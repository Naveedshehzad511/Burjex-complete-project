use crate::books::{BookRow, MemoryClaims, PendingBook, PositionBook};
use crate::calc::{
    apply_markup, compute_aggregates, dealing_commission, execution_applies,
    pending_type_to_apply_kind, required_margin, round_lots, round_price, slippage_bound,
    snap_volume, SymbolCalcSpec,
};
use crate::error::{
    BtError, BtResult, INSUFFICIENT_MARGIN, INVALID_PRICE, INVALID_VOLUME, MARKET_CLOSED, NO_PRICE,
    RATE_LIMITED, SYMBOL_DISABLED, TRADING_DISABLED, VALIDATION,
};
use crate::models::{account_from_row, now_ms, AccountRow, Snapshot, SymbolRow, ACCOUNT_SELECT};
use crate::policy::{audit_comment, create_plan, wait_for_deadline, ExecutionPlan};
use crate::prices::PriceSource;
use crate::routing::{resolve_routing, RoutingContext, RoutingRuleLike};
use crate::sessions::{is_symbol_tradable, parse_sessions};
use chrono::Utc;
use dashmap::DashMap;
use redis::AsyncCommands;
use serde::Deserialize;
use serde_json::json;
use sqlx::PgPool;
use std::collections::HashMap;
use std::sync::Arc;
use std::time::Instant;
use tokio::sync::Mutex;
use uuid::Uuid;

pub(crate) const SYMBOL_CACHE_MS: u128 = 30_000;
pub(crate) const CONFIG_CACHE_MS: u128 = 2_000;

pub struct Engine {
    pub pool: PgPool,
    pub redis: Mutex<redis::aio::MultiplexedConnection>,
    pub prices: Arc<PriceSource>,
    pub book: PositionBook,
    pub pendings: PendingBook,
    pub claims: MemoryClaims,
    pub(crate) symbol_cache: DashMap<String, (SymbolRow, Instant)>,
    pub(crate) group_cache: DashMap<String, (GroupBundle, Instant)>,
    pub(crate) acct_group: DashMap<String, Option<String>>,
    pub(crate) routing_cache: DashMap<String, (Vec<RoutingRuleLike>, Instant)>,
    rate_hits: DashMap<String, Vec<i64>>,
    account_locks: Mutex<HashMap<String, Arc<Mutex<()>>>>,
    pub(crate) profit_dirty: DashMap<String, f64>,
    pub(crate) last_profit_flush: Mutex<Instant>,
    pub(crate) live_throttle: DashMap<String, i64>,
    pub(crate) acct_live_at: DashMap<String, i64>,
    pub(crate) stop_out_checked: DashMap<String, i64>,
    /// Tightest configured quote-age limit. Groups with an execution delay use
    /// the smaller of this and their delay, so a 1ms group cannot fill a quote
    /// that was already stale before its configured delay expired.
    pub max_price_age_ms: i64,
    pub max_feed_still_ms: i64,
    order_rate_max: usize,
    order_rate_window_ms: i64,
}

#[derive(Clone)]
pub(crate) struct GroupBundle {
    pub enabled: bool,
    pub markup_points: f64,
    pub slippage_points: f64,
    pub commission_type: String,
    pub commission_value: f64,
    pub execution_mode: String,
    pub execution_delay_ms: i32,
    pub execution_apply_to: serde_json::Value,
    pub rules: Vec<MarkupRule>,
    pub mappings: Vec<MappingRow>,
}

#[derive(Clone)]
pub(crate) struct MarkupRule {
    pub symbol_id: Option<String>,
    pub instrument_class: Option<String>,
    pub markup_points: f64,
    pub commission_type: Option<String>,
    pub commission_value: Option<f64>,
}

#[derive(Clone)]
pub(crate) struct MappingRow {
    pub enabled: bool,
    pub symbol_id: Option<String>,
    pub lp_symbol: String,
    pub pricing_method: String,
    pub min_spread_points: f64,
    pub max_spread_points: f64,
    pub commission_type: String,
    pub commission_value: f64,
}

#[derive(Debug, Deserialize, Clone)]
pub struct PlaceReq {
    pub account_id: String,
    pub symbol: String,
    pub side: String,
    pub order_type: String,
    pub volume: f64,
    pub price: Option<f64>,
    pub stop_price: Option<f64>,
    pub sl_price: Option<f64>,
    pub tp_price: Option<f64>,
    pub time_in_force: Option<String>,
    pub expires_at: Option<String>,
    pub comment: Option<String>,
    pub one_click: Option<bool>,
    pub client_order_id: Option<String>,
    pub source: Option<String>,
}

