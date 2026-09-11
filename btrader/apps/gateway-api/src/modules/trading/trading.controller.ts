import {
  Body,
  Controller,
  Delete,
  ForbiddenException,
  Get,
  Param,
  Patch,
  Post,
  Query,
  UseGuards,
} from '@nestjs/common';
import { ApiTags, ApiBearerAuth, ApiOperation } from '@nestjs/swagger';
import { prisma } from '@btrader/db';
import { latency } from '@btrader/shared';
import { JwtAuthGuard } from '../../common/jwt.guard';
import { CurrentTenant, CurrentUser, Roles, ForbidReadOnly } from '../../common/decorators';
import { EngineProvider } from './engine.provider';
import { AuditService } from '../audit/audit.service';
import { PlaceOrderDto, ModifyPositionDto, ModifyOrderDto, ClosePositionDto } from './dto';
import { PORTAL_READ_CACHE_MS, ttlDelPrefix, ttlWrap } from '../../common/ttl-cache';

const STAFF_ROLES = new Set(['SUPER_ADMIN', 'TENANT_ADMIN', 'TENANT_STAFF', 'SERVICE']);

@ApiTags('trading')
@ApiBearerAuth()
@UseGuards(JwtAuthGuard)
@Controller()
export class TradingController {
  constructor(
    private readonly eng: EngineProvider,
    private readonly audit: AuditService,
  ) {}

  /** Traders may only mutate their own accounts; staff/CRM service keep tenant scope. */
  private async assertAccountAccess(tenantId: string, u: any, accountId: string): Promise<void> {
    if (!accountId) throw new ForbiddenException('account required');
    if (STAFF_ROLES.has(u?.role)) return;
    // Account-number login already bound the JWT to this account — skip a DB round-trip.
    if (u.acct) {
      if (u.acct !== accountId) throw new ForbiddenException('account access denied');
      return;
    }
    const acct = await prisma.account.findFirst({
      where: { id: accountId, tenantId },
      select: { userId: true },
    });
    if (!acct || acct.userId !== u.id) throw new ForbiddenException('account access denied');
  }

  private async assertPositionAccess(tenantId: string, u: any, positionId: string): Promise<string> {
    const pos = await prisma.position.findFirst({
      where: { id: positionId, tenantId },
      select: { accountId: true },
    });
    if (!pos) throw new ForbiddenException('position access denied');
    await this.assertAccountAccess(tenantId, u, pos.accountId);
    return pos.accountId;
  }

  private async assertOrderAccess(tenantId: string, u: any, orderId: string): Promise<void> {
    const order = await prisma.order.findFirst({
      where: { id: orderId, tenantId },
      select: { accountId: true },
    });
    if (!order) throw new ForbiddenException('order access denied');
    await this.assertAccountAccess(tenantId, u, order.accountId);
  }

  // ── Orders ────────────────────────────────────────────────────────────────
  @Post('orders')
  @ForbidReadOnly()
  @ApiOperation({ summary: 'Place an order (market or pending). One-click supported.' })
  async place(@CurrentTenant() t: any, @CurrentUser() u: any, @Body() dto: PlaceOrderDto) {
    await this.assertAccountAccess(t.id, u, (dto as any).accountId);
    // Per-group client symbol suffix is display-only — strip it back to the
    // canonical symbol if the app ever sends the suffixed name (e.g. "EURUSD.s").
    const symbol = await this.stripGroupSuffix(t.id, (dto as any).accountId, dto.symbol);
    const res = await latency.time('order.place.total', () =>
      this.eng.engine.placeOrder(t.id, { ...dto, symbol, source: 'mobile' } as any),
    );
    ttlDelPrefix(`orders:${t.id}:${(dto as any).accountId}`);
    ttlDelPrefix(`pos:${t.id}:${(dto as any).accountId}`);
    void this.audit.log(t.id, u.id, 'ORDER_PLACE', 'order', res.orderId, { after: res });
    return res;
  }

  @Get('metrics/latency')
  @Roles('SUPER_ADMIN', 'TENANT_ADMIN')
  @ApiOperation({ summary: 'Latency profile of hot paths (order execution phases). Admin-only.' })
  latency() {
    return latency.snapshot();
  }

  /** Strip the account's group client-symbol-suffix from an incoming symbol. */
  private async stripGroupSuffix(tenantId: string, accountId: string | undefined, symbol: string): Promise<string> {
    if (!accountId || !symbol) return symbol;
    const sfx = await ttlWrap(`sfx:${tenantId}:${accountId}`, 30_000, async () => {
      const a = await prisma.account.findFirst({
        where: { tenantId, id: accountId },
        select: { group: { select: { clientSymbolSuffix: true } } },
      });
      return a?.group?.clientSymbolSuffix ?? '';
    });
    return sfx && symbol.endsWith(sfx) ? symbol.slice(0, symbol.length - sfx.length) : symbol;
  }

