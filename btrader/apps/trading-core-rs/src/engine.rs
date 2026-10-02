use crate::books::{BookRow, MemoryClaims, PendingBook, PositionBook};
use crate::calc::{
    apply_markup, compute_aggregates, dealing_commission, execution_applies, pending_type_to_apply_kind,
    required_margin, round_lots, round_price, snap_volume, slippage_bound, SymbolCalcSpec,
};
use crate::error::{
    BtError, BtResult, INSUFFICIENT_MARGIN, INVALID_PRICE, INVALID_VOLUME, MARKET_CLOSED, NO_PRICE,
    RATE_LIMITED, SYMBOL_DISABLED, TRADING_DISABLED, VALIDATION,
};
use crate::models::{
    account_from_row, now_ms, AccountRow, Snapshot, SymbolRow, ACCOUNT_SELECT,
};
use crate::policy::{audit_comment, create_plan, wait_for_deadline, ExecutionPlan};
use crate::prices::PriceSource;
use crate::routing::{resolve_routing, RoutingContext, RoutingResolution, RoutingRuleLike};
use crate::sessions::{is_symbol_tradable, parse_sessions};
use chrono::Utc;
use dashmap::DashMap;
use redis::AsyncCommands;
use serde::Deserialize;
use serde_json::json;
use sqlx::PgPool;
use std::collections::HashMap;
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::Mutex;
use uuid::Uuid;

pub(crate) const SYMBOL_CACHE_MS: u128 = 30_000;
pub(crate) const CONFIG_CACHE_MS: u128 = 500;

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
    /// Pending orders whose delayed fill is already scheduled/running (idempotency guard).
    pub(crate) pending_inflight: dashmap::DashSet<String>,
    pub(crate) routing_cache: DashMap<String, (Vec<RoutingRuleLike>, Instant)>,
    rate_hits: DashMap<String, Vec<i64>>,
    account_locks: Mutex<HashMap<String, Arc<Mutex<()>>>>,
    pub(crate) profit_dirty: DashMap<String, f64>,
    pub(crate) last_profit_flush: Mutex<Instant>,
    pub(crate) live_throttle: DashMap<String, i64>,
    pub(crate) acct_live_at: DashMap<String, i64>,
    pub(crate) stop_out_checked: DashMap<String, i64>,
    pub max_price_age_ms: i64,
    pub max_feed_still_ms: i64,
    order_rate_max: usize,
    order_rate_window_ms: i64,
    account_queue_wait: Duration,
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
    std::env::var(key).ok().and_then(|v| v.parse().ok()).unwrap_or(default)
}

/// How long an order waits for the per-account mutation lock before "account busy".
pub(crate) const DEFAULT_ACCOUNT_QUEUE_WAIT_MS: i64 = 8000;

/// `ACCOUNT_QUEUE_WAIT_MS` of 0 (or negative) must not mean "never wait": a zero timeout
/// fails every order that arrives while another one on the same account holds the lock, so
/// a rapid burst would be rejected as "account busy" instead of queued. It carries no
/// execution delay either way (the group's configured delay is waited before the lock), so
/// a non-positive value is treated as unset.
pub(crate) fn account_queue_wait_from(raw_ms: i64) -> Duration {
    let ms = if raw_ms > 0 { raw_ms } else { DEFAULT_ACCOUNT_QUEUE_WAIT_MS };
    Duration::from_millis(ms as u64)
}