#[derive(Debug, Clone)]
pub struct ExecResult {
    pub accepted: bool,
    pub order_id: Option<String>,
    pub position_id: Option<String>,
    pub status: String,
    pub fill_price: Option<f64>,
    pub filled_volume: Option<f64>,
    pub reason: Option<String>,
    pub account: Option<serde_json::Value>,
}

impl ExecResult {
    pub fn json(&self) -> serde_json::Value {
        json!({
            "accepted": self.accepted,
            "orderId": self.order_id,
            "positionId": self.position_id,
            "status": self.status,
            "fillPrice": self.fill_price,
            "filledVolume": self.filled_volume,
            "reason": self.reason,
            "account": self.account,
        })
    }
}

pub(crate) fn spec_of(sym: &SymbolRow) -> SymbolCalcSpec {
    SymbolCalcSpec {
        digits: sym.digits,
        pip_size: sym.pip_size,
        contract_size: sym.contract_size,
        margin_rate: sym.margin_rate,
        margin_percent: sym.margin_percent,
        quote_currency: sym.quote_currency.clone(),
        base_currency: sym.base_currency.clone(),
    }
}

fn env_i64(key: &str, default: i64) -> i64 {
    std::env::var(key)
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(default)
}

pub(crate) fn quote_age_limit_ms(
    configured_max_age_ms: i64,
    pricing: &crate::calc::GroupPricing,
    kind: &str,
) -> i64 {
    let configured = configured_max_age_ms.max(1);
    // Pending activation is intentionally permitted to be faster than the
    // configured delay, but it must still use a quote no older than that
    // group's budget. Do not derive this from market_execution_delay_ms:
    // pending orders may have a zero intentional sleep.
    let group_delay = if pricing.execution_mode.eq_ignore_ascii_case("MARKET")
        && execution_applies(&pricing.execution_apply_to, kind)
    {
        i64::from(pricing.execution_delay_ms.max(0))
    } else {
        0
    };
    if group_delay > 0 {
        configured.min(group_delay)
    } else {
        configured
    }
}

impl Engine {
    pub fn new(
        pool: PgPool,
        redis: redis::aio::MultiplexedConnection,
        prices: Arc<PriceSource>,
    ) -> Self {
        Self {
            pool,
            redis: Mutex::new(redis),
            prices,
            book: PositionBook::new(),
            pendings: PendingBook::new(),
            claims: MemoryClaims::new(),
            symbol_cache: DashMap::new(),
            group_cache: DashMap::new(),
            acct_group: DashMap::new(),
            routing_cache: DashMap::new(),
            rate_hits: DashMap::new(),
            account_locks: Mutex::new(HashMap::new()),
            profit_dirty: DashMap::new(),
            last_profit_flush: Mutex::new(Instant::now()),
            live_throttle: DashMap::new(),
            acct_live_at: DashMap::new(),
            stop_out_checked: DashMap::new(),
            max_price_age_ms: env_i64("MAX_PRICE_AGE_MS", 1000),
            max_feed_still_ms: env_i64("MAX_FEED_STILL_MS", 120_000),
            order_rate_max: env_i64("ORDER_RATE_MAX", 40) as usize,
            order_rate_window_ms: env_i64("ORDER_RATE_WINDOW_MS", 1000),
        }
    }

    pub fn invalidate_group(&self, group_id: Option<&str>) {
        if let Some(id) = group_id {
            self.group_cache.remove(id);
        } else {
            self.group_cache.clear();
        }
        self.acct_group.clear();
        self.routing_cache.clear();
    }

    pub(crate) async fn with_account<T, F, Fut>(&self, account_id: &str, f: F) -> BtResult<T>
    where
        F: FnOnce() -> Fut,
        Fut: std::future::Future<Output = BtResult<T>>,
    {
        let lock = {
            let mut map = self.account_locks.lock().await;
            map.entry(account_id.to_string())
                .or_insert_with(|| Arc::new(Mutex::new(())))
                .clone()
        };
        // The lock guards account-level atomicity and client-order idempotency,
        // but must never become a hidden 40–100ms execution queue. The caller
        // receives a retryable busy result immediately instead of waiting past
        // the trading group's execution_ms budget.
        let _guard = lock.try_lock().map_err(|_| {
            BtError::new(
                RATE_LIMITED,
                "account busy — retry with the same client order id",
            )
        })?;
        f().await
    }

