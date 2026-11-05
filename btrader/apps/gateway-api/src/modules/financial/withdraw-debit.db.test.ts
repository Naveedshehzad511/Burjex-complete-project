import 'reflect-metadata';
import { prisma } from '@btrader/db';
import { FinancialService } from './financial.service';

/**
 * Withdrawal requests take their amount out of the balance when made, on a real database (BT_TEST_DB=1 and a
 * throwaway DATABASE_URL): trading cannot reach it, approval pays without a second debit, rejection refunds once.
 */
const run = process.env.BT_TEST_DB === '1' ? describe : describe.skip;

run('withdrawal debited on request', () => {
  const fin = new FinancialService();
  let tenantId = '';
  let userId = '';
  let symbolId = '';
  let n = 0;

  beforeAll(async () => {
    const t = await prisma.tenant.create({ data: { name: 'wd test', slug: `wd-${Date.now()}` } });
    tenantId = t.id;
    userId = (await prisma.user.create({ data: { tenantId, email: `wd-${Date.now()}@test.local` } })).id;
    symbolId = (await prisma.symbol.create({ data: { tenantId, symbol: 'XAUUSD', baseCurrency: 'XAU', quoteCurrency: 'USD' } })).id;
  });

  afterEach(() => {
    delete process.env.WITHDRAW_DEBIT_ON_REQUEST;
  });

  async function account(balance: number, credit = 0) {
    const login = `9${String(++n).padStart(5, '0')}`;
    const a = await prisma.account.create({ data: { tenantId, userId, login, balance, credit, equity: balance + credit } });
    return { id: a.id, login };
  }

  async function state(id: string) {
    const a = await prisma.account.findUniqueOrThrow({ where: { id } });
    return {
      balance: Number(a.balance),
      equity: Number(a.equity),
      freeMargin: Number(a.freeMargin),
      marginLevel: Number(a.marginLevel),
      reserved: Number(a.reservedWithdraw),
    };
  }

  const status = async (ref: string) => (await prisma.withdrawReservation.findUnique({ where: { externalRef: ref } }))?.status;
  const adjustments = (accountId: string) => prisma.balanceAdjustment.findMany({ where: { accountId }, orderBy: { createdAt: 'asc' } });
  const request = (login: string, amount: number, ref: string) =>
    fin.reserveWithdrawal({ tenantId, login, amount, externalRef: ref, comment: `CRM withdrawal ${ref}` });
  const approve = (login: string, amount: number, id: string) =>
    fin.adjust({ tenantId, login, type: 'WITHDRAWAL', amount, externalRef: `pay-${id}`, reservationRef: `req-${id}`, performedBy: 'test' });
  const reject = (login: string, id: string) => fin.releaseWithdrawal({ tenantId, login, externalRef: `req-${id}` });

  it('the request takes the amount out of the balance: balance, equity and free margin all drop at once', async () => {
    const a = await account(20);
    const res = await request(a.login, 10, 'req-a1');
    expect(res.status).toBe('DEBITED');
    expect(await state(a.id)).toMatchObject({ balance: 10, equity: 10, freeMargin: 10, reserved: 0 });
    expect(await status('req-a1')).toBe('DEBITED');
    const adj = await adjustments(a.id);
    expect(adj.map((x) => Number(x.amount))).toEqual([-10]);
    expect(adj[0].type).toBe('WITHDRAWAL');
    const deal = await prisma.deal.findUniqueOrThrow({ where: { id: adj[0].dealId! } });
    expect(Number(deal.balanceAfter)).toBe(10);
  });

  it('approval pays it out without a second debit, and a repeated approval changes nothing', async () => {
    const a = await account(20);
    await request(a.login, 10, 'req-a2');
    const paid = await approve(a.login, 10, 'a2');
    expect(paid).toMatchObject({ ok: true, duplicate: false, paidAtRequest: true });
    expect(await state(a.id)).toMatchObject({ balance: 10 });
    expect(await status('req-a2')).toBe('FINALIZED');
    const again = await approve(a.login, 10, 'a2');
    expect(again.duplicate).toBe(true);
    expect(await state(a.id)).toMatchObject({ balance: 10 });
    expect(await adjustments(a.id)).toHaveLength(1);
  });

  it('a trading loss after the request cannot reach the requested money: approval still pays (the 500145 case)', async () => {
    const a = await account(142);
    await request(a.login, 35, 'req-a3');
    // Trades lose 105 of what is left (the engine moves the balance on each close).
    await prisma.account.update({ where: { id: a.id }, data: { balance: 2 } });
    await expect(approve(a.login, 35, 'a3')).resolves.toMatchObject({ ok: true });
    expect(await state(a.id)).toMatchObject({ balance: 2 });
  });

  it('rejection refunds exactly once; approval after rejection is refused', async () => {
    const a = await account(20);
    await request(a.login, 10, 'req-a4');
    const r1 = await reject(a.login, 'a4');
    expect(r1).toMatchObject({ released: true, status: 'RELEASED', refunded: 10 });
    expect(await state(a.id)).toMatchObject({ balance: 20, equity: 20, freeMargin: 20 });
    const r2 = await reject(a.login, 'a4');
    expect(r2).toMatchObject({ released: false, status: 'RELEASED' });
    expect(await state(a.id)).toMatchObject({ balance: 20 });
    expect((await adjustments(a.id)).map((x) => Number(x.amount))).toEqual([-10, 10]);
    await expect(approve(a.login, 10, 'a4')).rejects.toThrow(/released/);
    expect(await state(a.id)).toMatchObject({ balance: 20 });
  });

  it('with open trades: only the real free funds can be requested, and the request leaves margin level at 100% or more', async () => {
    const a = await account(100);
    await prisma.position.create({
      data: { tenantId, accountId: a.id, symbolId, side: 'BUY', volume: 0.1, openPrice: 4000, marginUsed: 40, profit: -30 },
    });
    // equity 70, margin 40, free 30
    await expect(request(a.login, 31, 'req-a5x')).rejects.toThrow(/insufficient/);
    expect(await status('req-a5x')).toBeUndefined();
    expect(await state(a.id)).toMatchObject({ balance: 100 });
    await request(a.login, 30, 'req-a5');
    expect(await state(a.id)).toMatchObject({ balance: 70, equity: 40, freeMargin: 0, marginLevel: 100 });
  });

  it('a floating profit is not withdrawable; credit is not withdrawable', async () => {
    const a = await account(10, 50);
    await prisma.position.create({
      data: { tenantId, accountId: a.id, symbolId, side: 'SELL', volume: 0.01, openPrice: 4000, marginUsed: 1, profit: 25 },
    });
    await expect(request(a.login, 10.01, 'req-a6x')).rejects.toThrow(/insufficient/);
    await request(a.login, 10, 'req-a6');
    expect(await state(a.id)).toMatchObject({ balance: 0, equity: 75 });
  });

  it('several pending requests: each is taken out, paid or refunded on its own', async () => {
    const a = await account(30);
    await request(a.login, 10, 'req-a7');
    await request(a.login, 10, 'req-a8');
    expect(await state(a.id)).toMatchObject({ balance: 10 });
    await expect(request(a.login, 10.01, 'req-a9')).rejects.toThrow(/insufficient/);
    await reject(a.login, 'a7');
    await approve(a.login, 10, 'a8');
    expect(await state(a.id)).toMatchObject({ balance: 20 });
  });

  it('a repeated request (same reference) is not taken twice', async () => {
    const a = await account(20);
    await request(a.login, 10, 'req-a10');
    const again = await request(a.login, 10, 'req-a10');
    expect(again.duplicate).toBe(true);
    expect(await state(a.id)).toMatchObject({ balance: 10 });
  });

  it('two requests at the same moment cannot take more than the account holds', async () => {
    const a = await account(20);
    const out = await Promise.allSettled([request(a.login, 15, 'req-a11'), request(a.login, 15, 'req-a12')]);
    expect(out.filter((o) => o.status === 'fulfilled')).toHaveLength(1);
    expect(await state(a.id)).toMatchObject({ balance: 5 });
  });

  it('approval with a different amount than requested is refused', async () => {
    const a = await account(20);
    await request(a.login, 10, 'req-a13');
    await expect(approve(a.login, 12, 'a13')).rejects.toThrow(/differs/);
    expect(await status('req-a13')).toBe('DEBITED');
  });

  it('a deposit while a request is pending is the client\'s: it is not used for the request', async () => {
    const a = await account(20);
    await request(a.login, 10, 'req-a14');
    await fin.adjust({ tenantId, login: a.login, type: 'DEPOSIT', amount: 100, externalRef: 'dep-a14' });
    await approve(a.login, 10, 'a14');
    expect(await state(a.id)).toMatchObject({ balance: 110 });
  });

  it('switched off: the old hold (RESERVED) - and an old hold is still settled the old way once switched on', async () => {
    const a = await account(20);
    process.env.WITHDRAW_DEBIT_ON_REQUEST = 'off';
    const held = await request(a.login, 10, 'req-a15');
    expect(held.status).toBe('RESERVED');
    expect(await state(a.id)).toMatchObject({ balance: 20, reserved: 10 });
    delete process.env.WITHDRAW_DEBIT_ON_REQUEST;
    // A new request next to the old hold: only what the hold leaves is available.
    await expect(request(a.login, 10.01, 'req-a16x')).rejects.toThrow(/insufficient/);
    await request(a.login, 5, 'req-a16');
    expect(await state(a.id)).toMatchObject({ balance: 15, reserved: 10 });
    await approve(a.login, 10, 'a15');
    expect(await state(a.id)).toMatchObject({ balance: 5, reserved: 0 });
    expect(await status('req-a15')).toBe('FINALIZED');
  });

  it('an old hold the account can no longer cover is refused at approval (the CRM then rejects it)', async () => {
    const a = await account(20);
    process.env.WITHDRAW_DEBIT_ON_REQUEST = 'off';
    await request(a.login, 10, 'req-a17');
    await prisma.account.update({ where: { id: a.id }, data: { balance: 3 } });
    await expect(approve(a.login, 10, 'a17')).rejects.toThrow(/insufficient/);
    expect(await state(a.id)).toMatchObject({ balance: 3 });
    const rel = await reject(a.login, 'a17');
    expect(rel).toMatchObject({ released: true, status: 'RELEASED' });
    expect(await state(a.id)).toMatchObject({ balance: 3, reserved: 0 });
  });
});