impl Engine {
    pub fn new(pool: PgPool, redis: redis::aio::MultiplexedConnection, prices: Arc<PriceSource>) -> Self {
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
            pending_inflight: dashmap::DashSet::new(),
            routing_cache: DashMap::new(),
            rate_hits: DashMap::new(),
            account_locks: Mutex::new(HashMap::new()),
            profit_dirty: DashMap::new(),
            last_profit_flush: Mutex::new(Instant::now()),
            live_throttle: DashMap::new(),
            acct_live_at: DashMap::new(),
            stop_out_checked: DashMap::new(),
            max_price_age_ms: env_i64("MAX_PRICE_AGE_MS", 8000),
            max_feed_still_ms: env_i64("MAX_FEED_STILL_MS", 120_000),
            order_rate_max: env_i64("ORDER_RATE_MAX", 40) as usize,
            order_rate_window_ms: env_i64("ORDER_RATE_WINDOW_MS", 1000),
            account_queue_wait: account_queue_wait_from(env_i64("ACCOUNT_QUEUE_WAIT_MS", DEFAULT_ACCOUNT_QUEUE_WAIT_MS)),
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
        let acquired = tokio::time::timeout(self.account_queue_wait, lock.lock()).await;
        match acquired {
            Ok(_g) => f().await,
            Err(_) => Err(BtError::new(RATE_LIMITED, "account busy — too many queued mutations")),
        }
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

    pub async fn emit(&self, tenant_id: &str, evt: serde_json::Value) {
        let ch = format!("bt:{tenant_id}:engine.evt");
        let payload = evt.to_string();
        let mut r = self.redis.lock().await;
        let _: Result<(), _> = r.publish::<_, _, ()>(ch, payload).await;
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

    pub async fn place_order(self: &Arc<Self>, tenant_id: &str, req: PlaceReq) -> BtResult<ExecResult> {
        let aid = req.account_id.clone();
        // Market orders wait their group delay BEFORE the account lock is taken, so a
        // 500 ms delay never serialises the account's other actions.
        let t0 = Instant::now();
        let mut prewaited = false;
        let mut exec_kind = "";
        let is_market = req.order_type.eq_ignore_ascii_case("MARKET");
        if is_market {
            exec_kind = if req.side.eq_ignore_ascii_case("BUY") { "marketBuy" } else { "marketSell" };
            prewaited = self.pre_wait(tenant_id, &aid, exec_kind).await?;
        }
        let res = if is_market {
            self.place_market(tenant_id, req, prewaited).await
        } else {
            self.with_account(&aid, || self.place_order_exclusive(tenant_id, req, prewaited)).await
        };
        if let (Ok(r), false) = (&res, exec_kind.is_empty()) {
            tracing::info!(
                target: "exec_audit",
                "[EXEC] kind={} account={} measured_ms={} fill={:?}",
                exec_kind, aid, t0.elapsed().as_millis(), r.fill_price
            );
        }
        res
    }

    /// Resolve the account's CURRENT group rule for `kind` and wait its delay (no lock held).
    /// Returns true when the wait was done here (callers then skip their own wait).
    pub(crate) async fn pre_wait(&self, tenant_id: &str, account_id: &str, kind: &str) -> BtResult<bool> {
        let Some(acct) = self.load_account(tenant_id, account_id).await? else {
            return Ok(false);
        };
        let rule = self.group_exec_rule(acct.group_id.as_deref()).await?;
        let plan = create_plan(&rule, kind, Instant::now(), now_ms());
        wait_for_deadline(Some(&plan)).await;
        tracing::info!(
            target: "exec_audit",
            "[WAIT] kind={} mode={} cfg_ms={} waited_ms={:.1}",
            kind, plan.mode, plan.delay_ms, plan.trigger_mono.elapsed().as_secs_f64() * 1000.0
        );
        Ok(true)
    }

    /// Market open. Everything that only READS (validation, group rule, price, markup,
    /// routing) runs BEFORE the per-account lock, so concurrent orders on one account overlap
    /// that work instead of queueing behind each other. The lock then covers only what must
    /// be exclusive: the risk-limit count, the idempotency re-check and the DB transaction.
    /// The price is taken once the group's configured delay has elapsed (not after the queue),
    /// so the effective delay stays the configured one however many orders are in flight.
    async fn place_market(self: &Arc<Self>, tenant_id: &str, mut req: PlaceReq, prewaited: bool) -> BtResult<ExecResult> {
        let (account, sym, volume) = self.validate_place(tenant_id, &mut req).await?;
        if let Some(cid) = req.client_order_id.as_ref() {
            if let Some(dup) = self.find_client_order(tenant_id, &account.id, cid).await? {
                return Ok(dup);
            }
        }
        let prep = self
            .market_prepare(tenant_id, &account, &sym, &req, volume, None, None, prewaited)
            .await?;
        let aid = account.id.clone();
        let (res, post) = {
            let tenant = tenant_id.to_string();
            let aid_in = aid.clone();
            let cid = req.client_order_id.clone();
            self.with_account(&aid, move || async move {
                self.enforce_risk(&tenant, &aid_in, volume).await?;
                if let Some(cid) = cid.as_ref() {
                    if let Some(dup) = self.find_client_order(&tenant, &aid_in, cid).await? {
                        return Ok((dup, None));
                    }
                }
                let (res, post) = self.market_commit(prep).await?;
                Ok((res, Some(post)))
            })
            .await?
        };
        if let Some(post) = post {
            // The A-book hedge does not affect the client's confirmation: run it after the
            // lock is released and the response is on its way.
            let eng = Arc::clone(self);
            tokio::spawn(async move { eng.market_cover(post).await });
        }
        Ok(res)
    }

    /// Normalise + validate an incoming order up to (not including) the risk / idempotency
    /// checks. Read-only, so it never needs the account lock.
    async fn validate_place(&self, tenant_id: &str, req: &mut PlaceReq) -> BtResult<(AccountRow, SymbolRow, f64)> {
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
            return Err(BtError::new(MARKET_CLOSED, "trading paused — news event (new orders halted)"));
        }
        let Some(volume) = snap_volume(req.volume, sym.min_lot, sym.max_lot, sym.lot_step).filter(|v| *v > 0.0) else {
            return Err(BtError::new(
                INVALID_VOLUME,
                format!(
                    "invalid volume {} (min {}, max {}, step {})",
                    req.volume, sym.min_lot, sym.max_lot, sym.lot_step
                ),
            ));
        };
        Ok((account, sym, volume))
    }

    async fn place_order_exclusive(self: &Arc<Self>, tenant_id: &str, mut req: PlaceReq, prewaited: bool) -> BtResult<ExecResult> {
        let (account, sym, volume) = self.validate_place(tenant_id, &mut req).await?;
        self.enforce_risk(tenant_id, &account.id, volume).await?;
        if let Some(cid) = req.client_order_id.as_ref() {
            if let Some(dup) = self.find_client_order(tenant_id, &account.id, cid).await? {
                return Ok(dup);
            }
        }
        if req.order_type.eq_ignore_ascii_case("MARKET") {
            return self
                .execute_market(tenant_id, &account, &sym, &req, volume, None, None, prewaited)
                .await;
        }
        self.place_pending(tenant_id, &account, &sym, req, volume).await
    }


    /// Fill a market order (also used for triggered pending orders): prepare, commit, hedge.
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
        let prep = self
            .market_prepare(tenant_id, account, sym, req, volume, clamp_worst, plan_in, skip_delay)
            .await?;
        let (res, post) = self.market_commit(prep).await?;
        self.market_cover(post).await;
        Ok(res)
    }