    pub(crate) fn allow_rate(&self, account_id: &str) -> bool {
        let now = now_ms();
        let cutoff = now - self.order_rate_window_ms;
        let mut arr = self.rate_hits.entry(account_id.to_string()).or_default();
        arr.retain(|t| *t >= cutoff);
        if arr.len() >= self.order_rate_max {
            return false;
        }
        arr.push(now);
        true
    }

    pub(crate) fn quote_age_limit_ms(
        &self,
        pricing: &crate::calc::GroupPricing,
        kind: &str,
    ) -> i64 {
        quote_age_limit_ms(self.max_price_age_ms, pricing, kind)
    }

    pub(crate) fn assert_fresh_quote(
        &self,
        tenant_id: &str,
        symbol: &str,
        pricing: &crate::calc::GroupPricing,
        kind: &str,
    ) -> BtResult<()> {
        let max_age_ms = self.quote_age_limit_ms(pricing, kind);
        match self.prices.age_ms(tenant_id, symbol) {
            Some(age) if age <= max_age_ms => {}
            _ => {
                return Err(BtError::new(
                    NO_PRICE,
                    format!("no live price (quote exceeds {max_age_ms}ms age limit)"),
                ));
            }
        }
        if self.max_feed_still_ms > 0
            && self
                .prices
                .still_ms(tenant_id)
                .is_some_and(|still| still > self.max_feed_still_ms)
        {
            return Err(BtError::new(NO_PRICE, "feed frozen — no price movement"));
        }
        Ok(())
    }

    pub async fn emit(&self, tenant_id: &str, mut evt: serde_json::Value) {
        // This timestamp is carried through Redis to the WS gateway, where it
        // becomes a measurable matcher→Redis→WS hop instead of an opaque delay.
        if let Some(obj) = evt.as_object_mut() {
            obj.entry("emittedAt".to_string())
                .or_insert_with(|| json!(now_ms()));
        }
        let ch = format!("bt:{tenant_id}:engine.evt");
        let payload = evt.to_string();
        let queued = Instant::now();
        let mut r = self.redis.lock().await;
        let redis_lock_ms = queued.elapsed().as_millis() as u64;
        let publish_started = Instant::now();
        let _: Result<(), _> = r.publish::<_, _, ()>(ch, payload).await;
        tracing::debug!(
            redis_lock_ms,
            redis_publish_ms = publish_started.elapsed().as_millis() as u64,
            "trade-hop redis_publish"
        );
    }

    /// Authoritative open-position snapshot for WS reconnect (no REST poll).
    pub(crate) async fn redis_sync_open_positions(&self, tenant_id: &str, account_id: &str) {
        let positions: Vec<serde_json::Value> = self
            .book
            .for_account(tenant_id, account_id)
            .into_iter()
            .map(|p| {
                json!({
                    "id": p.id,
                    "accountId": p.account_id,
                    "symbol": p.symbol,
                    "side": p.side,
                    "status": p.status,
                    "volume": p.volume,
                    "openPrice": p.open_price,
                    "slPrice": p.sl_price,
                    "tpPrice": p.tp_price,
                })
            })
            .collect();
        let key = format!("bt:{tenant_id}:openpos:{account_id}");
        let payload = json!({ "v": 1, "positions": positions }).to_string();
        let mut r = self.redis.lock().await;
        let _: Result<(), _> = r.set::<_, _, ()>(key, payload).await;
    }

    pub async fn crm_outbox(&self, tenant_id: &str, event_type: &str, payload: serde_json::Value) {
        let id = Uuid::new_v4().to_string();
        let _ = sqlx::query(
            r#"INSERT INTO crm_sync_outbox (id, "tenantId", "eventType", payload, status)
               VALUES ($1,$2,$3,$4,'PENDING')"#,
        )
        .bind(&id)
        .bind(tenant_id)
        .bind(event_type)
        .bind(payload)
        .execute(&self.pool)
        .await;
    }