  @Get('orders')
  @ApiOperation({ summary: 'List orders for an account (optionally by status)' })
  orders(@CurrentTenant() t: any, @Query('accountId') accountId: string, @Query('status') status?: string) {
    return ttlWrap(`orders:${t.id}:${accountId}:${status || ''}`, PORTAL_READ_CACHE_MS, () =>
      prisma.order.findMany({
        where: { tenantId: t.id, accountId, ...(status ? { status: status as any } : {}) },
        include: { symbol: { select: { symbol: true, digits: true } } },
        orderBy: { createdAt: 'desc' },
        take: 200,
      }),
    );
  }

  @Patch('orders/:id')
  @ForbidReadOnly()
  @ApiOperation({ summary: 'Modify a pending order (price / SL / TP)' })
  async modifyOrder(
    @CurrentTenant() t: any,
    @CurrentUser() u: any,
    @Param('id') id: string,
    @Body() dto: ModifyOrderDto,
  ) {
    await this.assertOrderAccess(t.id, u, id);
    await this.eng.engine.modifyOrder(t.id, id, dto);
    void this.audit.log(t.id, u.id, 'ORDER_MODIFY', 'order', id, { after: dto });
    return { ok: true };
  }

  @Delete('orders/:id')
  @ForbidReadOnly()
  @ApiOperation({ summary: 'Cancel a pending order' })
  async cancel(@CurrentTenant() t: any, @CurrentUser() u: any, @Param('id') id: string) {
    await this.assertOrderAccess(t.id, u, id);
    await this.eng.engine.cancelOrder(t.id, id);
    void this.audit.log(t.id, u.id, 'ORDER_CANCEL', 'order', id);
    return { ok: true };
  }

  // ── Positions ───────────────────────────────────────────────────────────
  @Get('positions')
  @ApiOperation({ summary: 'List open positions for an account' })
  positions(@CurrentTenant() t: any, @Query('accountId') accountId: string, @Query('status') status = 'OPEN') {
    return ttlWrap(`pos:${t.id}:${accountId}:${status}`, PORTAL_READ_CACHE_MS, () =>
      prisma.position.findMany({
        where: { tenantId: t.id, accountId, status: status as any },
        include: { symbol: { select: { symbol: true, digits: true } } },
        orderBy: { openedAt: 'desc' },
        take: 500,
      }),
    );
  }

  @Patch('positions/:id')
  @ForbidReadOnly()
  @ApiOperation({ summary: 'Modify SL/TP on an open position' })
  async modify(@CurrentTenant() t: any, @CurrentUser() u: any, @Param('id') id: string, @Body() dto: ModifyPositionDto) {
    const accountId = await this.assertPositionAccess(t.id, u, id);
    await this.eng.engine.modifyPosition(t.id, id, dto.slPrice, dto.tpPrice);
    ttlDelPrefix(`pos:${t.id}:${accountId}`);
    void this.audit.log(t.id, u.id, 'POSITION_MODIFY', 'position', id, { after: dto });
    return { ok: true };
  }

  @Patch('positions/:id/open-price')
  @Roles('SUPER_ADMIN', 'TENANT_ADMIN', 'TENANT_STAFF')
  @ApiOperation({ summary: 'Dealer: edit an open position entry price (slippage compensation, admin-only)' })
  async setOpenPrice(@CurrentTenant() t: any, @CurrentUser() u: any, @Param('id') id: string, @Body() dto: { openPrice: number }) {
    await this.eng.engine.setPositionOpenPrice(t.id, id, Number(dto.openPrice));
    void this.audit.log(t.id, u.id, 'POSITION_MODIFY', 'position', id, { after: { openPrice: dto.openPrice, dealerEdit: true } });
    return { ok: true };
  }

  @Post('positions/:id/close')
  @ForbidReadOnly()
  @ApiOperation({ summary: 'Close a position (full or partial via volume)' })
  async close(@CurrentTenant() t: any, @CurrentUser() u: any, @Param('id') id: string, @Body() dto: ClosePositionDto) {
    const accountId = await this.assertPositionAccess(t.id, u, id);
    const res = await this.eng.engine.closePosition(t.id, id, dto.volume);
    ttlDelPrefix(`pos:${t.id}:${accountId}`);
    ttlDelPrefix(`orders:${t.id}:${accountId}`);
    void this.audit.log(t.id, u.id, 'POSITION_CLOSE', 'position', id, { after: res });
    return res;
  }

