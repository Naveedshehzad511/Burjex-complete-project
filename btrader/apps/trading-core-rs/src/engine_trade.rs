use crate::books::PendingRow;
use crate::calc::{
    apply_markup, compute_aggregates, execution_applies, normalize_volume, point_size,
    required_margin, round_price, split_position_charges,
};
use crate::close_sync::{on_protective_close, on_user_close, CloseExecute};
use crate::engine::{Engine, ExecResult, PlaceReq};
use crate::error::{
    BtError, BtResult, INSUFFICIENT_MARGIN, INVALID_PRICE, INVALID_VOLUME, NO_PRICE,
    ORDER_NOT_FOUND, POSITION_NOT_FOUND, RATE_LIMITED, STOPS_TOO_CLOSE,
};
use crate::models::{account_from_row, now_ms, AccountRow, Snapshot, SymbolRow, ACCOUNT_SELECT};
use crate::policy::{audit_comment, close_apply_kind, create_plan, wait_for_deadline};
use crate::sessions::{parse_sessions, session_closes_at};
use crate::trigger::{pending_fires, PendingAction};
use chrono::{DateTime, Utc};
use serde_json::json;
use sqlx::Row;
use std::time::Instant;
use uuid::Uuid;

impl Engine {
    pub(crate) async fn place_pending(
        &self,
        tenant_id: &str,
        account: &AccountRow,
        sym: &SymbolRow,
        req: PlaceReq,
        volume: f64,
    ) -> BtResult<ExecResult> {
        let trigger_price = req.stop_price.or(req.price);
        let Some(trigger_price) = trigger_price else {
            return Err(BtError::new(INVALID_PRICE, "pending order needs price"));
        };
        self.assert_pending_trigger(
            tenant_id,
            &req.symbol,
            &req.order_type,
            &req.side,
            trigger_price,
            sym,
        )?;
        let pricing = self
            .group_pricing(account.group_id.as_deref(), sym, tenant_id)
            .await?;
        let apply_kind = crate::calc::pending_type_to_apply_kind(&req.order_type, &req.side);
        self.assert_fresh_quote(tenant_id, &req.symbol, &pricing, apply_kind)?;
        let tif = req
            .time_in_force
            .clone()
            .unwrap_or_else(|| "GTC".into())
            .to_ascii_uppercase();
        let mut expires_at = req
            .expires_at
            .as_ref()
            .and_then(|s| DateTime::parse_from_rfc3339(s).ok())
            .map(|d| d.with_timezone(&Utc));
        if tif == "DAY" && expires_at.is_none() {
            let sessions = parse_sessions(sym.trading_sessions.as_ref());
            expires_at = Some(session_closes_at(&sessions, &sym.class, Utc::now()));
        }
        let spec = crate::calc::SymbolCalcSpec {
            digits: sym.digits,
            pip_size: sym.pip_size,
            contract_size: sym.contract_size,
            margin_rate: sym.margin_rate,
            margin_percent: sym.margin_percent,
            quote_currency: sym.quote_currency.clone(),
            base_currency: sym.base_currency.clone(),
        };
        let conv =
            self.quote_to_account_strict(tenant_id, &account.currency, &spec.quote_currency)?;
        let est = required_margin(
            volume,
            &spec,
            trigger_price,
            f64::from(account.leverage),
            conv,
        );
        let views = self
            .open_views(tenant_id, &account.id, &account.currency)
            .await?;
        let agg = compute_aggregates(account.balance, account.credit, &views);
        if agg.free_margin < est {
            return Err(BtError::new(
                INSUFFICIENT_MARGIN,
                format!(
                    "insufficient free margin for pending order: need ~{est}, available {}",
                    agg.free_margin
                ),
            ));
        }
        let order_id = Uuid::new_v4().to_string();
        sqlx::query(
            r#"INSERT INTO orders (
                 id, "tenantId", "accountId", "symbolId", side, type, status, "timeInForce", volume,
                 price, "stopPrice", "requestedPrice", "slPrice", "tpPrice", "expiresAt", "slippagePoints",
                 comment, source, "clientOrderId", "stopTriggered", "updatedAt"
               ) VALUES (
                 $1,$2,$3,$4,$5::"OrderSide",$6::"OrderType",'PENDING'::"OrderStatus",$7::"TimeInForce",
                 $8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,false,NOW()
               )"#,
        )
        .bind(&order_id)
        .bind(tenant_id)
        .bind(&account.id)
        .bind(&sym.id)
        .bind(&req.side)
        .bind(&req.order_type)
        .bind(&tif)
        .bind(volume)
        .bind(req.price)
        .bind(req.stop_price)
        .bind(req.price.or(req.stop_price))
        .bind(req.sl_price)
        .bind(req.tp_price)
        .bind(expires_at)
        .bind(sym.slippage_points)
        .bind(&req.comment)
        .bind(req.source.as_deref().unwrap_or("api"))
        .bind(&req.client_order_id)
        .execute(&self.pool)
        .await?;