    pub async fn place_order(&self, tenant_id: &str, req: PlaceReq) -> BtResult<ExecResult> {
        let aid = req.account_id.clone();
        let queued = Instant::now();
        let result = self
            .with_account(&aid, || self.place_order_exclusive(tenant_id, req))
            .await;
        tracing::debug!(
            account_id = %aid,
            queue_wait_ms = queued.elapsed().as_millis() as u64,
            "trade-hop account_queue"
        );
        result
    }

    async fn place_order_exclusive(
        &self,
        tenant_id: &str,
        mut req: PlaceReq,
    ) -> BtResult<ExecResult> {
        req.side = req.side.to_ascii_uppercase();
        req.order_type = req.order_type.to_ascii_uppercase();
        if !self.allow_rate(&req.account_id) {
            return Err(BtError::new(
                RATE_LIMITED,
                format!(
                    "order rate limit — max {} orders per {}ms for this account",
                    self.order_rate_max, self.order_rate_window_ms
                ),
            ));
        }
        let Some(account) = self.load_account(tenant_id, &req.account_id).await? else {
            return Err(BtError::new(VALIDATION, "account not found"));
        };
        if account.status == "TRADING_DISABLED" || account.status == "READ_ONLY" {
            return Err(BtError::new(TRADING_DISABLED, "trading disabled"));
        }
        let Some(sym) = self.load_symbol(tenant_id, &req.symbol).await? else {
            return Err(BtError::new(VALIDATION, "symbol not found"));
        };
        if !sym.enabled {
            return Err(BtError::new(SYMBOL_DISABLED, "symbol disabled"));
        }
        self.assert_group_symbol_access(&account, &sym).await?;
        let sessions = parse_sessions(sym.trading_sessions.as_ref());
        if !is_symbol_tradable(&sessions, &sym.class, Utc::now()) {
            return Err(BtError::new(MARKET_CLOSED, "market closed"));
        }
        if sym.news_mode && sym.news_halt_opens {
            return Err(BtError::new(
                MARKET_CLOSED,
                "trading paused — news event (new orders halted)",
            ));
        }
        let Some(volume) =
            snap_volume(req.volume, sym.min_lot, sym.max_lot, sym.lot_step).filter(|v| *v > 0.0)
        else {
            return Err(BtError::new(
                INVALID_VOLUME,
                format!(
                    "invalid volume {} (min {}, max {}, step {})",
                    req.volume, sym.min_lot, sym.max_lot, sym.lot_step
                ),
            ));
        };
        self.enforce_risk(tenant_id, &account.id, volume).await?;
        if let Some(cid) = req.client_order_id.as_ref() {
            if let Some(dup) = self.find_client_order(tenant_id, &account.id, cid).await? {
                return Ok(dup);
            }
        }
        if req.order_type.eq_ignore_ascii_case("MARKET") {
            return self
                .execute_market(tenant_id, &account, &sym, &req, volume, None, None, false)
                .await;
        }
        self.place_pending(tenant_id, &account, &sym, req, volume)
            .await
    }

