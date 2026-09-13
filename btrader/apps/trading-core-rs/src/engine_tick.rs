use crate::books::{BookRow, Claim, PendingRow};
use crate::calc::{compute_aggregates, pending_type_to_apply_kind, position_profit, worst_position};
use crate::engine::{spec_of, Engine, PlaceReq};
use crate::error::BtResult;
use crate::models::{now_ms, Snapshot};
use crate::policy::create_plan;
use crate::trigger::{is_limit_fill_type, pending_fires, protective_hit, PendingAction};
use chrono::Utc;
use serde_json::json;
use sqlx::Row;
use std::collections::HashSet;
use std::time::Instant;

impl Engine {
    pub async fn hydrate(&self) -> BtResult<usize> {
        let pos = sqlx::query(
            r#"SELECT p.id, p."tenantId", p."accountId", p."symbolId", p.side::text AS side,
                      p.volume::float8 AS volume, p."openPrice"::float8 AS "openPrice",
                      p."slPrice"::float8 AS "slPrice", p."tpPrice"::float8 AS "tpPrice",
                      p."marginUsed"::float8 AS "marginUsed", p.swap::float8 AS swap,
                      p.commission::float8 AS commission, p."coveredVolume"::float8 AS "coveredVolume",
                      p."openedAt", p."execClaimKind", a.currency, a."groupId"
               FROM positions p JOIN accounts a ON a.id=p."accountId" WHERE p.status='OPEN'"#,
        )
        .fetch_all(&self.pool)
        .await?;
        let rows: Vec<BookRow> = pos
            .into_iter()
            .map(|r| BookRow {
                id: r.try_get("id").unwrap_or_default(),
                tenant_id: r.try_get("tenantId").unwrap_or_default(),
                account_id: r.try_get("accountId").unwrap_or_default(),
                symbol_id: r.try_get("symbolId").unwrap_or_default(),
                side: r.try_get("side").unwrap_or_default(),
                volume: r.try_get("volume").unwrap_or(0.0),
                open_price: r.try_get("openPrice").unwrap_or(0.0),
                sl_price: r.try_get("slPrice").ok(),
                tp_price: r.try_get("tpPrice").ok(),
                margin_used: r.try_get("marginUsed").unwrap_or(0.0),
                swap: r.try_get("swap").unwrap_or(0.0),
                commission: r.try_get("commission").unwrap_or(0.0),
                covered_volume: r.try_get("coveredVolume").unwrap_or(0.0),
                opened_at: r.try_get("openedAt").unwrap_or_else(|_| Utc::now()),
                account_currency: r.try_get("currency").unwrap_or_else(|_| "USD".into()),
                group_id: r.try_get("groupId").ok(),
                exec_claim_kind: r.try_get("execClaimKind").ok(),
            })
            .collect();
        let n = rows.len();
        self.book.load(rows);

        let pend = sqlx::query(
            r#"SELECT id, "tenantId", "accountId", "symbolId", side::text AS side, type::text AS type,
                      status::text AS status, volume::float8 AS volume, price::float8 AS price,
                      "stopPrice"::float8 AS "stopPrice", "slPrice"::float8 AS "slPrice",
                      "tpPrice"::float8 AS "tpPrice", "expiresAt", "updatedAt", "stopTriggered"
               FROM orders WHERE status='PENDING' OR (status='PARTIAL' AND "positionId" IS NULL AND "filledVolume"=0)"#,
        )
        .fetch_all(&self.pool)
        .await?;
        self.pendings.load(
            pend.into_iter()
                .map(|r| PendingRow {
                    id: r.try_get("id").unwrap_or_default(),
                    tenant_id: r.try_get("tenantId").unwrap_or_default(),
                    account_id: r.try_get("accountId").unwrap_or_default(),
                    symbol_id: r.try_get("symbolId").unwrap_or_default(),
                    side: r.try_get("side").unwrap_or_default(),
                    order_type: r.try_get("type").unwrap_or_default(),
                    status: r.try_get("status").unwrap_or_default(),
                    volume: r.try_get("volume").unwrap_or(0.0),
                    price: r.try_get("price").ok(),
                    stop_price: r.try_get("stopPrice").ok(),
                    sl_price: r.try_get("slPrice").ok(),
                    tp_price: r.try_get("tpPrice").ok(),
                    expires_at: r.try_get("expiresAt").ok(),
                    updated_at: r.try_get("updatedAt").unwrap_or_else(|_| Utc::now()),
                    stop_triggered: r.try_get("stopTriggered").unwrap_or(false),
                })
                .collect(),
        );
        Ok(n)
    }