  @Post('positions/:id/close-at')
  @Roles('SUPER_ADMIN', 'TENANT_ADMIN', 'TENANT_STAFF')
  @ApiOperation({ summary: 'Dealer: close a position at a manual price (slippage / compensation, admin-only)' })
  async closeAt(@CurrentTenant() t: any, @CurrentUser() u: any, @Param('id') id: string, @Body() dto: { price: number; volume?: number }) {
    const res = await this.eng.engine.closePosition(t.id, id, dto.volume, { closePriceOverride: Number(dto.price) });
    void this.audit.log(t.id, u.id, 'POSITION_CLOSE', 'position', id, { after: { ...res, closePrice: dto.price, dealerClose: true } });
    return res;
  }

  @Post('accounts/:accountId/close-all')
  @ForbidReadOnly()
  @ApiOperation({ summary: 'Close all open positions on an account' })
  async closeAll(@CurrentTenant() t: any, @CurrentUser() u: any, @Param('accountId') accountId: string) {
    await this.assertAccountAccess(t.id, u, accountId);
    const closed = await this.eng.engine.closeAll(t.id, accountId);
    ttlDelPrefix(`pos:${t.id}:${accountId}`);
    ttlDelPrefix(`orders:${t.id}:${accountId}`);
    void this.audit.log(t.id, u.id, 'POSITION_CLOSE', 'account', accountId, { meta: { closed } });
    return { closed };
  }

  // ── History ───────────────────────────────────────────────────────────────
  @Get('history/deals')
  @ApiOperation({ summary: 'Trade/deal history for an account (MT5-style, enriched)' })
  async deals(
    @CurrentTenant() t: any,
    @Query('accountId') accountId: string,
    @Query('from') from?: string,
    @Query('to') to?: string,
  ) {
    const deals = await prisma.deal.findMany({
      where: {
        tenantId: t.id,
        accountId,
        ...(from || to
          ? { createdAt: { gte: from ? new Date(from) : undefined, lte: to ? new Date(to) : undefined } }
          : {}),
      },
      orderBy: { createdAt: 'desc' },
      take: 500,
    });

    // Enrich with symbol name/digits (for trade rows) and the position open price
    // (entry → exit), plus the signed balance change per deal.
    const symIds = [...new Set(deals.map((d) => d.symbolId).filter(Boolean) as string[])];
    const posIds = [...new Set(deals.map((d) => d.positionId).filter(Boolean) as string[])];
    const [syms, poss] = await Promise.all([
      symIds.length
        ? prisma.symbol.findMany({ where: { id: { in: symIds } }, select: { id: true, symbol: true, digits: true } })
        : Promise.resolve([]),
      posIds.length
        ? prisma.position.findMany({
            where: { id: { in: posIds } },
            // slPrice/tpPrice/openedAt ride along on a join this query already
            // does, so the history detail can show the protection a trade
            // carried, and how long it was held, without a second round trip.
            select: { id: true, openPrice: true, slPrice: true, tpPrice: true, openedAt: true },
          })
        : Promise.resolve([]),
    ]);
    const symMap = new Map(syms.map((s) => [s.id, s]));
    const posMap = new Map(poss.map((p) => [p.id, p]));

    // Signed amount = change in balanceAfter, computed in chronological order.
    const asc = [...deals].sort((a, b) => a.createdAt.getTime() - b.createdAt.getTime());
    const amountById = new Map<string, number>();
    let prev: number | null = null;
    for (const d of asc) {
      const bal = Number(d.balanceAfter);
      amountById.set(d.id, prev == null ? bal : bal - prev);
      prev = bal;
    }

    return deals.map((d) => ({
      id: d.id,
      type: d.type,
      side: d.side,
      volume: d.volume,
      price: d.price,
      profit: d.profit,
      swap: d.swap,
      commission: d.commission,
      balanceAfter: d.balanceAfter,
      comment: d.comment,
      createdAt: d.createdAt,
      symbol: d.symbolId ? symMap.get(d.symbolId)?.symbol ?? null : null,
      digits: d.symbolId ? symMap.get(d.symbolId)?.digits ?? 5 : 5,
      openPrice: d.positionId ? posMap.get(d.positionId)?.openPrice ?? null : null,
      slPrice: d.positionId ? posMap.get(d.positionId)?.slPrice ?? null : null,
      tpPrice: d.positionId ? posMap.get(d.positionId)?.tpPrice ?? null : null,
      openedAt: d.positionId ? posMap.get(d.positionId)?.openedAt ?? null : null,
      // Same id the open position uses — client shortens to #1234 for IB tracking.
      positionId: d.positionId ?? null,
      ticket: d.positionId ?? null,
      amount: amountById.get(d.id) ?? 0,
    }));
  }
}