    pub(crate) async fn execute_market(
        &self,
        tenant_id: &str,
        account: &AccountRow,
        sym: &SymbolRow,
        req: &PlaceReq,
        volume: f64,
        clamp_worst: Option<f64>,
        plan_in: Option<ExecutionPlan>,
        skip_delay: bool,
    ) -> BtResult<ExecResult> {
        let spec = spec_of(sym);
        let pricing = self
            .group_pricing(account.group_id.as_deref(), sym, tenant_id)
            .await?;
        let apply_kind = if req.order_type.eq_ignore_ascii_case("MARKET") {
            if req.side.eq_ignore_ascii_case("BUY") {
                "marketBuy"
            } else {
                "marketSell"
            }
        } else {
            pending_type_to_apply_kind(&req.order_type, &req.side)
        };
        let applies = execution_applies(&pricing.execution_apply_to, apply_kind);
        let trigger_mono = plan_in
            .as_ref()
            .map(|p| p.trigger_mono)
            .unwrap_or_else(Instant::now);
        let trigger_wall = plan_in
            .as_ref()
            .map(|p| p.trigger_wall)
            .unwrap_or_else(now_ms);
        let plan = plan_in
            .unwrap_or_else(|| create_plan(&pricing, apply_kind, trigger_mono, trigger_wall));
        if !skip_delay {
            wait_for_deadline(Some(&plan)).await;
        }

        let px = if req.side.eq_ignore_ascii_case("BUY") {
            self.prices.buy_price(tenant_id, &req.symbol)
        } else {
            self.prices.sell_price(tenant_id, &req.symbol)
        };
        let Some(px) = px else {
            return Err(BtError::new(NO_PRICE, "no price"));
        };
        self.assert_fresh_quote(tenant_id, &req.symbol, &pricing, apply_kind)?;

        let conv =
            self.quote_to_account_strict(tenant_id, &account.currency, &spec.quote_currency)?;
        let news_markup = if sym.news_mode {
            f64::from(sym.news_spread_points)
        } else {
            0.0
        };
        let mapping_owns = matches!(
            pricing.pricing_method.as_deref(),
            Some("SPREAD_ONLY" | "SPREAD_AND_COMMISSION" | "COMMISSION_ONLY")
        );
        let symbol_book_markup = if mapping_owns {
            0.0
        } else {
            f64::from(sym.spread_markup)
        };
        let total_markup = symbol_book_markup + pricing.markup_points + news_markup;
        let with_markup = apply_markup(&req.side, px, total_markup, sym.digits);
        let honour_ref = req.price;
        // Instant market: honour click. Pending (stop/limit) with apply-to: honour
        // level even after MARKET delay — same rule as SL/TP closes (no fill through).
        // Plain MARKET marketBuy/Sell never honour a client price after the delay.
        let is_market_ot = req.order_type.eq_ignore_ascii_case("MARKET");
        let honour_level = applies
            && honour_ref.is_some()
            && clamp_worst.is_none()
            && (pricing.execution_mode.eq_ignore_ascii_case("INSTANT") || !is_market_ot);

        let mut fill_price = if honour_level {
            round_price(honour_ref.unwrap(), sym.digits)
        } else {
            if req.one_click.unwrap_or(false) && req.price.is_some() && sym.slippage_points > 0 {
                let bound = slippage_bound(
                    &req.side,
                    req.price.unwrap(),
                    f64::from(sym.slippage_points),
                    sym.digits,
                );
                let worse = if req.side.eq_ignore_ascii_case("BUY") {
                    px > bound
                } else {
                    px < bound
                };
                if worse {
                    return Err(BtError::new(INVALID_PRICE, "slippage exceeded"));
                }
            }
            round_price(
                apply_markup(&req.side, with_markup, pricing.slippage_points, sym.digits),
                sym.digits,
            )
        };
        if let Some(clamp) = clamp_worst {
            let honour_clamp = applies
                && (pricing.execution_mode.eq_ignore_ascii_case("INSTANT") || !is_market_ot);
            fill_price = if honour_clamp {
                round_price(clamp, sym.digits)
            } else {
                round_price(
                    if req.side.eq_ignore_ascii_case("BUY") {
                        fill_price.min(clamp)
                    } else {
                        fill_price.max(clamp)
                    },
                    sym.digits,
                )
            };
        }
        if let (Some(bid), Some(ask)) = (
            self.prices.sell_price(tenant_id, &req.symbol),
            self.prices.buy_price(tenant_id, &req.symbol),
        ) {
            if let Err(msg) =
                crate::trigger::validate_sl_tp(&req.side, bid, ask, req.sl_price, req.tp_price)
            {
                return Err(BtError::new(INVALID_PRICE, msg));
            }
        }
        let commission = dealing_commission(&pricing, volume, &spec, fill_price, conv);
        let margin = required_margin(volume, &spec, fill_price, f64::from(account.leverage), conv);

        let group_book = if let Some(gid) = &sym.group_id {
            self.symbol_group_book(gid).await?
        } else {
            None
        };
        let rules = self.routing_rules(tenant_id).await?;
        let routing = resolve_routing(
            &rules,
            RoutingContext {
                account_group_id: account.group_id.as_deref(),
                symbol_id: &sym.id,
                symbol_class: &sym.class,
                account_book: account.book.as_deref(),
                symbol_force_book: sym.force_book.as_deref(),
                symbol_group_default_book: group_book.as_deref(),
            },
        );
        let book = if account.is_demo {
            "B".to_string()
        } else {
            routing.book.clone()
        };
        let covered_volume = if book == "A" {
            round_lots((volume * routing.coverage_ratio) / 100.0, sym.lot_step)
        } else {
            0.0
        };

        let position_id = Uuid::new_v4().to_string();
        let order_id = Uuid::new_v4().to_string();
        let deal_id = Uuid::new_v4().to_string();
        let source = req.source.clone().unwrap_or_else(|| "api".into());
        let comment = audit_comment(
            Some(&plan),
            json!({"fillPrice": fill_price, "result": "filled"}),
        );
        let requested = req.price.unwrap_or(px);

        let mut tx = self.pool.begin().await?;
        sqlx::query("SELECT id FROM accounts WHERE id = $1 FOR UPDATE")
            .bind(&account.id)
            .execute(&mut *tx)
            .await?;
        let locked_row = sqlx::query(&format!("{ACCOUNT_SELECT} WHERE id = $1"))
            .bind(&account.id)
            .fetch_one(&mut *tx)
            .await?;
        let locked = account_from_row(&locked_row);
        if locked.status == "TRADING_DISABLED" || locked.status == "READ_ONLY" {
            return Err(BtError::new(TRADING_DISABLED, "trading disabled"));
        }
        let views = self
            .open_views_tx(&mut tx, tenant_id, &account.id, &locked.currency)
            .await?;
        let live = compute_aggregates(locked.balance, locked.credit, &views);
        if live.free_margin < margin {
            return Err(BtError::new(
                INSUFFICIENT_MARGIN,
                format!(
                    "insufficient free margin: need {margin}, available {}",
                    live.free_margin
                ),
            ));
        }

        sqlx::query(
            r#"INSERT INTO positions (
                 id, "tenantId", "accountId", "symbolId", side, status, book, volume, "coveredVolume",
                 "openPrice", "slPrice", "tpPrice", "marginUsed", commission, comment, "updatedAt"
               ) VALUES (
                 $1,$2,$3,$4,$5::"OrderSide",'OPEN'::"PositionStatus",$6::"BookType",$7,$8,$9,$10,$11,$12,$13,$14,NOW()
               )"#,
        )
        .bind(&position_id)
        .bind(tenant_id)
        .bind(&account.id)
        .bind(&sym.id)
        .bind(&req.side)
        .bind(&book)
        .bind(volume)
        .bind(covered_volume)
        .bind(fill_price)
        .bind(req.sl_price)
        .bind(req.tp_price)
        .bind(margin)
        .bind(commission)
        .bind(&req.comment)
        .execute(&mut *tx)
        .await?;