    /// Read-only half of a market fill: wait the group's delay (unless already waited),
    /// read the live price, apply markup / slippage, work out commission, margin and book.
    /// Needs no account lock — the margin is re-checked against the locked row in
    /// [`Self::market_commit`].
    pub(crate) async fn market_prepare(
        &self,
        tenant_id: &str,
        account: &AccountRow,
        sym: &SymbolRow,
        req: &PlaceReq,
        volume: f64,
        clamp_worst: Option<f64>,
        plan_in: Option<ExecutionPlan>,
        skip_delay: bool,
    ) -> BtResult<MarketPrep> {
        let spec = spec_of(sym);
        let pricing = self.group_pricing(account.group_id.as_deref(), sym, tenant_id).await?;
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
        let trigger_mono = plan_in.as_ref().map(|p| p.trigger_mono).unwrap_or_else(Instant::now);
        let trigger_wall = plan_in.as_ref().map(|p| p.trigger_wall).unwrap_or_else(now_ms);
        let plan = plan_in.unwrap_or_else(|| create_plan(&pricing, apply_kind, trigger_mono, trigger_wall));
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
        if self.max_price_age_ms > 0 {
            match self.prices.age_ms(tenant_id, &req.symbol) {
                Some(age) if age <= self.max_price_age_ms => {}
                _ => {
                    return Err(BtError::new(NO_PRICE, "no live price (feed stale or late) — order not filled"));
                }
            }
        }
        if self.max_feed_still_ms > 0 {
            if let Some(still) = self.prices.still_ms(tenant_id) {
                if still > self.max_feed_still_ms {
                    return Err(BtError::new(
                        NO_PRICE,
                        format!("feed frozen — no price has moved for {}s", still / 1000),
                    ));
                }
            }
        }

        let conv = self.quote_to_account_strict(tenant_id, &account.currency, &spec.quote_currency)?;
        let news_markup = if sym.news_mode { f64::from(sym.news_spread_points) } else { 0.0 };
        let mapping_owns = matches!(
            pricing.pricing_method.as_deref(),
            Some("SPREAD_ONLY" | "SPREAD_AND_COMMISSION" | "COMMISSION_ONLY")
        );
        let symbol_book_markup = if mapping_owns { 0.0 } else { f64::from(sym.spread_markup) };
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
                let bound = slippage_bound(&req.side, req.price.unwrap(), f64::from(sym.slippage_points), sym.digits);
                let worse = if req.side.eq_ignore_ascii_case("BUY") {
                    px > bound
                } else {
                    px < bound
                };
                if worse {
                    return Err(BtError::new(INVALID_PRICE, "slippage exceeded"));
                }
            }
            round_price(apply_markup(&req.side, with_markup, pricing.slippage_points, sym.digits), sym.digits)
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
            if let Err(msg) = crate::trigger::validate_sl_tp(&req.side, bid, ask, req.sl_price, req.tp_price) {
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
        let comment = audit_comment(Some(&plan), json!({"fillPrice": fill_price, "result": "filled"}));
        let requested = req.price.unwrap_or(px);

        Ok(MarketPrep {
            tenant_id: tenant_id.to_string(),
            account: account.clone(),
            sym: sym.clone(),
            req: req.clone(),
            volume,
            px,
            fill_price,
            commission,
            margin,
            book,
            covered_volume,
            routing,
            comment,
            requested,
        })
    }