    pub async fn on_tick_fast(&self, tenant_id: &str, symbol: &str) {
        if let Err(e) = self.trigger_pending(tenant_id, symbol).await {
            tracing::debug!(error=%e.message, "pending tick");
        }
        if let Err(e) = self.check_protective(tenant_id, symbol).await {
            tracing::debug!(error=%e.message, "protective tick");
        }
    }

    pub async fn on_tick_slow(&self, tenant_id: &str, symbol: &str) {
        if let Err(e) = self.check_stop_out(tenant_id, symbol).await {
            tracing::debug!(error=%e.message, "stopout tick");
        }
        self.emit_live(tenant_id, symbol).await;
    }

    async fn trigger_pending(&self, tenant_id: &str, symbol: &str) -> BtResult<()> {
        let Some(sym) = self.load_symbol(tenant_id, symbol).await? else {
            return Ok(());
        };
        let Some(raw_bid) = self.prices.sell_price(tenant_id, symbol) else {
            return Ok(());
        };
        let Some(raw_ask) = self.prices.buy_price(tenant_id, symbol) else {
            return Ok(());
        };
        let working = self.pendings.for_symbol(tenant_id, &sym.id);
        if working.is_empty() {
            return Ok(());
        }
        let now = Utc::now();
        for o in working {
            if o.expires_at.is_some_and(|e| e < now) {
                let _ = sqlx::query(r#"UPDATE orders SET status='EXPIRED'::"OrderStatus" WHERE id=$1"#)
                    .bind(&o.id)
                    .execute(&self.pool)
                    .await;
                self.pendings.remove(&o.id);
                continue;
            }
            if o.status == "PARTIAL" {
                let _ = self.fill_pending(tenant_id, &o.id).await;
                continue;
            }
            let Some(trigger) = o.stop_price.or(o.price) else {
                continue;
            };
            let gid = self.acct_group.get(&o.account_id).and_then(|g| g.clone());
            if gid.is_none() && !self.acct_group.contains_key(&o.account_id) {
                if let Ok(Some(row)) = sqlx::query(r#"SELECT "groupId" FROM accounts WHERE id=$1"#)
                    .bind(&o.account_id)
                    .fetch_optional(&self.pool)
                    .await
                {
                    let g: Option<String> = row.try_get("groupId").ok();
                    self.acct_group.insert(o.account_id.clone(), g.clone());
                }
            }
            let gid = self.acct_group.get(&o.account_id).and_then(|g| g.clone());
            let pricing = self.group_pricing(gid.as_deref(), &sym, tenant_id).await?;
            let (bid, ask) = self.quoted_bid_ask(tenant_id, symbol, &sym, &pricing).unwrap_or((raw_bid, raw_ask));
            let action = pending_fires(
                &o.order_type,
                &o.side,
                bid,
                ask,
                trigger,
                o.stop_price,
                o.price,
                o.stop_triggered,
            );
            if action == PendingAction::ArmStopLimit {
                let n = sqlx::query(
                    r#"UPDATE orders SET "stopTriggered"=true, "triggeredAt"=NOW()
                       WHERE id=$1 AND status='PENDING' AND "stopTriggered"=false"#,
                )
                .bind(&o.id)
                .execute(&self.pool)
                .await?
                .rows_affected();
                if n > 0 {
                    self.pendings.patch(&o.id, None, Some(true));
                }
                continue;
            }
            if action != PendingAction::Fill {
                continue;
            }
            let n = sqlx::query(
                r#"UPDATE orders SET status='PARTIAL'::"OrderStatus", "triggeredAt"=NOW()
                   WHERE id=$1 AND status IN ('PENDING','PARTIAL')"#,
            )
            .bind(&o.id)
            .execute(&self.pool)
            .await?
            .rows_affected();
            if n == 0 {
                continue;
            }
            self.pendings.patch(&o.id, Some("PARTIAL"), None);
            let _ = self.fill_pending(tenant_id, &o.id).await;
        }
        Ok(())
    }

    pub(crate) async fn fill_pending(&self, tenant_id: &str, order_id: &str) -> BtResult<()> {
        let row = sqlx::query(
            r#"SELECT o.id, o."accountId", o.status::text AS status, o.type::text AS type, o.side::text AS side,
                      o.volume::float8 AS volume, o.price::float8 AS price, o."stopPrice"::float8 AS "stopPrice",
                      o."slPrice"::float8 AS "slPrice", o."tpPrice"::float8 AS "tpPrice",
                      s.symbol, s.digits
               FROM orders o JOIN symbols s ON s.id=o."symbolId" WHERE o.id=$1"#,
        )
        .bind(order_id)
        .fetch_optional(&self.pool)
        .await?;
        let Some(o) = row else {
            self.pendings.remove(order_id);
            return Ok(());
        };
        let status: String = o.try_get("status").unwrap_or_default();
        if status != "PARTIAL" && status != "PENDING" {
            self.pendings.remove(order_id);
            return Ok(());
        }
        let account_id: String = o.try_get("accountId").unwrap_or_default();
        let Some(acct) = self.load_account(tenant_id, &account_id).await? else {
            let _ = sqlx::query(r#"UPDATE orders SET status='REJECTED'::"OrderStatus" WHERE id=$1"#)
                .bind(order_id)
                .execute(&self.pool)
                .await;
            self.pendings.remove(order_id);
            return Ok(());
        };
        let Some(sym) = self.load_symbol(tenant_id, &o.try_get::<String, _>("symbol").unwrap_or_default()).await? else {
            return Ok(());
        };
        let ot: String = o.try_get("type").unwrap_or_default();
        let side: String = o.try_get("side").unwrap_or_default();
        let apply_kind = pending_type_to_apply_kind(&ot, &side);
        let pricing = self.group_pricing(acct.group_id.as_deref(), &sym, tenant_id).await?;
        let plan = create_plan(&pricing, apply_kind, Instant::now(), now_ms());
        crate::policy::wait_for_deadline(Some(&plan)).await;
        let honour = if apply_kind == "buyStop" || apply_kind == "sellStop" {
            o.try_get::<Option<f64>, _>("stopPrice").ok().flatten().or_else(|| o.try_get("price").ok())
        } else {
            o.try_get::<Option<f64>, _>("price").ok().flatten().or_else(|| o.try_get("stopPrice").ok())
        };
        let clamp = if is_limit_fill_type(&ot) {
            o.try_get::<Option<f64>, _>("price").ok().flatten()
        } else {
            None
        };
        let req = PlaceReq {
            account_id: account_id.clone(),
            symbol: sym.symbol.clone(),
            side,
            order_type: ot.clone(),
            volume: o.try_get("volume").unwrap_or(0.0),
            price: honour,
            stop_price: None,
            sl_price: o.try_get("slPrice").ok(),
            tp_price: o.try_get("tpPrice").ok(),
            time_in_force: None,
            expires_at: None,
            comment: None,
            one_click: None,
            client_order_id: None,
            source: Some("api".into()),
        };
        match self
            .execute_market(tenant_id, &acct, &sym, &req, req.volume, clamp, Some(plan), true)
            .await
        {
            Ok(fill) => {
                let _ = sqlx::query(
                    r#"UPDATE orders SET status='FILLED'::"OrderStatus", "filledAt"=NOW(), "triggeredAt"=NOW(),
                       "filledVolume"=volume, "avgFillPrice"=$1, "positionId"=$2 WHERE id=$3"#,
                )
                .bind(fill.fill_price)
                .bind(&fill.position_id)
                .bind(order_id)
                .execute(&self.pool)
                .await;
                self.pendings.remove(order_id);
                self.emit(
                    tenant_id,
                    json!({
                        "kind":"ORDER_UPDATE","tenantId":tenant_id,
                        "order":{"id":order_id,"status":"FILLED","positionId":fill.position_id,"avgFillPrice":fill.fill_price}
                    }),
                )
                .await;
            }
            Err(e) if matches!(e.code, crate::error::INSUFFICIENT_MARGIN | crate::error::TRADING_DISABLED | crate::error::INVALID_VOLUME) => {
                let _ = sqlx::query(r#"UPDATE orders SET status='REJECTED'::"OrderStatus", "rejectReason"=$1 WHERE id=$2"#)
                    .bind(&e.message)
                    .bind(order_id)
                    .execute(&self.pool)
                    .await;
                self.pendings.remove(order_id);
            }
            Err(e) => tracing::error!(error=%e.message, "pending fill failed"),
        }
        Ok(())
    }

    async fn check_protective(&self, tenant_id: &str, symbol: &str) -> BtResult<()> {
        let Some(sym) = self.load_symbol(tenant_id, symbol).await? else {
            return Ok(());
        };
        let Some(raw_bid) = self.prices.sell_price(tenant_id, symbol) else {
            return Ok(());
        };
        let Some(raw_ask) = self.prices.buy_price(tenant_id, symbol) else {
            return Ok(());
        };
        let open = self.book.for_symbol(tenant_id, &sym.id);
        for p in open {
            if p.exec_claim_kind.is_some() || self.claims.has(&p.id) {
                if p.exec_claim_kind.as_deref() == Some("sl")
                    || p.exec_claim_kind.as_deref() == Some("tp")
                    || self.claims.has(&p.id)
                {
                    let rec = self.claims.get(&p.id);
                    let kind = rec
                        .as_ref()
                        .map(|c| c.kind.as_str())
                        .or(p.exec_claim_kind.as_deref())
                        .unwrap_or("sl");
                    let _ = self
                        .close_position(
                            tenant_id,
                            &p.id,
                            None,
                            None,
                            rec.as_ref().and_then(|c| c.level),
                            Some(kind),
                            false,
                            None,
                            false,
                            false,
                            Some(p.account_id.clone()),
                        )
                        .await;
                }
                continue;
            }
            let pricing = self.group_pricing(p.group_id.as_deref(), &sym, tenant_id).await?;
            let (bid, ask) = self.quoted_bid_ask(tenant_id, symbol, &sym, &pricing).unwrap_or((raw_bid, raw_ask));
            let (hit, level) = protective_hit(&p.side, bid, ask, p.sl_price, p.tp_price);
            let Some(hit) = hit else { continue };
            let kind = if hit == "SL" { "sl" } else { "tp" };
            let claimed = self.claims.claim(
                &p.id,
                Claim {
                    kind: kind.into(),
                    level,
                    bid,
                    ask,
                    trigger_wall: now_ms(),
                    trigger_mono: 0.0,
                },
            );
            if !claimed {
                continue;
            }
            self.book.patch_claim(&p.id, kind);
            let n = sqlx::query(
                r#"UPDATE positions SET "execClaimKind"=$1, "execClaimedAt"=NOW(), "execClaimedBy"=$2,
                   "execTriggerAt"=NOW(), "execTriggerBid"=$3, "execTriggerAsk"=$4
                   WHERE id=$5 AND status='OPEN' AND "execClaimedAt" IS NULL"#,
            )
            .bind(kind)
            .bind(crate::engine_id())
            .bind(bid)
            .bind(ask)
            .bind(&p.id)
            .execute(&self.pool)
            .await?
            .rows_affected();
            if n == 0 {
                continue;
            }
            let _ = self
                .close_position(
                    tenant_id,
                    &p.id,
                    None,
                    None,
                    level,
                    Some(kind),
                    false,
                    None,
                    false,
                    false,
                    Some(p.account_id.clone()),
                )
                .await;
        }
        Ok(())
    }

    async fn check_stop_out(&self, tenant_id: &str, symbol: &str) -> BtResult<()> {
        let Some(sym) = self.load_symbol(tenant_id, symbol).await? else {
            return Ok(());
        };
        let accounts = self.book.accounts_for_symbol(tenant_id, &sym.id);
        let now = now_ms();
        for account_id in accounts.into_iter().take(4) {
            let last = self.stop_out_checked.get(&account_id).map(|v| *v).unwrap_or(0);
            if now - last < 1000 {
                continue;
            }
            self.stop_out_checked.insert(account_id.clone(), now);
            self.enforce_stop_out(tenant_id, &account_id).await;
        }
        Ok(())
    }

    async fn enforce_stop_out(&self, tenant_id: &str, account_id: &str) {
        let mut skip = HashSet::new();
        for _ in 0..32 {
            let Ok(Some(acct)) = self.load_account(tenant_id, account_id).await else {
                return;
            };
            let Ok(views) = self.open_views(tenant_id, account_id, &acct.currency).await else {
                return;
            };
            let agg = compute_aggregates(acct.balance, acct.credit, &views);
            if agg.margin <= 0.0 {
                return;
            }
            if agg.margin_level > f64::from(acct.stop_out_level) {
                if agg.margin_level <= f64::from(acct.margin_call_level) {
                    self.emit(
                        tenant_id,
                        json!({"kind":"MARGIN_CALL","tenantId":tenant_id,"accountId":account_id,"marginLevel":agg.margin_level}),
                    )
                    .await;
                }
                return;
            }
            let Some(worst) = worst_position(&views, &skip) else {
                return;
            };
            self.emit(
                tenant_id,
                json!({"kind":"STOP_OUT","tenantId":tenant_id,"accountId":account_id,"positionId":worst.id}),
            )
            .await;
            if self
                .close_position(tenant_id, &worst.id, None, None, None, None, true, None, false, true, Some(account_id.into()))
                .await
                .is_err()
            {
                skip.insert(worst.id.clone());
            }
        }
    }

    async fn emit_live(&self, tenant_id: &str, symbol: &str) {
        let key = format!("{tenant_id}:{symbol}");
        let now = now_ms();
        if now - self.live_throttle.get(&key).map(|v| *v).unwrap_or(0) < 500 {
            return;
        }
        self.live_throttle.insert(key, now);
        let Ok(Some(sym)) = self.load_symbol(tenant_id, symbol).await else {
            return;
        };
        let mut accounts = Vec::new();
        let mut seen = HashSet::new();
        for p in self.book.for_symbol(tenant_id, &sym.id) {
            let current = if p.side.eq_ignore_ascii_case("BUY") {
                self.prices.sell_price(tenant_id, symbol)
            } else {
                self.prices.buy_price(tenant_id, symbol)
            }
            .unwrap_or(p.open_price);
            let spec = spec_of(&sym);
            let conv = self.quote_to_account(tenant_id, &p.account_currency, &spec.quote_currency);
            let profit = position_profit(&p.side, p.volume, p.open_price, current, &spec, conv)
                + p.swap
                + p.commission;
            self.profit_dirty.insert(p.id.clone(), profit);
            self.emit(
                tenant_id,
                json!({
                    "kind":"POSITION_UPDATE","tenantId":tenant_id,
                    "position":{"id":p.id,"accountId":p.account_id,"symbol":symbol,"side":p.side,"status":"OPEN",
                        "volume":p.volume,"openPrice":p.open_price,"currentPrice":current,"profit":profit,
                        "slPrice":p.sl_price,"tpPrice":p.tp_price}
                }),
            )
            .await;
            if seen.insert(p.account_id.clone()) {
                accounts.push((p.account_id.clone(), p.account_currency.clone()));
            }
        }
        self.flush_profits().await;
        let live_ms = std::env::var("ENGINE_ACCOUNT_LIVE_MS")
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(5000i64)
            .max(1000);
        let mut budget = 2;
        for (account_id, ccy) in accounts {
            if budget <= 0 {
                break;
            }
            let last = self.acct_live_at.get(&account_id).map(|v| *v).unwrap_or(0);
            if now - last < live_ms {
                continue;
            }
            self.acct_live_at.insert(account_id.clone(), now);
            budget -= 1;
            let Ok(Some(acct)) = self.load_account(tenant_id, &account_id).await else {
                continue;
            };
            let Ok(views) = self.open_views(tenant_id, &account_id, &ccy).await else {
                continue;
            };
            let after = compute_aggregates(acct.balance, acct.credit, &views);
            let snap = Snapshot {
                account_id: acct.id.clone(),
                login: acct.login,
                currency: acct.currency,
                leverage: acct.leverage,
                balance: acct.balance,
                credit: acct.credit,
                equity: after.equity,
                margin: after.margin,
                free_margin: after.free_margin,
                margin_level: after.margin_level,
                floating_pl: after.floating_pl,
                ts: now,
            };
            self.emit(tenant_id, json!({"kind":"ACCOUNT_UPDATE","tenantId":tenant_id,"account": snap.json()}))
                .await;
        }
    }

    async fn flush_profits(&self) {
        let mut last = self.last_profit_flush.lock().await;
        if last.elapsed().as_millis() < 2000 {
            return;
        }
        *last = Instant::now();
        drop(last);
        let rows: Vec<(String, f64)> = self.profit_dirty.iter().map(|e| (e.key().clone(), *e.value())).collect();
        self.profit_dirty.clear();
        for (id, profit) in rows {
            let _ = sqlx::query(r#"UPDATE positions SET profit=$1 WHERE id=$2 AND status='OPEN'"#)
                .bind(profit)
                .bind(id)
                .execute(&self.pool)
                .await;
        }
    }
}
