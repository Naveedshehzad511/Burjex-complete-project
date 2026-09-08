import { ArgumentsHost, Catch, ExceptionFilter, Logger } from '@nestjs/common';
import { Response } from 'express';
import { BtError, BtErrorCode } from '@btrader/shared';

/**
 * Maps BtError onto HTTP.
 *
 * Without this every business rejection surfaced as a 500 "Internal server
 * error": insufficient funds, market closed, invalid volume, no price. Three
 * things go wrong when that happens —
 *
 *   1. The CRM cannot tell "declined" from "broken". A 500 is retryable, so a
 *      legitimately refused withdrawal gets hammered instead of accepted.
 *   2. Clients and support see "Internal server error" instead of the reason.
 *   3. Genuine faults are indistinguishable from routine rejections in logs
 *      and alerting.
 *
 * The response keeps the machine-readable `code` so callers branch on that
 * rather than parsing prose.
 */
const STATUS: Record<string, number> = {
  // auth / tenancy
  [BtErrorCode.UNAUTHORIZED]: 401,
  [BtErrorCode.INVALID_SIGNATURE]: 401,
  [BtErrorCode.FORBIDDEN]: 403,
  [BtErrorCode.IP_NOT_ALLOWED]: 403,
  [BtErrorCode.TENANT_SUSPENDED]: 403,
  [BtErrorCode.TENANT_NOT_FOUND]: 404,
  [BtErrorCode.RATE_LIMITED]: 429,

  // not found
  [BtErrorCode.POSITION_NOT_FOUND]: 404,
  [BtErrorCode.ORDER_NOT_FOUND]: 404,

  // already applied — the caller should stop, not retry
  [BtErrorCode.DUPLICATE_REF]: 409,

  // #2B: instant-execution requote — the price changed; the client re-confirms
  // the new price (in details.newPrice) and resubmits. 409 = state conflict.
  [BtErrorCode.REQUOTE]: 409,

  // client-fixable business rejections
  [BtErrorCode.VALIDATION]: 400,
  [BtErrorCode.INVALID_VOLUME]: 400,
  [BtErrorCode.INVALID_PRICE]: 400,
  [BtErrorCode.STOPS_TOO_CLOSE]: 400,
  [BtErrorCode.SYMBOL_DISABLED]: 400,
  [BtErrorCode.MARKET_CLOSED]: 400,
  [BtErrorCode.TRADING_DISABLED]: 403,
  [BtErrorCode.INSUFFICIENT_MARGIN]: 400,
  [BtErrorCode.INSUFFICIENT_FUNDS]: 400,
  [BtErrorCode.RISK_LIMIT_BREACH]: 400,

  // cannot price right now — retrying later is reasonable, unlike the above
  [BtErrorCode.NO_PRICE]: 503,
  [BtErrorCode.FX_RATE_UNAVAILABLE]: 503,

  [BtErrorCode.INTERNAL]: 500,
};

@Catch(BtError)
export class BtErrorFilter implements ExceptionFilter {
  private readonly logger = new Logger('BtError');

  catch(err: BtError, host: ArgumentsHost): void {
    const res = host.switchToHttp().getResponse<Response>();
    const status = STATUS[err.code] ?? 400;

    // Only a genuine fault deserves an error-level log; a refused withdrawal is
    // routine and should not page anyone.
    if (status >= 500) this.logger.error(`${err.code}: ${err.message}`);
    else this.logger.warn(`${err.code}: ${err.message}`);

    res.status(status).json({
      statusCode: status,
      code: err.code,
      message: err.message,
      ...(err.details ? { details: err.details } : {}),
    });
  }
}