    /// Exclusive half of a market fill: the margin check against the LOCKED account row, the
    /// position / order / deal inserts, the in-memory book and the client events. Returns the
    /// result plus what the A-book hedge needs (run separately, outside the account lock).
    pub(crate) async fn market_commit(&self, prep: MarketPrep) -> BtResult<(ExecResult, MarketPostFill)> {
        let MarketPrep {
            tenant_id,
            account,
            sym,
            req,
            volume,
            px,
            fill_price,
            commission,
            margin,
            book,
            covered_volume,
            routing,
            comment,
            requested,
        } = prep;
        let tenant_id = tenant_id.as_str();

        let position_id = Uuid::new_v4().to_string();
        let order_id = Uuid::new_v4().to_string();
        let deal_id = Uuid::new_v4().to_string();
        let source = req.source.clone().unwrap_or_else(|| "api".into());

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
        let views = self.open_views_tx(&mut tx, tenant_id, &account.id, &locked.currency).await?;
        let live = compute_aggregates(locked.balance, locked.credit, &views);
        if live.free_margin < margin {
            return Err(BtError::new(
                INSUFFICIENT_MARGIN,
                format!("insufficient free margin: need {margin}, available {}", live.free_margin),
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

        let views_after = self.open_views_tx(&mut tx, tenant_id, &account.id, &locked.currency).await?;
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
        tx.commit().await?;

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
        let opened_at = Utc::now();
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
            opened_at,
            account_currency: account.currency.clone(),
            group_id: account.group_id.clone(),
            exec_claim_kind: None,
        });
        // The confirmed position rides on the event itself, so clients can show the trade the
        // moment the engine confirms it instead of refetching the whole list.
        let position_json = json!({
            "opened": true,
            "id": position_id,
            "accountId": account.id,
            "symbol": sym.symbol,
            "digits": sym.digits,
            "side": req.side,
            "volume": volume,
            "openPrice": fill_price,
            "slPrice": req.sl_price,
            "tpPrice": req.tp_price,
            "marginUsed": margin,
            "commission": commission,
            "swap": 0.0,
            "openedAt": opened_at.to_rfc3339(),
        });
        self.publish_after_fill_with(tenant_id, &account.id, &position_id, "opened", &snap, None, Some(position_json))
            .await;

        let result = ExecResult {
            accepted: true,
            order_id: Some(order_id),
            position_id: Some(position_id.clone()),
            status: "FILLED".into(),
            fill_price: Some(fill_price),
            filled_volume: Some(volume),
            reason: None,
            account: Some(snap.json()),
        };
        let post = MarketPostFill {
            tenant_id: tenant_id.to_string(),
            account_id: account.id.clone(),
            position_id,
            sym,
            side: req.side.clone(),
            book,
            covered_volume,
            px,
            routing,
        };
        Ok((result, post))
    }

    /// A-book hedge for a freshly opened position (no-op for B-book / demo).
    pub(crate) async fn market_cover(&self, post: MarketPostFill) {
        if post.book == "A" && post.covered_volume > 0.0 {
            self.cover_open(
                &post.tenant_id,
                &post.position_id,
                &post.account_id,
                &post.sym,
                &post.side,
                post.covered_volume,
                post.px,
                &post.routing,
            )
            .await;
        }
    }
}

/// Everything [`Engine::market_prepare`] worked out, handed to [`Engine::market_commit`].
pub(crate) struct MarketPrep {
    tenant_id: String,
    account: AccountRow,
    sym: SymbolRow,
    req: PlaceReq,
    volume: f64,
    px: f64,
    fill_price: f64,
    commission: f64,
    margin: f64,
    book: String,
    covered_volume: f64,
    routing: RoutingResolution,
    comment: String,
    requested: f64,
}

/// What the A-book hedge needs once the position is committed.
pub(crate) struct MarketPostFill {
    tenant_id: String,
    account_id: String,
    position_id: String,
    sym: SymbolRow,
    side: String,
    book: String,
    covered_volume: f64,
    px: f64,
    routing: RoutingResolution,
}

#[cfg(test)]
mod queue_wait_tests {
    use super::*;

    #[test]
    fn zero_or_negative_queue_wait_falls_back_to_the_default() {
        // ACCOUNT_QUEUE_WAIT_MS=0 (as in .env.github) must not reject orders that merely
        // queue behind another one on the same account.
        assert_eq!(account_queue_wait_from(0), Duration::from_millis(DEFAULT_ACCOUNT_QUEUE_WAIT_MS as u64));
        assert_eq!(account_queue_wait_from(-5), Duration::from_millis(DEFAULT_ACCOUNT_QUEUE_WAIT_MS as u64));
    }

    #[test]
    fn positive_queue_wait_is_used_as_configured() {
        assert_eq!(account_queue_wait_from(1500), Duration::from_millis(1500));
    }
}