        sqlx::query(
            r#"INSERT INTO orders (
                 id, "tenantId", "accountId", "symbolId", side, type, status, book, volume, "filledVolume",
                 "requestedPrice", "avgFillPrice", "slPrice", "tpPrice", "slippagePoints", "positionId",
                 source, "filledAt", "clientOrderId", "updatedAt"
               ) VALUES (
                 $1,$2,$3,$4,$5::"OrderSide",'MARKET'::"OrderType",'FILLED'::"OrderStatus",$6::"BookType",
                 $7,$8,$9,$10,$11,$12,$13,$14,$15,NOW(),$16,NOW()
               )"#,
        )
        .bind(&order_id)
        .bind(tenant_id)
        .bind(&account.id)
        .bind(&sym.id)
        .bind(&req.side)
        .bind(&book)
        .bind(volume)
        .bind(volume)
        .bind(requested)
        .bind(fill_price)
        .bind(req.sl_price)
        .bind(req.tp_price)
        .bind(sym.slippage_points)
        .bind(&position_id)
        .bind(&source)
        .bind(&req.client_order_id)
        .execute(&mut *tx)
        .await?;

        sqlx::query(
            r#"INSERT INTO deals (
                 id, "tenantId", "accountId", "positionId", "symbolId", type, side, volume, price, "balanceAfter", comment
               ) VALUES (
                 $1,$2,$3,$4,$5,'OPEN'::"DealType",$6::"OrderSide",$7,$8,$9,$10
               )"#,
        )
        .bind(&deal_id)
        .bind(tenant_id)
        .bind(&account.id)
        .bind(&position_id)
        .bind(&sym.id)
        .bind(&req.side)
        .bind(volume)
        .bind(fill_price)
        .bind(locked.balance)
        .bind(&comment)
        .execute(&mut *tx)
        .await?;

        let views_after = self
            .open_views_tx(&mut tx, tenant_id, &account.id, &locked.currency)
            .await?;
        let after = compute_aggregates(locked.balance, locked.credit, &views_after);
        sqlx::query(
            r#"UPDATE accounts SET equity=$1, margin=$2, "freeMargin"=$3, "marginLevel"=$4, "floatingPL"=$5
               WHERE id=$6"#,
        )
        .bind(after.equity)
        .bind(after.margin)
        .bind(after.free_margin)
        .bind(after.margin_level)
        .bind(after.floating_pl)
        .bind(&locked.id)
        .execute(&mut *tx)
        .await?;
        let commit_started = Instant::now();
        tx.commit().await?;
        tracing::debug!(
            order_id = %order_id,
            sql_commit_ms = commit_started.elapsed().as_millis() as u64,
            "trade-hop sql_commit"
        );

        if book == "A" && covered_volume > 0.0 {
            self.cover_open(
                tenant_id,
                &position_id,
                &account.id,
                sym,
                &req.side,
                covered_volume,
                px,
                &routing,
            )
            .await;
        }

        let snap = Snapshot {
            account_id: locked.id.clone(),
            login: locked.login.clone(),
            currency: locked.currency.clone(),
            leverage: locked.leverage,
            balance: locked.balance,
            credit: locked.credit,
            equity: after.equity,
            margin: after.margin,
            free_margin: after.free_margin,
            margin_level: after.margin_level,
            floating_pl: after.floating_pl,
            ts: now_ms(),
        };
        self.book.upsert(BookRow {
            id: position_id.clone(),
            tenant_id: tenant_id.to_string(),
            account_id: account.id.clone(),
            symbol_id: sym.id.clone(),
            side: req.side.clone(),
            volume,
            open_price: fill_price,
            sl_price: req.sl_price,
            tp_price: req.tp_price,
            margin_used: margin,
            swap: 0.0,
            commission,
            covered_volume,
            opened_at: Utc::now(),
            account_currency: account.currency.clone(),
            group_id: account.group_id.clone(),
            exec_claim_kind: None,
            symbol: sym.symbol.clone(),
            status: "OPEN".into(),
        });
        self.redis_sync_open_positions(tenant_id, &account.id).await;
        let alias = self.client_alias(account.group_id.as_deref(), &sym.symbol).await;
        self.publish_after_fill(
            tenant_id,
            &account.id,
            &position_id,
            Some(&order_id),
            "opened",
            &snap,
            None,
            Some(json!({
                "position": {
                    "id": position_id.clone(),
                    "accountId": account.id.clone(),
                    "symbol": alias,
                    "side": req.side.clone(),
                    "status": "OPEN",
                    "book": book.clone(),
                    "volume": volume,
                    "openPrice": fill_price,
                    "currentPrice": fill_price,
                    "slPrice": req.sl_price,
                    "tpPrice": req.tp_price,
                    "profit": 0.0,
                    "swap": 0.0,
                    "commission": commission,
                    "marginUsed": margin,
                    "digits": sym.digits,
                    "openedAt": Utc::now().to_rfc3339(),
                }
            })),
        )
        .await;

        Ok(ExecResult {
            accepted: true,
            order_id: Some(order_id),
            position_id: Some(position_id),
            status: "FILLED".into(),
            fill_price: Some(fill_price),
            filled_volume: Some(volume),
            reason: None,
            account: Some(snap.json()),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::quote_age_limit_ms;
    use crate::calc::GroupPricing;

    #[test]
    fn one_ms_group_rejects_any_older_tradeable_quote() {
        let pricing = GroupPricing {
            execution_mode: "MARKET".into(),
            execution_delay_ms: 1,
            execution_apply_to: serde_json::json!({
                "marketBuy": true,
                "manualClose": true,
                "buyStop": true,
                "sl": true,
                "tp": true,
            }),
            ..Default::default()
        };
        for kind in ["marketBuy", "manualClose", "buyStop", "sl", "tp"] {
            assert_eq!(quote_age_limit_ms(1000, &pricing, kind), 1, "{kind}");
        }
    }

    #[test]
    fn unconfigured_execution_kind_uses_tight_global_quote_limit() {
        let pricing = GroupPricing {
            execution_mode: "MARKET".into(),
            execution_delay_ms: 1,
            execution_apply_to: serde_json::json!({"marketBuy": true}),
            ..Default::default()
        };
        assert_eq!(quote_age_limit_ms(1000, &pricing, "marketSell"), 1000);
    }
}