        let bid = self.prices.sell_price(tenant_id, &req.symbol);
        let ask = self.prices.buy_price(tenant_id, &req.symbol);
        let action = if let (Some(bid), Some(ask)) = (bid, ask) {
            pending_fires(
                &req.order_type,
                &req.side,
                bid,
                ask,
                trigger_price,
                req.stop_price,
                req.price,
                false,
            )
        } else {
            PendingAction::None
        };
        if (tif == "IOC" || tif == "FOK") && action != PendingAction::Fill {
            let st = if tif == "FOK" {
                "REJECTED"
            } else {
                "CANCELLED"
            };
            sqlx::query(
                r#"UPDATE orders SET status=$1::"OrderStatus", "rejectReason"=$2 WHERE id=$3"#,
            )
            .bind(st)
            .bind("IOC/FOK not immediately marketable")
            .bind(&order_id)
            .execute(&self.pool)
            .await?;
            return Ok(ExecResult {
                accepted: false,
                order_id: Some(order_id),
                position_id: None,
                status: st.into(),
                fill_price: None,
                filled_volume: None,
                reason: Some("not immediately marketable".into()),
                account: None,
            });
        }
        self.pendings.upsert(PendingRow {
            id: order_id.clone(),
            tenant_id: tenant_id.into(),
            account_id: account.id.clone(),
            symbol_id: sym.id.clone(),
            side: req.side.clone(),
            order_type: req.order_type.clone(),
            status: "PENDING".into(),
            volume,
            price: req.price,
            stop_price: req.stop_price,
            sl_price: req.sl_price,
            tp_price: req.tp_price,
            expires_at,
            updated_at: Utc::now(),
            stop_triggered: false,
        });
        if action == PendingAction::Fill {
            let n = sqlx::query(
                r#"UPDATE orders SET status='PARTIAL'::"OrderStatus", "triggeredAt"=NOW()
                   WHERE id=$1 AND status IN ('PENDING','PARTIAL')"#,
            )
            .bind(&order_id)
            .execute(&self.pool)
            .await?
            .rows_affected();
            if n > 0 {
                self.pendings.patch(&order_id, Some("PARTIAL"), None);
                let _ = self.fill_pending(tenant_id, &order_id).await;
            }
        }
        self.emit(
            tenant_id,
            json!({"kind":"ORDER_UPDATE","tenantId":tenant_id,"order":{"id":order_id,"status":"PENDING","symbol":req.symbol}}),
        )
        .await;
        Ok(ExecResult {
            accepted: true,
            order_id: Some(order_id),
            position_id: None,
            status: "PENDING".into(),
            fill_price: None,
            filled_volume: None,
            reason: None,
            account: None,
        })
    }

    fn assert_pending_trigger(
        &self,
        tenant_id: &str,
        symbol: &str,
        order_type: &str,
        side: &str,
        trigger_price: f64,
        sym: &SymbolRow,
    ) -> BtResult<()> {
        if !(trigger_price > 0.0) {
            return Err(BtError::new(INVALID_PRICE, "entry price must be positive"));
        }
        let bid = self.prices.sell_price(tenant_id, symbol);
        let ask = self.prices.buy_price(tenant_id, symbol);
        let (Some(bid), Some(ask)) = (bid, ask) else {
            return Err(BtError::new(NO_PRICE, "no live price for pending order"));
        };
        let t = order_type.to_ascii_uppercase();
        let s = side.to_ascii_uppercase();
        let is_buy = t == "BUY_LIMIT"
            || t == "BUY_STOP"
            || (s == "BUY" && matches!(t.as_str(), "LIMIT" | "STOP" | "STOP_LIMIT"));
        if t == "BUY_LIMIT" || (t == "LIMIT" && is_buy) {
            if !(trigger_price < ask) {
                return Err(BtError::new(
                    INVALID_PRICE,
                    format!("Buy Limit must be below Ask ({ask})"),
                ));
            }
        } else if t == "BUY_STOP" || (t == "STOP" && is_buy) || (t == "STOP_LIMIT" && is_buy) {
            if !(trigger_price > ask) {
                return Err(BtError::new(
                    INVALID_PRICE,
                    format!("Buy Stop must be above Ask ({ask})"),
                ));
            }
        } else if t == "SELL_LIMIT" || (t == "LIMIT" && !is_buy) {
            if !(trigger_price > bid) {
                return Err(BtError::new(
                    INVALID_PRICE,
                    format!("Sell Limit must be above Bid ({bid})"),
                ));
            }
        } else if t == "SELL_STOP" || (t == "STOP" && !is_buy) || (t == "STOP_LIMIT" && !is_buy) {
            if !(trigger_price < bid) {
                return Err(BtError::new(
                    INVALID_PRICE,
                    format!("Sell Stop must be below Bid ({bid})"),
                ));
            }
        }
        if sym.stops_level > 0 {
            let market = if is_buy { ask } else { bid };
            let min_dist = f64::from(sym.stops_level) * point_size(sym.digits);
            if (trigger_price - market).abs() < min_dist {
                return Err(BtError::new(
                    STOPS_TOO_CLOSE,
                    format!("entry too close to market (min {} points)", sym.stops_level),
                ));
            }
        }
        Ok(())
    }

    pub async fn close_position(
        &self,
        tenant_id: &str,
        position_id: &str,
        close_volume: Option<f64>,
        close_price_override: Option<f64>,
        protective_level: Option<f64>,
        protective_kind: Option<&str>,
        skip_delay: bool,
        require_account_id: Option<&str>,
        close_all: bool,
        floor_balance: bool,
        account_id_hint: Option<String>,
    ) -> BtResult<ExecResult> {
        let account_id = if let Some(a) = account_id_hint {
            a
        } else {
            let row = sqlx::query(r#"SELECT "accountId", status::text AS status FROM positions WHERE id=$1 AND "tenantId"=$2"#)
                .bind(position_id)
                .bind(tenant_id)
                .fetch_optional(&self.pool)
                .await?
                .ok_or_else(|| BtError::new(POSITION_NOT_FOUND, "position not found"))?;
            row.try_get("accountId").unwrap_or_default()
        };
        let pid = position_id.to_string();
        let tenant = tenant_id.to_string();
        let req_acct = require_account_id.map(|s| s.to_string());
        let pk = protective_kind.map(|s| s.to_string());
        self.with_account(&account_id, || {
            self.close_exclusive(
                tenant.clone(),
                pid.clone(),
                close_volume,
                close_price_override,
                protective_level,
                pk.clone(),
                skip_delay,
                req_acct.clone(),
                close_all,
                floor_balance,
            )
        })
        .await
    }

    async fn close_exclusive(
        &self,
        tenant_id: String,
        position_id: String,
        close_volume: Option<f64>,
        override_px: Option<f64>,
        protective_level: Option<f64>,
        protective_kind: Option<String>,
        skip_delay: bool,
        require_account_id: Option<String>,
        close_all: bool,
        floor_balance: bool,
    ) -> BtResult<ExecResult> {
        let row = sqlx::query(
            r#"SELECT p.id, p."accountId", p."symbolId", p.side::text AS side, p.volume::float8 AS volume,
                      p."openPrice"::float8 AS "openPrice", p."coveredVolume"::float8 AS "coveredVolume",
                      p.swap::float8 AS swap, p.commission::float8 AS commission,
                      p."slPrice"::float8 AS "slPrice", p."tpPrice"::float8 AS "tpPrice", p."openedAt",
                      p.status::text AS status,
                      a.currency, a.leverage, a."groupId", a.balance::float8 AS balance, a.credit::float8 AS credit, a.login,
                      s.symbol, s.digits, s."pipSize"::float8 AS "pipSize", s."contractSize"::float8 AS "contractSize",
                      s."marginRate"::float8 AS "marginRate", s."marginPercent"::float8 AS "marginPercent",
                      s."quoteCurrency", s."baseCurrency", s."minLot"::float8 AS "minLot", s."lotStep"::float8 AS "lotStep",
                      s.id AS sid, s."groupId" AS "symGroupId", s.class::text AS class, s."spreadMarkup", s."newsMode",
                      s."newsSpreadPoints", s."forceBook"::text AS "forceBook", s.enabled, s."slippagePoints",
                      s."stopsLevel", s."newsHaltOpens", s."tradingSessions", s."tenantId"
               FROM positions p
               JOIN accounts a ON a.id = p."accountId"
               JOIN symbols s ON s.id = p."symbolId"
               WHERE p.id=$1 AND p."tenantId"=$2
                 AND p.status IN ('OPEN'::"PositionStatus", 'CLOSE_PENDING'::"PositionStatus")"#,
        )
        .bind(&position_id)
        .bind(&tenant_id)
        .fetch_optional(&self.pool)
        .await?;
        let Some(row) = row else {
            let st = sqlx::query(
                r#"SELECT status::text AS status FROM positions WHERE id=$1 AND "tenantId"=$2"#,
            )
            .bind(&position_id)
            .bind(&tenant_id)
            .fetch_optional(&self.pool)
            .await?;
            if st
                .as_ref()
                .map(|r| r.try_get::<String, _>("status").unwrap_or_default())
                .unwrap_or_default()
                .eq_ignore_ascii_case("CLOSED")
            {
                return Ok(already_done(&position_id, "CLOSED"));
            }
            return Err(BtError::new(POSITION_NOT_FOUND, "position not found"));
        };

        let pos_status: String = row.try_get("status").unwrap_or_else(|_| "OPEN".into());
        if protective_kind.is_none() && on_user_close(&pos_status) == CloseExecute::IgnoreDuplicate
        {
            return Ok(already_done(&position_id, &pos_status));
        }
        if protective_kind.is_some()
            && on_protective_close(&pos_status) == CloseExecute::IgnoreDuplicate
        {
            return Ok(already_done(&position_id, "CLOSED"));
        }

        let account_id: String = row.try_get("accountId").unwrap_or_default();
        if let Some(req) = require_account_id {
            if req != account_id {
                return Err(BtError::new(
                    crate::error::VALIDATION,
                    "position access denied",
                ));
            }
        }
        if !floor_balance
            && protective_kind.is_none()
            && !skip_delay
            && !close_all
            && !self.allow_rate(&account_id)
        {
            return Err(BtError::new(RATE_LIMITED, "order rate limit"));
        }

        let side: String = row.try_get("side").unwrap_or_default();
        let symbol: String = row.try_get("symbol").unwrap_or_default();
        let digits: i32 = row.try_get("digits").unwrap_or(5);
        let group_id: Option<String> = row.try_get("groupId").ok();
        let spec = crate::calc::SymbolCalcSpec {
            digits,
            pip_size: row.try_get("pipSize").unwrap_or(0.0001),
            contract_size: row.try_get("contractSize").unwrap_or(100_000.0),
            margin_rate: row.try_get("marginRate").unwrap_or(1.0),
            margin_percent: row.try_get("marginPercent").ok(),
            quote_currency: row
                .try_get("quoteCurrency")
                .unwrap_or_else(|_| "USD".into()),
            base_currency: row.try_get("baseCurrency").unwrap_or_else(|_| "USD".into()),
        };
        let dummy_sym = SymbolRow {
            id: row.try_get("sid").unwrap_or_default(),
            tenant_id: tenant_id.clone(),
            symbol: symbol.clone(),
            class: row.try_get("class").unwrap_or_else(|_| "FOREX".into()),
            enabled: true,
            digits,
            pip_size: spec.pip_size,
            contract_size: spec.contract_size,
            min_lot: row.try_get("minLot").unwrap_or(0.01),
            max_lot: 100.0,
            lot_step: row.try_get("lotStep").unwrap_or(0.01),
            margin_rate: spec.margin_rate,
            margin_percent: spec.margin_percent,
            quote_currency: spec.quote_currency.clone(),
            base_currency: spec.base_currency.clone(),
            slippage_points: row.try_get("slippagePoints").unwrap_or(0),
            spread_markup: row.try_get("spreadMarkup").unwrap_or(0),
            stops_level: 0,
            news_mode: row.try_get("newsMode").unwrap_or(false),
            news_spread_points: row.try_get("newsSpreadPoints").unwrap_or(0),
            news_halt_opens: false,
            force_book: row.try_get("forceBook").ok(),
            group_id: row.try_get("symGroupId").ok(),
            trading_sessions: None,
        };

        let pricing = if override_px.is_none() {
            Some(
                self.group_pricing(group_id.as_deref(), &dummy_sym, &tenant_id)
                    .await?,
            )
        } else {
            None
        };
        let apply_kind = close_apply_kind(
            protective_kind.as_deref(),
            close_all,
            floor_balance,
            override_px.is_some(),
        );
        let plan = if let (Some(p), Some(kind)) = (pricing.as_ref(), apply_kind) {
            Some(create_plan(p, kind, Instant::now(), now_ms()))
        } else {
            None
        };
        if pricing.is_some() && !skip_delay && !floor_balance && override_px.is_none() {
            wait_for_deadline(plan.as_ref()).await;
        }

        let px = if let Some(o) = override_px.filter(|v| *v > 0.0) {
            o
        } else if side.eq_ignore_ascii_case("BUY") {
            self.prices
                .sell_price(&tenant_id, &symbol)
                .ok_or_else(|| BtError::new(NO_PRICE, "no price"))?
        } else {
            self.prices
                .buy_price(&tenant_id, &symbol)
                .ok_or_else(|| BtError::new(NO_PRICE, "no price"))?
        };
        if let (Some(pricing), Some(kind)) = (pricing.as_ref(), apply_kind) {
            self.assert_fresh_quote(&tenant_id, &symbol, pricing, kind)?;
        }
        let mut close_px = px;
        if override_px.is_none() {
            if let Some(pricing) = pricing.as_ref() {
                let applies_prot = protective_kind
                    .as_ref()
                    .is_some_and(|k| execution_applies(&pricing.execution_apply_to, k));
                if let Some(lvl) = protective_level.filter(|v| *v > 0.0) {
                    if applies_prot {
                        // SL/TP selected in apply-to: honour the trigger level.
                        // MARKET mode only adds executionDelayMs wait (already done);
                        // it must NOT fill further through the level after that wait —
                        // that is what made BUY SL closes print below the SL line.
                        close_px = lvl;
                    } else {
                        // apply-to unchecked: live market, gap may slip through the level.
                        let close_side = if side.eq_ignore_ascii_case("BUY") {
                            "SELL"
                        } else {
                            "BUY"
                        };
                        let total = pricing.markup_points + pricing.slippage_points;
                        if total != 0.0 {
                            close_px = apply_markup(close_side, px, total, digits);
                        }
                        close_px = if side.eq_ignore_ascii_case("BUY") {
                            close_px.min(lvl)
                        } else {
                            close_px.max(lvl)
                        };
                    }
                } else {
                    let close_side = if side.eq_ignore_ascii_case("BUY") {
                        "SELL"
                    } else {
                        "BUY"
                    };
                    let total = pricing.markup_points + pricing.slippage_points;
                    if total != 0.0 {
                        close_px = apply_markup(close_side, px, total, digits);
                    }
                }
            }
        }
        let close_price = round_price(close_px, digits);
        let conv = self.quote_to_account(
            &tenant_id,
            &row.try_get::<String, _>("currency")
                .unwrap_or_else(|_| "USD".into()),
            &spec.quote_currency,
        );
        let _currency: String = row.try_get("currency").unwrap_or_else(|_| "USD".into());
        let leverage: i32 = row.try_get("leverage").unwrap_or(100);
        let login: String = row.try_get("login").unwrap_or_default();
        let _credit: f64 = row.try_get("credit").unwrap_or(0.0);
        let min_lot: f64 = dummy_sym.min_lot;
        let lot_step: f64 = dummy_sym.lot_step;
        let open_price: f64 = row.try_get("openPrice").unwrap_or(0.0);

        let mut tx = self.pool.begin().await?;
        sqlx::query("SELECT id FROM accounts WHERE id = $1 FOR UPDATE")
            .bind(&account_id)
            .execute(&mut *tx)
            .await?;
        sqlx::query("SELECT id FROM positions WHERE id = $1 FOR UPDATE")
            .bind(&position_id)
            .execute(&mut *tx)
            .await?;
        let fresh = sqlx::query(
            r#"SELECT volume::float8 AS volume, "coveredVolume"::float8 AS "coveredVolume",
                      swap::float8 AS swap, commission::float8 AS commission, side::text AS side,
                      "openPrice"::float8 AS "openPrice"
               FROM positions WHERE id=$1 AND status IN ('OPEN'::"PositionStatus", 'CLOSE_PENDING'::"PositionStatus")"#,
        )
        .bind(&position_id)
        .fetch_optional(&mut *tx)
        .await?;
        let Some(fresh) = fresh else {
            tx.rollback().await.ok();
            return Ok(already_done(&position_id, "CLOSED"));
        };
        let acct = sqlx::query(&format!("{ACCOUNT_SELECT} WHERE id=$1"))
            .bind(&account_id)
            .fetch_one(&mut *tx)
            .await?;
        let acct = account_from_row(&acct);
        let open_vol: f64 = fresh.try_get("volume").unwrap_or(0.0);
        let mut vol = close_volume
            .map(|v| normalize_volume(v, min_lot, open_vol, lot_step))
            .unwrap_or(open_vol);
        if vol > open_vol {
            vol = open_vol;
        }
        if !(vol > 0.0) {
            return Err(BtError::new(
                INVALID_VOLUME,
                "close volume must be positive",
            ));
        }
        let partial = vol < open_vol;
        let covered_before: f64 = fresh.try_get("coveredVolume").unwrap_or(0.0);
        let cover_to_close = if open_vol > 0.0 {
            covered_before.min(round_lots_local(
                (covered_before * vol) / open_vol,
                lot_step,
            ))
        } else {
            0.0
        };
        let swap: f64 = fresh.try_get("swap").unwrap_or(0.0);
        let commission: f64 = fresh.try_get("commission").unwrap_or(0.0);
        let charges = split_position_charges(swap, commission, vol, open_vol);
        let mut realized =
            crate::calc::position_profit(&side, vol, open_price, close_price, &spec, conv)
                + charges.0
                + charges.1;
        if floor_balance && acct.balance + realized < 0.0 {
            realized = -acct.balance;
        }
        let new_balance = acct.balance + realized;
        let deal_id = Uuid::new_v4().to_string();
        let comment = audit_comment(
            plan.as_ref(),
            json!({"fillPrice": close_price, "result": "closed", "partial": partial}),
        );
        sqlx::query(
            r#"INSERT INTO deals (id, "tenantId", "accountId", "positionId", "symbolId", type, side, volume, price, profit, "balanceAfter", comment)
               VALUES ($1,$2,$3,$4,$5,$6::"DealType",$7::"OrderSide",$8,$9,$10,$11,$12)"#,
        )
        .bind(&deal_id)
        .bind(&tenant_id)
        .bind(&account_id)
        .bind(&position_id)
        .bind(&dummy_sym.id)
        .bind(if partial { "PARTIAL_CLOSE" } else { "CLOSE" })
        .bind(&side)
        .bind(vol)
        .bind(close_price)
        .bind(realized)
        .bind(new_balance)
        .bind(&comment)
        .execute(&mut *tx)
        .await?;
        if partial {
            let remaining = open_vol - vol;
            let new_margin =
                required_margin(remaining, &spec, open_price, f64::from(leverage), conv);
            sqlx::query(
                r#"UPDATE positions SET volume=$1, "marginUsed"=$2, "coveredVolume"=$3, swap=$4, commission=$5 WHERE id=$6"#,
            )
            .bind(remaining)
            .bind(new_margin)
            .bind((covered_before - cover_to_close).max(0.0))
            .bind(charges.2)
            .bind(charges.3)
            .bind(&position_id)
            .execute(&mut *tx)
            .await?;
        } else {
            sqlx::query(
                r#"UPDATE positions SET status='CLOSED'::"PositionStatus", volume=0, "coveredVolume"=0,
                   "closePrice"=$1, profit=$2, "marginUsed"=0, "closedAt"=NOW() WHERE id=$3"#,
            )
            .bind(close_price)
            .bind(realized)
            .bind(&position_id)
            .execute(&mut *tx)
            .await?;
        }
        let views = self
            .open_views_tx(&mut tx, &tenant_id, &account_id, &acct.currency)
            .await?;
        let after = compute_aggregates(new_balance, acct.credit, &views);
        sqlx::query(
            r#"UPDATE accounts SET balance=$1, equity=$2, margin=$3, "freeMargin"=$4, "marginLevel"=$5, "floatingPL"=$6 WHERE id=$7"#,
        )
        .bind(new_balance)
        .bind(after.equity)
        .bind(after.margin)
        .bind(after.free_margin)
        .bind(after.margin_level)
        .bind(after.floating_pl)
        .bind(&acct.id)
        .execute(&mut *tx)
        .await?;
        let commit_started = Instant::now();
        tx.commit().await?;
        tracing::debug!(
            position_id = %position_id,
            sql_commit_ms = commit_started.elapsed().as_millis() as u64,
            "trade-hop sql_commit"
        );
        self.claims.mark_closed(&position_id);
        if partial {
            let remaining = open_vol - vol;
            let new_margin =
                required_margin(remaining, &spec, open_price, f64::from(leverage), conv);
            self.book.map(&position_id, |r| {
                r.volume = remaining;
                r.margin_used = new_margin;
                r.covered_volume = (covered_before - cover_to_close).max(0.0);
                r.swap = charges.2;
                r.commission = charges.3;
            });
        } else {
            self.book.remove(&position_id);
        }
        self.redis_sync_open_positions(&tenant_id, &account_id)
            .await;
        let snap = Snapshot {
            account_id: account_id.clone(),
            login,
            currency: acct.currency,
            leverage: acct.leverage,
            balance: new_balance,
            credit: acct.credit,
            equity: after.equity,
            margin: after.margin,
            free_margin: after.free_margin,
            margin_level: after.margin_level,
            floating_pl: after.floating_pl,
            ts: now_ms(),
        };
        let alias = self.client_alias(group_id.as_deref(), &symbol).await;
        let close_reason = match protective_kind.as_deref() {
            Some("tp") => "TP_HIT",
            Some("sl") => "SL_HIT",
            _ => "CLOSED",
        };
        self.publish_after_fill(
            &tenant_id,
            &account_id,
            &position_id,
            None,
            "closed",
            &snap,
            Some(realized),
            Some(json!({
                "symbol": alias,
                "volume": vol,
                "dealId": deal_id,
                "tradeId": position_id,
                "partial": partial,
                "reason": close_reason
            })),
        )
        .await;
        Ok(ExecResult {
            accepted: true,
            order_id: None,
            position_id: Some(position_id),
            status: "FILLED".into(),
            fill_price: Some(close_price),
            filled_volume: Some(vol),
            reason: None,
            account: Some(snap.json()),
        })
    }

    pub async fn close_all(&self, tenant_id: &str, account_id: &str) -> BtResult<i64> {
        let aid = account_id.to_string();
        let tenant = tenant_id.to_string();
        self.with_account(&aid, || {
            self.close_all_exclusive(tenant.clone(), aid.clone())
        })
        .await
    }

    async fn close_all_exclusive(&self, tenant_id: String, account_id: String) -> BtResult<i64> {
        let rows = sqlx::query(
            r#"SELECT id FROM positions WHERE "tenantId"=$1 AND "accountId"=$2 AND status='OPEN'"#,
        )
        .bind(&tenant_id)
        .bind(&account_id)
        .fetch_all(&self.pool)
        .await?;
        let mut closed = 0i64;
        for r in rows {
            let id: String = r.try_get("id").unwrap_or_default();
            if self
                .close_exclusive(
                    tenant_id.clone(),
                    id,
                    None,
                    None,
                    None,
                    None,
                    true,
                    None,
                    true,
                    false,
                )
                .await
                .is_ok()
            {
                closed += 1;
            }
        }
        Ok(closed)
    }

    pub async fn modify_position(
        &self,
        tenant_id: &str,
        position_id: &str,
        sl: Option<Option<f64>>,
        tp: Option<Option<f64>>,
    ) -> BtResult<serde_json::Value> {
        let row = sqlx::query(
            r#"SELECT p.id, p.side::text AS side, p."slPrice"::float8 AS "slPrice", p."tpPrice"::float8 AS "tpPrice",
                      p."accountId", a."groupId", s.symbol, s.digits, s.id AS sid, s.class::text AS class,
                      s."quoteCurrency", s."baseCurrency", s."pipSize"::float8 AS "pipSize",
                      s."contractSize"::float8 AS "contractSize", s."marginRate"::float8 AS "marginRate",
                      s."spreadMarkup", s."newsMode", s."newsSpreadPoints", s."slippagePoints"
               FROM positions p JOIN accounts a ON a.id=p."accountId" JOIN symbols s ON s.id=p."symbolId"
               WHERE p.id=$1 AND p."tenantId"=$2 AND p.status='OPEN'"#,
        )
        .bind(position_id)
        .bind(tenant_id)
        .fetch_optional(&self.pool)
        .await?
        .ok_or_else(|| BtError::new(POSITION_NOT_FOUND, "position not found"))?;
        let is_buy: bool = row
            .try_get::<String, _>("side")
            .unwrap_or_default()
            .eq_ignore_ascii_case("BUY");
        let symbol: String = row.try_get("symbol").unwrap_or_default();
        let digits: i32 = row.try_get("digits").unwrap_or(5);
        let dummy = SymbolRow {
            id: row.try_get("sid").unwrap_or_default(),
            tenant_id: tenant_id.into(),
            symbol: symbol.clone(),
            class: row.try_get("class").unwrap_or_else(|_| "FOREX".into()),
            enabled: true,
            digits,
            pip_size: row.try_get("pipSize").unwrap_or(0.0001),
            contract_size: row.try_get("contractSize").unwrap_or(100_000.0),
            min_lot: 0.01,
            max_lot: 100.0,
            lot_step: 0.01,
            margin_rate: row.try_get("marginRate").unwrap_or(1.0),
            margin_percent: None,
            quote_currency: row
                .try_get("quoteCurrency")
                .unwrap_or_else(|_| "USD".into()),
            base_currency: row.try_get("baseCurrency").unwrap_or_else(|_| "USD".into()),
            slippage_points: row.try_get("slippagePoints").unwrap_or(0),
            spread_markup: row.try_get("spreadMarkup").unwrap_or(0),
            stops_level: 0,
            news_mode: row.try_get("newsMode").unwrap_or(false),
            news_spread_points: row.try_get("newsSpreadPoints").unwrap_or(0),
            news_halt_opens: false,
            force_book: None,
            group_id: None,
            trading_sessions: None,
        };
        let gid: Option<String> = row.try_get("groupId").ok();
        let _pricing = self
            .group_pricing(gid.as_deref(), &dummy, tenant_id)
            .await?;
        // Validate against Redis/client tick (same as chart) — no second markup.
        let bid = self.prices.sell_price(tenant_id, &symbol);
        let ask = self.prices.buy_price(tenant_id, &symbol);
        let mut next_sl: Option<f64> = row.try_get("slPrice").ok();
        let mut next_tp: Option<f64> = row.try_get("tpPrice").ok();
        if let Some(v) = sl {
            next_sl = v;
        }
        if let Some(v) = tp {
            next_tp = v;
        }
        if let (Some(bid), Some(ask)) = (bid, ask) {
            if let Err(msg) = crate::trigger::validate_sl_tp(
                if is_buy { "BUY" } else { "SELL" },
                bid,
                ask,
                next_sl,
                next_tp,
            ) {
                return Err(BtError::new(INVALID_PRICE, msg));
            }
        }
        sqlx::query(r#"UPDATE positions SET "slPrice"=$1, "tpPrice"=$2 WHERE id=$3"#)
            .bind(next_sl)
            .bind(next_tp)
            .bind(position_id)
            .execute(&self.pool)
            .await?;
        self.book.map(position_id, |r| {
            r.sl_price = next_sl;
            r.tp_price = next_tp;
        });
        let account_id: String = row.try_get("accountId").unwrap_or_default();
        self.redis_sync_open_positions(tenant_id, &account_id).await;
        Ok(json!({"slPrice": next_sl, "tpPrice": next_tp}))
    }

    pub(crate) fn quoted_bid_ask(
        &self,
        tenant_id: &str,
        symbol: &str,
        sym: &SymbolRow,
        pricing: &crate::calc::GroupPricing,
    ) -> Option<(f64, f64)> {
        let bid = self.prices.sell_price(tenant_id, symbol)?;
        let ask = self.prices.buy_price(tenant_id, symbol)?;
        let news = if sym.news_mode {
            f64::from(sym.news_spread_points)
        } else {
            0.0
        };
        let mapping_owns = matches!(
            pricing.pricing_method.as_deref(),
            Some("SPREAD_ONLY" | "SPREAD_AND_COMMISSION" | "COMMISSION_ONLY")
        );
        let symbol_book = if mapping_owns {
            0.0
        } else {
            f64::from(sym.spread_markup)
        };
        let total = symbol_book + pricing.markup_points + news;
        Some((
            apply_markup("SELL", bid, total, sym.digits),
            apply_markup("BUY", ask, total, sym.digits),
        ))
    }

    pub async fn cancel_order(&self, tenant_id: &str, order_id: &str) -> BtResult<()> {
        let n = sqlx::query(
            r#"UPDATE orders SET status='CANCELLED'::"OrderStatus"
               WHERE id=$1 AND "tenantId"=$2
                 AND (status='PENDING' OR (status='PARTIAL' AND "positionId" IS NULL))"#,
        )
        .bind(order_id)
        .bind(tenant_id)
        .execute(&self.pool)
        .await?
        .rows_affected();
        if n == 0 {
            return Err(BtError::new(ORDER_NOT_FOUND, "order not found"));
        }
        self.pendings.remove(order_id);
        self.emit(tenant_id, json!({"kind":"ORDER_UPDATE","tenantId":tenant_id,"order":{"id":order_id,"status":"CANCELLED"}}))
            .await;
        Ok(())
    }

    pub async fn modify_order(
        &self,
        tenant_id: &str,
        order_id: &str,
        price: Option<Option<f64>>,
        stop_price: Option<Option<f64>>,
        sl: Option<Option<f64>>,
        tp: Option<Option<f64>>,
    ) -> BtResult<()> {
        let row = sqlx::query(
            r#"SELECT o.id, o.side::text AS side, o.type::text AS type,
                      o.price::float8 AS price, o."stopPrice"::float8 AS "stopPrice",
                      o."slPrice"::float8 AS "slPrice", o."tpPrice"::float8 AS "tpPrice",
                      s.symbol, s.digits, s."stopsLevel", s.id AS sid, s.class::text AS class
               FROM orders o JOIN symbols s ON s.id=o."symbolId"
               WHERE o.id=$1 AND o."tenantId"=$2 AND o.status='PENDING'"#,
        )
        .bind(order_id)
        .bind(tenant_id)
        .fetch_optional(&self.pool)
        .await?
        .ok_or_else(|| BtError::new(ORDER_NOT_FOUND, "order not found"))?;
        let cur_price: Option<f64> = row.try_get("price").ok();
        let cur_stop: Option<f64> = row.try_get("stopPrice").ok();
        let next_price = match price {
            Some(v) => v,
            None => cur_price,
        };
        let next_stop = match stop_price {
            Some(v) => v,
            None => cur_stop,
        };
        let trigger = next_stop
            .or(next_price)
            .ok_or_else(|| BtError::new(INVALID_PRICE, "pending order needs price"))?;
        let dummy = SymbolRow {
            id: row.try_get("sid").unwrap_or_default(),
            tenant_id: tenant_id.into(),
            symbol: row.try_get("symbol").unwrap_or_default(),
            class: row.try_get("class").unwrap_or_else(|_| "FOREX".into()),
            enabled: true,
            digits: row.try_get("digits").unwrap_or(5),
            pip_size: 0.0001,
            contract_size: 100_000.0,
            min_lot: 0.01,
            max_lot: 100.0,
            lot_step: 0.01,
            margin_rate: 1.0,
            margin_percent: None,
            quote_currency: "USD".into(),
            base_currency: "USD".into(),
            slippage_points: 0,
            spread_markup: 0,
            stops_level: row.try_get("stopsLevel").unwrap_or(0),
            news_mode: false,
            news_spread_points: 0,
            news_halt_opens: false,
            force_book: None,
            group_id: None,
            trading_sessions: None,
        };
        let side: String = row.try_get("side").unwrap_or_default();
        let ot: String = row.try_get("type").unwrap_or_default();
        self.assert_pending_trigger(tenant_id, &dummy.symbol, &ot, &side, trigger, &dummy)?;
        sqlx::query(
            r#"UPDATE orders SET price=$1, "stopPrice"=$2, "requestedPrice"=$3, "slPrice"=COALESCE($4,"slPrice"), "tpPrice"=COALESCE($5,"tpPrice") WHERE id=$6"#,
        )
        .bind(next_price)
        .bind(next_stop)
        .bind(trigger)
        .bind(sl.flatten())
        .bind(tp.flatten())
        .bind(order_id)
        .execute(&self.pool)
        .await?;
        self.pendings.map(order_id, |r| {
            r.price = next_price;
            r.stop_price = next_stop;
            if let Some(v) = sl {
                r.sl_price = v;
            }
            if let Some(v) = tp {
                r.tp_price = v;
            }
        });
        Ok(())
    }

    pub async fn set_open_price(
        &self,
        tenant_id: &str,
        position_id: &str,
        new_open: f64,
    ) -> BtResult<()> {
        if !(new_open > 0.0) {
            return Err(BtError::new(INVALID_PRICE, "open price must be positive"));
        }
        sqlx::query(r#"UPDATE positions SET "openPrice"=$1 WHERE id=$2 AND "tenantId"=$3 AND status='OPEN'"#)
            .bind(new_open)
            .bind(position_id)
            .bind(tenant_id)
            .execute(&self.pool)
            .await?;
        self.book.map(position_id, |r| r.open_price = new_open);
        Ok(())
    }

    pub async fn cover_more(
        &self,
        tenant_id: &str,
        position_id: &str,
        lots: f64,
    ) -> BtResult<serde_json::Value> {
        let row = sqlx::query(
            r#"SELECT volume::float8 AS volume, "coveredVolume"::float8 AS covered FROM positions
               WHERE id=$1 AND "tenantId"=$2 AND status='OPEN'"#,
        )
        .bind(position_id)
        .bind(tenant_id)
        .fetch_optional(&self.pool)
        .await?
        .ok_or_else(|| BtError::new(POSITION_NOT_FOUND, "position not found"))?;
        let volume: f64 = row.try_get("volume").unwrap_or(0.0);
        let covered: f64 = row.try_get("covered").unwrap_or(0.0);
        let warehoused = (volume - covered).max(0.0);
        let n = lots.max(0.0).min(warehoused);
        if n <= 0.0 {
            return Ok(json!({"covered": covered, "warehoused": warehoused}));
        }
        sqlx::query(r#"UPDATE positions SET "coveredVolume"=$1 WHERE id=$2"#)
            .bind(covered + n)
            .bind(position_id)
            .execute(&self.pool)
            .await?;
        self.book
            .map(position_id, |r| r.covered_volume = covered + n);
        Ok(json!({"covered": covered + n, "warehoused": warehoused - n}))
    }
}

fn already_done(position_id: &str, status: &str) -> ExecResult {
    let st = if status.eq_ignore_ascii_case("CLOSE_PENDING") {
        "CLOSE_PENDING"
    } else {
        "CLOSED"
    };
    ExecResult {
        accepted: true,
        order_id: None,
        position_id: Some(position_id.to_string()),
        status: st.into(),
        fill_price: None,
        filled_volume: None,
        reason: Some(if st == "CLOSED" {
            "already_closed".into()
        } else {
            "already_closing".into()
        }),
        account: None,
    }
}

fn round_lots_local(v: f64, step: f64) -> f64 {
    crate::calc::round_lots(v, step)
}
