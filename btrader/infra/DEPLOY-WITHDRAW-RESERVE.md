# Withdrawal reservations (trading-account withdrawals)

A request to withdraw from a **trading account** now holds its amount in the matching engine until it is approved or
rejected. Wallet withdrawals are unchanged.

| Piece | Change |
|---|---|
| Database | `accounts."reservedWithdraw"` (default 0) and the table `withdraw_reservations` (one row per request). Additive. |
| Engine (`btrader-matching`) | Keeps the reserved amount out of the free margin for **new trades, pending-order placement and triggered pending orders**. Stop-out and margin level are untouched. |
| Gateway (`btrader-gateway`) | New `POST /crm/accounts/:login/withdraw-reservations` and `.../release`; the WITHDRAWAL balance op takes `reservationRef` and finalizes the reservation in the same transaction. Every other debit (transfers, admin debit) cannot use reserved funds. |
| CRM (`crm-web`) | A trading-account request reserves first (no request if the reservation is refused); approve pays against the reservation; reject releases it first. |

## Order matters: database FIRST

The engine and the gateway read `reservedWithdraw` from every account. A new engine or gateway on an old database
cannot read any account, so trading stops. Apply the schema before replacing them. The running (old) services keep
working on the new schema, so this step is safe on its own.

```
# 1. database (either one; both give the same schema)
docker compose -f deploy/docker-compose.live.yml --env-file deploy/.env.live run --rm btrader-gateway sh -lc 'cd /app/packages/db && npx prisma db push --skip-generate'
#    or:  psql ... -f btrader/packages/db/prisma/manual-sql/2026_withdraw_reservations.sql

# 2. engine and gateway
docker compose -f deploy/docker-compose.live.yml --env-file deploy/.env.live up -d --build btrader-matching btrader-gateway

# 3. CRM (after 2: the CRM calls the new gateway routes)
docker compose -f deploy/docker-compose.live.yml --env-file deploy/.env.live up -d --build crm-web
```

If the CRM is deployed before the gateway, new trading-account requests fail with "Unable to reserve the funds"
(nothing is created, nothing is lost) until the gateway is updated.

## Requests that were pending before this release

They hold nothing in the engine. Look first (changes nothing), then reserve what the funds allow:

```
docker exec -i bxnet_crm_web python manage.py reserve_pending_trading_withdrawals           # dry run
docker exec -i bxnet_crm_web python manage.py reserve_pending_trading_withdrawals --apply   # reserves
```

Requests the funds can no longer cover are listed and left pending, not reserved. An admin decides (reject, or ask
for a smaller amount). Until a legacy request is reserved or settled it is paid as before (checked against free funds
when approved).

## Checks after deploying

Reservations that are still held (`RESERVED`), with the CRM request they belong to (`crm-withdraw-reserve-<id>`):

```
SELECT a.login, r."externalRef", r.amount, r."createdAt" FROM withdraw_reservations r JOIN accounts a ON a.id=r."accountId" WHERE r.status='RESERVED' ORDER BY r."createdAt";
```

Every row should match a PENDING trading-account withdrawal in the CRM. A row with no pending request is an orphan
(the engine could not be reached when the CRM tried to release it - the CRM logs `WITHDRAWAL RESERVATION NOT RELEASED`
with the reference). Release it:

```
docker exec -i bxnet_crm_web python manage.py shell -c "from btrader_integration.services import release_btrader_withdrawal as r; print(r(login='<LOGIN>', external_ref='<externalRef>'))"
```

The sum of an account's `RESERVED` rows must equal `accounts."reservedWithdraw"`:

```
SELECT a.login, a."reservedWithdraw", coalesce(sum(r.amount) FILTER (WHERE r.status='RESERVED'),0) AS held FROM accounts a LEFT JOIN withdraw_reservations r ON r."accountId"=a.id GROUP BY a.id HAVING a."reservedWithdraw" <> coalesce(sum(r.amount) FILTER (WHERE r.status='RESERVED'),0);
```

(No rows = consistent.)

## Rollback

Everything is additive. Redeploy the previous images; the new column and table simply go unused. Reservations that were
held at that moment stop being enforced.
