//! Pure trading math — same formulas as Node `packages/engine-core/src/calc.ts`.

#[derive(Debug, Clone)]
pub struct SymbolCalcSpec {
    pub digits: i32,
    pub pip_size: f64,
    pub contract_size: f64,
    pub margin_rate: f64,
    pub margin_percent: Option<f64>,
    pub quote_currency: String,
    pub base_currency: String,
}

pub fn point_size(digits: i32) -> f64 {
    10f64.powi(-digits)
}

pub fn notional_quote(volume_lots: f64, spec: &SymbolCalcSpec, price: f64) -> f64 {
    volume_lots * spec.contract_size * price
}

pub fn required_margin(
    volume_lots: f64,
    spec: &SymbolCalcSpec,
    price: f64,
    mut leverage: f64,
    quote_to_acct: f64,
) -> f64 {
    let raw = notional_quote(volume_lots, spec, price);
    if let Some(pct) = spec.margin_percent {
        if pct > 0.0 {
            return raw * pct * quote_to_acct;
        }
    }
    if leverage <= 0.0 {
        leverage = 1.0;
    }
    (raw * spec.margin_rate / leverage) * quote_to_acct
}

pub fn position_profit(
    side: &str,
    volume_lots: f64,
    open_price: f64,
    current_price: f64,
    spec: &SymbolCalcSpec,
    quote_to_acct: f64,
) -> f64 {
    let direction = if side.eq_ignore_ascii_case("BUY") { 1.0 } else { -1.0 };
    (current_price - open_price) * direction * volume_lots * spec.contract_size * quote_to_acct
}

#[derive(Debug, Clone, Default)]
pub struct GroupPricing {
    pub markup_points: f64,
    pub slippage_points: f64,
    pub commission_type: String,
    pub commission_value: f64,
    pub min_spread_points: f64,
    pub max_spread_points: f64,
    pub pricing_method: Option<String>,
    pub execution_mode: String,
    pub instant_deviation_points: f64,
    pub execution_delay_ms: i32,
    pub execution_apply_to: serde_json::Value,
}

/// Whether Instant honour / Market delay applies to `kind`.
/// Empty `{}` ⇒ all kinds (legacy). Otherwise only explicit `true` keys apply;
/// missing or `false` ⇒ immediate market fill (no delay / no Instant honour).
/// Admin always saves the full checkbox map; selective checks must not leak delay
/// onto unchecked SL/TP/pending kinds.
pub fn execution_applies(flags: &serde_json::Value, kind: &str) -> bool {
    let Some(obj) = flags.as_object() else {
        return true;
    };
    if obj.is_empty() {
        return true;
    }
    match obj.get(kind) {
        Some(v) => v.as_bool() == Some(true),
        None => false,
    }
}

pub fn pending_type_to_apply_kind(order_type: &str, side: &str) -> &'static str {
    let t = order_type.to_ascii_uppercase();
    let s = side.to_ascii_uppercase();
    match t.as_str() {
        "BUY_LIMIT" => "buyLimit",
        "SELL_LIMIT" => "sellLimit",
        "BUY_STOP" => "buyStop",
        "SELL_STOP" => "sellStop",
        "LIMIT" => {
            if s == "BUY" {
                "buyLimit"
            } else {
                "sellLimit"
            }
        }
        "STOP" | "STOP_LIMIT" => {
            if s == "BUY" {
                "buyStop"
            } else {
                "sellStop"
            }
        }
        _ => "buyLimit",
    }
}

/// Hard ceiling on a group's execution delay. The gateway rejects larger values; the
/// engine clamps too so a bad row can never park an order for minutes.
pub const MAX_EXECUTION_DELAY_MS: i32 = 30_000;

pub fn market_execution_delay_ms(pricing: &GroupPricing, kind: &str) -> i32 {
    if pricing.execution_mode.to_ascii_uppercase() != "MARKET" {
        return 0;
    }
    // Per client requirement: SL / TP / pending triggers / manual close / close-all all
    // take the group's *current* delay when their kind is checked in executionApplyTo.
    if !execution_applies(&pricing.execution_apply_to, kind) {
        return 0;
    }
    pricing.execution_delay_ms.clamp(0, MAX_EXECUTION_DELAY_MS)
}

/// Instant execution on a checked kind: exact click/level price, so no group slippage.
pub fn instant_honours(pricing: &GroupPricing, kind: &str) -> bool {
    pricing.execution_mode.eq_ignore_ascii_case("INSTANT") && execution_applies(&pricing.execution_apply_to, kind)
}

/// How an open (a market order, or a pending order that has just triggered) is priced once its delay is over.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LevelRule {
    /// Instant execution on a ticked kind: exactly the client's price / the pending level.
    Honour,
    /// Market execution on a ticked kind: the live quote at the moment the delay ends. A pending order's level
    /// only decides WHEN it becomes eligible to fill; it is never the fill price.
    Live,
    /// Kind not ticked: immediate fill at the live quote, never worse than a limit order's price.
    LiveWithinLimit,
}

pub fn level_rule(pricing: &GroupPricing, kind: &str) -> LevelRule {
    if !execution_applies(&pricing.execution_apply_to, kind) {
        LevelRule::LiveWithinLimit
    } else if pricing.execution_mode.eq_ignore_ascii_case("INSTANT") {
        LevelRule::Honour
    } else {
        LevelRule::Live
    }
}

/// The price an open fills at once any delay is over.
///
/// `live_with_costs` is the live quote (read AFTER the delay) with the symbol / group markup and slippage already
/// on it. `honour_ref` is the client's price (a click, or the pending level); `clamp_worst` is a limit order's
/// price; `stop_level` is a Buy Stop / Sell Stop's trigger level.
///
/// Under Market execution the live post-delay quote is used, but never on the wrong side of the order's own price:
/// a limit (and the limit leg of a stop limit) is never worse than its price (BUY at most, SELL at least), and a
/// stop is never better than its level (BUY at least, SELL at most).
pub fn open_fill_price(
    rule: LevelRule,
    side: &str,
    honour_ref: Option<f64>,
    clamp_worst: Option<f64>,
    stop_level: Option<f64>,
    live_with_costs: f64,
    digits: i32,
) -> f64 {
    let buy = side.eq_ignore_ascii_case("BUY");
    let mut fill = match (rule, honour_ref, clamp_worst) {
        (LevelRule::Honour, Some(level), None) => round_price(level, digits),
        _ => round_price(live_with_costs, digits),
    };
    if let Some(clamp) = clamp_worst {
        fill = match rule {
            LevelRule::Honour => round_price(clamp, digits),
            LevelRule::Live | LevelRule::LiveWithinLimit => {
                round_price(if buy { fill.min(clamp) } else { fill.max(clamp) }, digits)
            }
        };
    } else if let (LevelRule::Live, Some(level)) = (rule, stop_level) {
        fill = round_price(if buy { fill.max(level) } else { fill.min(level) }, digits);
    }
    fill
}

/// Whether an SL / TP close fills exactly at its level: only Instant execution on a ticked kind. Under Market
/// execution the level is just the TRIGGER (when the protection fires); the fill is priced after the delay.
pub fn protective_honours_level(pricing: &GroupPricing, kind: &str) -> bool {
    instant_honours(pricing, kind)
}

/// Close price of an SL / TP once its delay is over, from the live closing quote (with the group's markup and
/// slippage on it) and the SL / TP level that triggered. The level only decided WHEN it fired; the close is the
/// live post-delay quote, never on the wrong side of that level:
/// * SL is a stop: a BUY position (closed by selling) gets at most the level, a SELL at least the level.
/// * TP is a limit: a BUY position gets at least the level, a SELL at most the level.
pub fn protective_close_price(position_side: &str, is_tp: bool, live_with_costs: f64, level: f64) -> f64 {
    let long = position_side.eq_ignore_ascii_case("BUY");
    if long != is_tp {
        live_with_costs.min(level)
    } else {
        live_with_costs.max(level)
    }
}

/// Per-side price adjustment (in points) that makes a group's TOTAL client spread equal what the
/// admin configured.
///
/// The admin's Min / Max spread are the spread the client gets, not a markup on top of the market:
/// total = the live market spread clamped into [min, max] (max 0 = no cap, min 0 = no floor). Bid
/// and ask each move by half of the difference, so `ask' - bid' == total`. The result is negative
/// when the market spread is wider than the cap: the client is quoted inside the market.
///
/// * `COMMISSION_ONLY` - 0: raw market prices; the charge is the commission.
/// * min = max = 0 on a spread method - the legacy fixed markup (`legacy_markup_points`), else 0.
pub fn spread_markup_from_band(
    lp_spread_points: f64,
    method: Option<&str>,
    min_spread_points: f64,
    max_spread_points: f64,
    legacy_markup_points: f64,
) -> f64 {
    if method == Some("COMMISSION_ONLY") {
        return 0.0;
    }
    let min = min_spread_points.max(0.0);
    let max = max_spread_points.max(0.0);
    if min == 0.0 && max == 0.0 {
        return if method == Some("SPREAD_ONLY")
            || method == Some("SPREAD_AND_COMMISSION")
            || method.is_none()
        {
            legacy_markup_points.max(0.0)
        } else {
            0.0
        };
    }
    let lp = lp_spread_points.max(0.0);
    let mut total = lp;
    if min > 0.0 && total < min {
        total = min;
    }
    if max > 0.0 && total > max {
        total = max;
    }
    (total - lp) / 2.0
}

/// The group's per-side markup for the quote as it is right now. A mapped symbol re-derives it
/// from the live bid/ask (the market spread moves tick to tick, and an order may have waited out
/// an execution delay); an unmapped symbol keeps its fixed legacy markup.
pub fn group_markup_for_quote(pricing: &GroupPricing, bid: f64, ask: f64, digits: i32) -> f64 {
    let Some(method) = pricing.pricing_method.as_deref() else {
        return pricing.markup_points;
    };
    let lp = ((ask - bid) / point_size(digits)).max(0.0);
    spread_markup_from_band(lp, Some(method), pricing.min_spread_points, pricing.max_spread_points, 0.0)
}

/// `COMMISSION_ONLY` groups quote a ZERO total spread: the client's Bid and Ask are one price, the middle of the live
/// market quote (feed 4007.39 / 4007.43 -> 4007.41 / 4007.41). This is the same rule as a Min / Max band with total
/// spread 0 (both sides move half the gap, the middle stays), computed ONCE from the middle and rounded ONCE, so BUY
/// and SELL are exactly equal even when the gap is an odd number of points (a half-tick middle cannot round two ways).
/// The charge for these groups stays the commission. `None` for every other pricing method: nothing else changes.
pub fn zero_spread_px(pricing: &GroupPricing, bid: f64, ask: f64, digits: i32) -> Option<f64> {
    if pricing.pricing_method.as_deref() != Some("COMMISSION_ONLY") {
        return None;
    }
    if !(bid > 0.0) || !(ask > 0.0) {
        return None;
    }
    Some(round_price((bid + ask) / 2.0, digits))
}

pub fn apply_markup(side: &str, raw_price: f64, markup_points: f64, digits: i32) -> f64 {
    if markup_points == 0.0 {
        return raw_price;
    }
    let delta = markup_points * point_size(digits);
    if side.eq_ignore_ascii_case("BUY") {
        raw_price + delta
    } else {
        raw_price - delta
    }
}

pub fn dealing_commission(
    pricing: &GroupPricing,
    volume_lots: f64,
    spec: &SymbolCalcSpec,
    open_price: f64,
    quote_to_acct: f64,
) -> f64 {
    let v = pricing.commission_value;
    match pricing.commission_type.to_ascii_uppercase().as_str() {
        "PER_LOT" | "ROUND_TURN" => -(v * volume_lots),
        "PER_SIDE" => -(v * volume_lots * 2.0),
        "PERCENT" => {
            let notional = notional_quote(volume_lots, spec, open_price) * quote_to_acct;
            -((v / 100.0) * notional * 2.0)
        }
        _ => 0.0,
    }
}

/// Free funds a fill needs: the margin it locks plus the commission debited from the balance
/// at open (`commission` is negative when charged). A positive commission needs nothing extra.
/// The part of the free margin a NEW trade (or a triggered pending order) may use: what is left after the funds held
/// for pending withdrawal requests. Only the checks for opening exposure use it; equity, margin level and stop-out
/// keep the real free margin, so a reservation can never close a position by itself.
pub fn free_margin_for_new_trades(free_margin: f64, reserved_withdraw: f64) -> f64 {
    free_margin - reserved_withdraw.max(0.0)
}

pub fn open_funds_required(margin: f64, commission: f64) -> f64 {
    margin + (-commission).max(0.0)
}

/// Balance right after a fill: the commission is debited at execution, once. The position
/// is stored with `commission = 0` (nothing left to realize at close) and the amount in
/// `commissionCharged`, so equity does not count it a second time.
pub fn balance_after_open(balance: f64, commission: f64) -> f64 {
    balance + commission
}

pub fn split_position_charges(
    swap: f64,
    commission: f64,
    close_volume: f64,
    open_volume: f64,
) -> (f64, f64, f64, f64) {
    if !(open_volume > 0.0) || close_volume >= open_volume {
        return (swap, commission, 0.0, 0.0);
    }
    let ratio = close_volume / open_volume;
    let realized_swap = swap * ratio;
    let realized_commission = commission * ratio;
    (
        realized_swap,
        realized_commission,
        swap - realized_swap,
        commission - realized_commission,
    )
}

#[derive(Debug, Clone)]
pub struct OpenPositionView {
    pub id: String,
    pub side: String,
    pub volume: f64,
    pub open_price: f64,
    pub current_price: f64,
    pub margin_used: f64,
    pub swap: f64,
    pub commission: f64,
    pub spec: SymbolCalcSpec,
    pub quote_to_acct: f64,
}

pub fn position_floating(p: &OpenPositionView) -> f64 {
    position_profit(
        &p.side,
        p.volume,
        p.open_price,
        p.current_price,
        &p.spec,
        p.quote_to_acct,
    ) + p.swap
        + p.commission
}

pub fn worst_position<'a>(
    positions: &'a [OpenPositionView],
    skip: &std::collections::HashSet<String>,
) -> Option<&'a OpenPositionView> {
    let mut worst: Option<&OpenPositionView> = None;
    let mut worst_pl = f64::INFINITY;
    for p in positions {
        if skip.contains(&p.id) {
            continue;
        }
        let pl = position_floating(p);
        if pl < worst_pl {
            worst_pl = pl;
            worst = Some(p);
        }
    }
    worst
}

#[derive(Debug, Clone, Default)]
pub struct AccountAggregates {
    pub floating_pl: f64,
    pub margin: f64,
    pub equity: f64,
    pub free_margin: f64,
    pub margin_level: f64,
}

pub fn compute_aggregates(balance: f64, credit: f64, positions: &[OpenPositionView]) -> AccountAggregates {
    let mut floating_pl = 0.0;
    let mut margin = 0.0;
    for p in positions {
        floating_pl += position_floating(p);
        margin += p.margin_used;
    }
    let equity = balance + credit + floating_pl;
    let free_margin = equity - margin;
    let margin_level = if margin > 0.0 { equity / margin * 100.0 } else { 0.0 };
    AccountAggregates {
        floating_pl,
        margin,
        equity,
        free_margin,
        margin_level,
    }
}

pub fn resolve_fx_factor(
    account_ccy: &str,
    quote_ccy: &str,
    mut mid: impl FnMut(&str) -> Option<f64>,
) -> Option<f64> {
    if quote_ccy.is_empty() || account_ccy.is_empty() || quote_ccy == account_ccy {
        return Some(1.0);
    }
    if let Some(direct) = mid(&format!("{quote_ccy}{account_ccy}")) {
        if direct > 0.0 {
            return Some(direct);
        }
    }
    if let Some(inverse) = mid(&format!("{account_ccy}{quote_ccy}")) {
        if inverse > 0.0 {
            return Some(1.0 / inverse);
        }
    }
    None
}

pub fn snap_volume(volume: f64, min_lot: f64, max_lot: f64, lot_step: f64) -> Option<f64> {
    if !(volume > 0.0) || !volume.is_finite() || !(lot_step > 0.0) {
        return None;
    }
    if !(min_lot > 0.0) || max_lot < min_lot {
        return None;
    }
    let steps = (volume / lot_step).round();
    let mut v = steps * lot_step;
    v = (v / lot_step).round() * lot_step;
    if (volume - v).abs() > lot_step * 0.51 + 1e-9 {
        return None;
    }
    if v + 1e-12 < min_lot || v - 1e-12 > max_lot {
        return None;
    }
    Some(v)
}

pub fn normalize_volume(volume: f64, min_lot: f64, max_lot: f64, lot_step: f64) -> f64 {
    let steps = (volume / lot_step).round();
    let mut v = steps * lot_step;
    v = v.max(min_lot).min(max_lot);
    (v / lot_step).round() * lot_step
}

pub fn round_price(price: f64, digits: i32) -> f64 {
    let f = 10f64.powi(digits);
    (price * f).round() / f
}

pub fn slippage_bound(side: &str, requested: f64, slippage_points: f64, digits: i32) -> f64 {
    let slip = slippage_points * point_size(digits);
    if side.eq_ignore_ascii_case("BUY") {
        requested + slip
    } else {
        requested - slip
    }
}

pub fn round_lots(v: f64, step: f64) -> f64 {
    let s = if step > 0.0 { step } else { 0.01 };
    ((v / s).round() * s * 10000.0).round() / 10000.0
}

#[cfg(test)]
mod tests {
    use super::*;

    fn eurusd() -> SymbolCalcSpec {
        SymbolCalcSpec {
            digits: 5,
            pip_size: 0.0001,
            contract_size: 100_000.0,
            margin_rate: 1.0,
            margin_percent: None,
            quote_currency: "USD".into(),
            base_currency: "EUR".into(),
        }
    }

    #[test]
    fn margin_1_lot() {
        let m = required_margin(1.0, &eurusd(), 1.1, 100.0, 1.0);
        assert!((m - 1100.0).abs() < 1e-6);
    }

    #[test]
    fn profit_buy() {
        let p = position_profit("BUY", 1.0, 1.1, 1.105, &eurusd(), 1.0);
        assert!((p - 500.0).abs() < 1e-6);
    }

    #[test]
    fn profit_sell() {
        let p = position_profit("SELL", 1.0, 1.1, 1.105, &eurusd(), 1.0);
        assert!((p + 500.0).abs() < 1e-6);
    }

    #[test]
    fn delay_instant_is_zero() {
        let p = GroupPricing {
            execution_mode: "INSTANT".into(),
            execution_delay_ms: 200,
            execution_apply_to: serde_json::json!({"marketBuy": true, "sl": true}),
            ..Default::default()
        };
        assert_eq!(market_execution_delay_ms(&p, "marketBuy"), 0);
        assert_eq!(market_execution_delay_ms(&p, "sl"), 0);
    }

    #[test]
    fn delay_only_checked_apply_to() {
        let p = GroupPricing {
            execution_mode: "MARKET".into(),
            execution_delay_ms: 150,
            execution_apply_to: serde_json::json!({
                "marketBuy": true,
                "marketSell": false,
                "sl": false,
                "tp": false,
                "buyLimit": false,
                "sellLimit": false,
                "buyStop": false,
                "sellStop": false,
                "manualClose": false,
                "closeAll": false
            }),
            ..Default::default()
        };
        assert_eq!(market_execution_delay_ms(&p, "marketBuy"), 150);
        assert_eq!(market_execution_delay_ms(&p, "marketSell"), 0);
        assert_eq!(market_execution_delay_ms(&p, "sl"), 0);
        assert_eq!(market_execution_delay_ms(&p, "tp"), 0);
        assert_eq!(market_execution_delay_ms(&p, "buyStop"), 0);
    }

    #[test]
    fn delay_empty_apply_to_means_all() {
        let p = GroupPricing {
            execution_mode: "MARKET".into(),
            execution_delay_ms: 80,
            execution_apply_to: serde_json::json!({}),
            ..Default::default()
        };
        assert_eq!(market_execution_delay_ms(&p, "sl"), 80);
        assert_eq!(market_execution_delay_ms(&p, "tp"), 80);
        assert_eq!(market_execution_delay_ms(&p, "marketBuy"), 80);
        assert_eq!(market_execution_delay_ms(&p, "buyStop"), 80);
    }

    #[test]
    fn protective_and_pending_take_market_delay_when_checked() {
        let p = GroupPricing {
            execution_mode: "MARKET".into(),
            execution_delay_ms: 100,
            execution_apply_to: serde_json::json!({
                "sl": true, "tp": true, "buyStop": true, "sellLimit": true,
                "marketBuy": true, "manualClose": true
            }),
            ..Default::default()
        };
        assert_eq!(market_execution_delay_ms(&p, "sl"), 100);
        assert_eq!(market_execution_delay_ms(&p, "tp"), 100);
        assert_eq!(market_execution_delay_ms(&p, "buyStop"), 100);
        assert_eq!(market_execution_delay_ms(&p, "sellLimit"), 100);
        assert_eq!(market_execution_delay_ms(&p, "sellStop"), 0);
        assert_eq!(market_execution_delay_ms(&p, "marketBuy"), 100);
        assert_eq!(market_execution_delay_ms(&p, "manualClose"), 100);
    }

    #[test]
    fn delay_is_clamped_to_ceiling() {
        let p = GroupPricing {
            execution_mode: "MARKET".into(),
            execution_delay_ms: 9_999_999,
            execution_apply_to: serde_json::json!({}),
            ..Default::default()
        };
        assert_eq!(market_execution_delay_ms(&p, "marketBuy"), MAX_EXECUTION_DELAY_MS);
        let neg = GroupPricing { execution_delay_ms: -5, ..p };
        assert_eq!(market_execution_delay_ms(&neg, "marketBuy"), 0);
    }

    fn pricing(kind: &str, value: f64) -> GroupPricing {
        GroupPricing { commission_type: kind.into(), commission_value: value, ..Default::default() }
    }

    #[test]
    fn commission_amounts_per_type_are_unchanged() {
        let spec = eurusd();
        // PER_LOT and ROUND_TURN: the configured amount per lot, once, for the whole round trip.
        assert!((dealing_commission(&pricing("PER_LOT", 3.5), 2.0, &spec, 1.1, 1.0) + 7.0).abs() < 1e-9);
        assert!((dealing_commission(&pricing("ROUND_TURN", 3.5), 2.0, &spec, 1.1, 1.0) + 7.0).abs() < 1e-9);
        // PER_SIDE: both sides booked up front.
        assert!((dealing_commission(&pricing("PER_SIDE", 3.5), 2.0, &spec, 1.1, 1.0) + 14.0).abs() < 1e-9);
        // PERCENT: value% of the notional (account currency) for both sides.
        // 1 lot * 100000 * 1.1 = 110000 quote; x0.5 conversion = 55000; 0.01% * 2 = 11.
        assert!((dealing_commission(&pricing("PERCENT", 0.01), 1.0, &spec, 1.1, 0.5) + 11.0).abs() < 1e-9);
        // NONE / unknown: nothing.
        assert_eq!(dealing_commission(&pricing("NONE", 9.0), 1.0, &spec, 1.1, 1.0), 0.0);
        assert_eq!(dealing_commission(&pricing("", 9.0), 1.0, &spec, 1.1, 1.0), 0.0);
        // Case-insensitive, as before.
        assert!((dealing_commission(&pricing("per_lot", 2.0), 1.0, &spec, 1.1, 1.0) + 2.0).abs() < 1e-9);
    }

    fn view(commission: f64, current: f64) -> OpenPositionView {
        OpenPositionView {
            id: "p".into(),
            side: "BUY".into(),
            volume: 1.0,
            open_price: 1.1,
            current_price: current,
            margin_used: 1100.0,
            swap: 0.0,
            commission,
            spec: eurusd(),
            quote_to_acct: 1.0,
        }
    }

    #[test]
    fn charging_at_open_leaves_equity_and_free_margin_as_they_were() {
        let c = -7.0;
        // Old behaviour: balance untouched, commission pending on the position.
        let legacy = compute_aggregates(10_000.0, 0.0, &[view(c, 1.1)]);
        // New behaviour: balance reduced, nothing pending.
        let fresh = compute_aggregates(balance_after_open(10_000.0, c), 0.0, &[view(0.0, 1.1)]);
        assert!((legacy.equity - fresh.equity).abs() < 1e-9);
        assert!((legacy.free_margin - fresh.free_margin).abs() < 1e-9);
        assert!((legacy.margin_level - fresh.margin_level).abs() < 1e-9);
        assert!((legacy.floating_pl - (fresh.floating_pl + c)).abs() < 1e-9);
        assert!((fresh.equity - 9_993.0).abs() < 1e-9);
    }

    #[test]
    fn commission_is_counted_once_over_the_whole_life_of_a_position() {
        let start = 10_000.0;
        let c = -7.0;
        let profit_at_close = 250.0;
        // New: debited at open; nothing pending, so a close realizes only the price result.
        let new_final = balance_after_open(start, c) + profit_at_close + split_position_charges(0.0, 0.0, 1.0, 1.0).1;
        // Legacy: realized at close.
        let legacy_final = start + profit_at_close + split_position_charges(0.0, c, 1.0, 1.0).1;
        assert!((new_final - legacy_final).abs() < 1e-9);
        assert!((new_final - (start + c + profit_at_close)).abs() < 1e-9);
    }

    #[test]
    fn partial_closes_never_charge_a_new_position_again() {
        // A new position carries commission 0 (already debited), so every partial and the final
        // close realize 0 commission, however the volume is split.
        let (mut vol, mut pending) = (1.0_f64, 0.0_f64);
        for take in [0.3, 0.2, 0.5] {
            let (_, realized, _, remaining) = split_position_charges(0.0, pending, take, vol);
            assert_eq!(realized, 0.0);
            pending = remaining;
            vol -= take;
        }
        assert_eq!(pending, 0.0);
    }

    #[test]
    fn a_legacy_position_still_pays_exactly_once_across_partial_closes() {
        let c = -10.0;
        let (mut vol, mut pending, mut paid) = (1.0_f64, c, 0.0_f64);
        for take in [0.25, 0.25, 0.5] {
            let (_, realized, _, remaining) = split_position_charges(0.0, pending, take, vol);
            paid += realized;
            pending = remaining;
            vol -= take;
        }
        assert!((paid - c).abs() < 1e-9, "paid {paid}");
        assert!(pending.abs() < 1e-9);
    }

    // ── Commission only = zero total spread (Bid and Ask are the middle of the live quote) ──────────────────────

    fn gold() -> SymbolCalcSpec {
        SymbolCalcSpec {
            digits: 2,
            pip_size: 0.01,
            contract_size: 100.0,
            margin_rate: 1.0,
            margin_percent: None,
            quote_currency: "USD".into(),
            base_currency: "XAU".into(),
        }
    }

    fn group_pricing_of(method: &str, min: f64, max: f64) -> GroupPricing {
        GroupPricing {
            pricing_method: Some(method.into()),
            min_spread_points: min,
            max_spread_points: max,
            ..Default::default()
        }
    }

    /// What the engine pays / charges a client who trades at the live quote `bid` / `ask` (open and close use the
    /// same steps): the group's base price, the group markup, rounded to the symbol's digits.
    fn client_px(p: &GroupPricing, side: &str, bid: f64, ask: f64, digits: i32) -> f64 {
        let raw = if side == "BUY" { ask } else { bid };
        let markup = group_markup_for_quote(p, bid, ask, digits);
        let base = zero_spread_px(p, bid, ask, digits).unwrap_or(raw);
        round_price(apply_markup(side, base, markup, digits), digits)
    }

    #[test]
    fn commission_only_feed_4007_39_4007_43_gives_4007_41_on_both_sides() {
        let p = group_pricing_of("COMMISSION_ONLY", 0.0, 0.0);
        assert_eq!(zero_spread_px(&p, 4007.39, 4007.43, 2), Some(4007.41));
        assert_eq!(client_px(&p, "BUY", 4007.39, 4007.43, 2), 4007.41, "a BUY opens at the middle");
        assert_eq!(client_px(&p, "SELL", 4007.39, 4007.43, 2), 4007.41, "a SELL opens at the middle");
        // Closing is the opposite side of the same quote: also the middle.
        assert_eq!(client_px(&p, "SELL", 4007.39, 4007.43, 2), client_px(&p, "BUY", 4007.39, 4007.43, 2));
    }

    #[test]
    fn commission_only_buy_and_sell_are_exactly_equal_for_every_gap_even_odd_ones() {
        let p = group_pricing_of("COMMISSION_ONLY", 0.0, 0.0);
        for bid in [4007.39_f64, 4007.38, 1999.99, 79906.04, 0.58797, 176.156] {
            for gap in 0..=60 {
                let digits = if bid < 200.0 { if bid < 1.0 { 5 } else { 3 } } else { 2 };
                let ask = bid + f64::from(gap) * point_size(digits);
                let buy = client_px(&p, "BUY", bid, ask, digits);
                let sell = client_px(&p, "SELL", bid, ask, digits);
                assert_eq!(buy, sell, "bid {bid} gap {gap}: {buy} vs {sell}");
                // and it is the middle (within half a tick)
                assert!((buy - (bid + ask) / 2.0).abs() <= point_size(digits) / 2.0 + 1e-9, "bid {bid} gap {gap}");
            }
        }
    }

    #[test]
    fn golden_zero_spread_prices() {
        // The same table is asserted by the app (`zero_spread_quote_test.dart`): screen and engine agree to the digit.
        let p = group_pricing_of("COMMISSION_ONLY", 0.0, 0.0);
        let golden: [(f64, f64, i32, f64); 10] = [
            (4007.39, 4007.43, 2, 4007.41),
            (4007.39, 4007.42, 2, 4007.41),
            (4012.33, 4012.39, 2, 4012.36),
            (1999.99, 2000.02, 2, 2000.01),
            (176.156, 176.160, 3, 176.158),
            (0.58797, 0.58800, 5, 0.58799),
            (79906.04, 79917.98, 2, 79912.01),
            (1.12182, 1.12183, 5, 1.12183),
            (4007.38, 4007.43, 2, 4007.41),
            (53.914, 53.919, 3, 53.917),
        ];
        for (bid, ask, digits, want) in golden {
            assert_eq!(client_px(&p, "BUY", bid, ask, digits), want, "BUY {bid}/{ask}");
            assert_eq!(client_px(&p, "SELL", bid, ask, digits), want, "SELL {bid}/{ask}");
        }
    }

    #[test]
    fn a_zero_gap_feed_stays_as_it_is() {
        let p = group_pricing_of("COMMISSION_ONLY", 0.0, 0.0);
        assert_eq!(client_px(&p, "BUY", 4007.39, 4007.39, 2), 4007.39);
        assert_eq!(client_px(&p, "SELL", 4007.39, 4007.39, 2), 4007.39);
    }

    #[test]
    fn only_commission_only_gets_the_zero_spread_price() {
        for m in ["SPREAD_ONLY", "SPREAD_AND_COMMISSION"] {
            assert_eq!(zero_spread_px(&group_pricing_of(m, 0.0, 0.0), 4007.39, 4007.43, 2), None, "{m}");
        }
        assert_eq!(zero_spread_px(&GroupPricing::default(), 4007.39, 4007.43, 2), None, "an unmapped symbol");
        assert_eq!(zero_spread_px(&group_pricing_of("COMMISSION_ONLY", 0.0, 0.0), 0.0, 4007.43, 2), None, "no price, no price");
    }

    #[test]
    fn a_configured_50_point_spread_is_still_exactly_50_points_around_the_middle() {
        // Gold at 4 points, admin: min = max = 50 -> the client gets 50 points, centred on the market's middle.
        let p = group_pricing_of("SPREAD_ONLY", 50.0, 50.0);
        let (bid, ask) = (4007.39, 4007.43);
        let buy = client_px(&p, "BUY", bid, ask, 2);
        let sell = client_px(&p, "SELL", bid, ask, 2);
        assert!(((buy - sell) / point_size(2) - 50.0).abs() < 1e-6, "{buy} {sell}");
        assert!(((buy + sell) / 2.0 - (bid + ask) / 2.0).abs() < 0.006);
        // Also with commission, same band: unchanged.
        let both = group_pricing_of("SPREAD_AND_COMMISSION", 50.0, 50.0);
        assert_eq!(client_px(&both, "BUY", bid, ask, 2), buy);
        // and a band that is not set (0 / 0) on a spread method keeps the raw feed, exactly as before.
        let none = group_pricing_of("SPREAD_ONLY", 0.0, 0.0);
        assert_eq!(client_px(&none, "BUY", bid, ask, 2), ask);
        assert_eq!(client_px(&none, "SELL", bid, ask, 2), bid);
        // legacy fixed markup (no mapping): unchanged
        let legacy = GroupPricing { markup_points: 3.0, ..Default::default() };
        assert_eq!(client_px(&legacy, "BUY", bid, ask, 2), round_price(ask + 0.03, 2));
        assert_eq!(client_px(&legacy, "SELL", bid, ask, 2), round_price(bid - 0.03, 2));
    }

    #[test]
    fn the_fill_rule_gives_the_middle_for_market_and_never_a_worse_price_for_a_limit() {
        let p = group_pricing_of("COMMISSION_ONLY", 0.0, 0.0);
        let live = client_px(&p, "BUY", 4007.39, 4007.43, 2);
        // Market (Live): the live middle.
        assert_eq!(open_fill_price(LevelRule::Live, "BUY", None, None, None, live, 2), 4007.41);
        // A BUY LIMIT at 4007.40 is never filled above its price; at 4007.45 it takes the (better) middle.
        assert_eq!(open_fill_price(LevelRule::LiveWithinLimit, "BUY", None, Some(4007.40), None, live, 2), 4007.40);
        assert_eq!(open_fill_price(LevelRule::LiveWithinLimit, "BUY", None, Some(4007.45), None, live, 2), 4007.41);
        let live_sell = client_px(&p, "SELL", 4007.39, 4007.43, 2);
        assert_eq!(open_fill_price(LevelRule::LiveWithinLimit, "SELL", None, Some(4007.45), None, live_sell, 2), 4007.45);
        assert_eq!(open_fill_price(LevelRule::LiveWithinLimit, "SELL", None, Some(4007.40), None, live_sell, 2), 4007.41);
    }

    #[test]
    fn a_protective_close_is_at_the_middle_but_never_past_its_level() {
        let p = group_pricing_of("COMMISSION_ONLY", 0.0, 0.0);
        // A BUY position's SL (a stop) at 4007.40: the live close is the middle 4007.41 -> at most the level.
        let close = client_px(&p, "SELL", 4007.39, 4007.43, 2);
        assert_eq!(protective_close_price("BUY", false, close, 4007.40), 4007.40);
        // Its TP (a limit) at 4007.40: the middle 4007.41 is better than the level, so it is taken.
        assert_eq!(protective_close_price("BUY", true, close, 4007.40), 4007.41);
    }

    #[test]
    fn floating_profit_is_valued_on_the_raw_feed_as_before_and_the_open_is_half_a_gap_better() {
        // The engine values an open position on the raw closing side of the feed (bid for a BUY, ask for a SELL):
        // that code is untouched. What changes is the open price: the middle instead of the far side.
        let g = gold();
        let p = group_pricing_of("COMMISSION_ONLY", 0.0, 0.0);
        let (bid, ask) = (4007.39, 4007.43);
        let buy_open = client_px(&p, "BUY", bid, ask, 2);
        let sell_open = client_px(&p, "SELL", bid, ask, 2);
        let buy_now = position_profit("BUY", 1.0, buy_open, bid, &g, 1.0);
        let sell_now = position_profit("SELL", 1.0, sell_open, ask, &g, 1.0);
        assert!((buy_now + 2.0).abs() < 1e-6, "{buy_now}"); // was -4 (bought at the ask, valued at the bid)
        assert!((sell_now + 2.0).abs() < 1e-6, "{sell_now}"); // was -4 (sold at the bid, valued at the ask)
        let old_buy = position_profit("BUY", 1.0, ask, bid, &g, 1.0);
        assert!((old_buy + 4.0).abs() < 1e-6);
        // Opened and closed at once under the rule: no spread cost at all (the commission is the only charge).
        let round_trip = position_profit("BUY", 1.0, buy_open, client_px(&p, "SELL", bid, ask, 2), &g, 1.0);
        assert!(round_trip.abs() < 1e-9, "{round_trip}");
    }

    #[test]
    fn margin_follows_the_fill_price_so_it_moves_by_the_tiny_half_gap_only() {
        let g = gold();
        let p = group_pricing_of("COMMISSION_ONLY", 0.0, 0.0);
        let (bid, ask) = (4007.39, 4007.43);
        let at_ask = required_margin(1.0, &g, ask, 100.0, 1.0);
        let at_mid = required_margin(1.0, &g, client_px(&p, "BUY", bid, ask, 2), 100.0, 1.0);
        assert!((at_ask - at_mid - 0.02 * 100.0 / 100.0).abs() < 1e-9, "{at_ask} {at_mid}"); // 0.02 * 100 oz / lev 100
        assert!(at_mid < at_ask);
        let sell_mid = required_margin(1.0, &g, client_px(&p, "SELL", bid, ask, 2), 100.0, 1.0);
        assert_eq!(sell_mid, at_mid, "both sides lock the same margin");
    }

    #[test]
    fn commission_charges_are_not_touched_by_the_zero_spread_price() {
        let g = gold();
        let mut p = group_pricing_of("COMMISSION_ONLY", 0.0, 0.0);
        p.commission_type = "PER_LOT".into();
        p.commission_value = 11.0;
        assert_eq!(dealing_commission(&p, 2.0, &g, 4007.41, 1.0), -22.0);
        p.commission_type = "PER_SIDE".into();
        assert_eq!(dealing_commission(&p, 2.0, &g, 4007.41, 1.0), -44.0);
    }

    #[test]
    fn reserved_withdrawal_funds_are_not_available_to_new_trades() {
        // $500 free, $100 held for a withdrawal request: a trade needing $450 is refused, one needing $400 is allowed.
        let avail = free_margin_for_new_trades(500.0, 100.0);
        assert_eq!(avail, 400.0);
        assert!(avail < open_funds_required(450.0, 0.0));
        assert!(!(avail < open_funds_required(400.0, 0.0)));
    }

    #[test]
    fn releasing_the_reservation_gives_the_funds_back() {
        assert_eq!(free_margin_for_new_trades(500.0, 0.0), 500.0);
    }

    #[test]
    fn a_bad_reservation_value_never_adds_funds() {
        assert_eq!(free_margin_for_new_trades(500.0, -50.0), 500.0, "negative reserve is ignored");
        assert_eq!(free_margin_for_new_trades(80.0, 100.0), -20.0, "reserve above free margin leaves nothing, never a positive number");
    }

    #[test]
    fn the_reservation_never_changes_equity_free_margin_or_margin_level_themselves() {
        // Stop-out and margin level read compute_aggregates, which must not know about reservations.
        let a = compute_aggregates(500.0, 0.0, &[]);
        assert_eq!(a.free_margin, 500.0);
        assert_eq!(a.equity, 500.0);
        assert_eq!(a.margin_level, 0.0);
    }

    #[test]
    fn a_fill_needs_free_margin_for_the_commission_too() {
        assert!((open_funds_required(1100.0, -7.0) - 1107.0).abs() < 1e-9);
        assert_eq!(open_funds_required(1100.0, 0.0), 1100.0);
        // A rebate-style positive commission never lowers what is needed.
        assert_eq!(open_funds_required(1100.0, 3.0), 1100.0);
        // 1105 free covers the margin but not margin + commission.
        assert!(1105.0 < open_funds_required(1100.0, -7.0));
    }

    fn fill_spread(lp_pts: f64, min: f64, max: f64) -> f64 {
        // 2-digit symbol (gold): 1 point = 0.01. Market bid 4000.00, ask 4000.00 + lp.
        let digits = 2;
        let bid = 4000.0;
        let ask = bid + lp_pts * point_size(digits);
        let per_side = spread_markup_from_band(lp_pts, Some("SPREAD_ONLY"), min, max, 0.0);
        let buy = apply_markup("BUY", ask, per_side, digits);
        let sell = apply_markup("SELL", bid, per_side, digits);
        (buy - sell) / point_size(digits)
    }

    #[test]
    fn the_client_spread_is_exactly_the_configured_number() {
        // Fixed 18 (min = max): market 24 -> pulled in to 18, market 6 -> widened to 18.
        assert!((fill_spread(24.0, 18.0, 18.0) - 18.0).abs() < 1e-6);
        assert!((fill_spread(6.0, 18.0, 18.0) - 18.0).abs() < 1e-6);
        // Band 5-8: below the floor -> 5, inside -> as the market, above the cap -> 8.
        assert!((fill_spread(0.0, 5.0, 8.0) - 5.0).abs() < 1e-6);
        assert!((fill_spread(6.5, 5.0, 8.0) - 6.5).abs() < 1e-6);
        assert!((fill_spread(24.0, 5.0, 8.0) - 8.0).abs() < 1e-6);
        // Cap only (0-2): gold at 24 is quoted at 2.
        assert!((fill_spread(24.0, 0.0, 2.0) - 2.0).abs() < 1e-6);
        // Floor only (max 0 = no cap): wider markets pass through.
        assert!((fill_spread(24.0, 10.0, 0.0) - 24.0).abs() < 1e-6);
        assert!((fill_spread(4.0, 10.0, 0.0) - 10.0).abs() < 1e-6);
    }

    #[test]
    fn a_wider_market_than_the_cap_gives_a_negative_per_side_adjustment() {
        let m = spread_markup_from_band(24.0, Some("SPREAD_ONLY"), 0.0, 2.0, 0.0);
        assert!((m + 11.0).abs() < 1e-9, "{m}");
        assert!(spread_markup_from_band(0.0, Some("SPREAD_ONLY"), 2.0, 4.0, 0.0) > 0.0);
    }

    #[test]
    fn commission_only_and_unconfigured_bands_add_no_markup() {
        // No markup on top of the market for Commission only (its zero-spread price is `zero_spread_px`, below).
        assert_eq!(spread_markup_from_band(24.0, Some("COMMISSION_ONLY"), 5.0, 8.0, 3.0), 0.0);
        // min = max = 0 on a spread method: the legacy markup, as before (0 by default).
        assert_eq!(spread_markup_from_band(24.0, Some("SPREAD_ONLY"), 0.0, 0.0, 0.0), 0.0);
        assert_eq!(spread_markup_from_band(24.0, None, 0.0, 0.0, 4.0), 4.0);
    }

    #[test]
    fn one_point_on_gold_costs_a_dollar_per_lot() {
        let gold = SymbolCalcSpec {
            digits: 2,
            pip_size: 0.01,
            contract_size: 100.0,
            margin_rate: 1.0,
            margin_percent: None,
            quote_currency: "USD".into(),
            base_currency: "XAU".into(),
        };
        // Open and close 1 lot straight away at an 18-point spread: the loss is $18.
        let spread_px = 18.0 * point_size(gold.digits);
        let loss = position_profit("BUY", 1.0, 4000.0 + spread_px / 2.0, 4000.0 - spread_px / 2.0, &gold, 1.0);
        assert!((loss + 18.0).abs() < 1e-6, "{loss}");
    }

    #[test]
    fn markup_follows_the_live_quote_for_a_mapped_symbol_only() {
        let mapped = GroupPricing {
            pricing_method: Some("SPREAD_ONLY".into()),
            min_spread_points: 0.0,
            max_spread_points: 2.0,
            markup_points: 99.0, // stale value computed earlier: must not be used
            ..Default::default()
        };
        // 24-point quote at 2 digits.
        let m = group_markup_for_quote(&mapped, 4000.00, 4000.24, 2);
        assert!((m + 11.0).abs() < 1e-9, "{m}");
        let legacy = GroupPricing { markup_points: 3.0, ..Default::default() };
        assert_eq!(group_markup_for_quote(&legacy, 4000.00, 4000.24, 2), 3.0);
    }

    #[test]
    fn instant_honours_only_checked_kinds() {
        let p = GroupPricing {
            execution_mode: "INSTANT".into(),
            execution_apply_to: serde_json::json!({"marketBuy": true, "manualClose": false}),
            ..Default::default()
        };
        assert!(instant_honours(&p, "marketBuy"));
        assert!(!instant_honours(&p, "manualClose"));
        assert!(!instant_honours(&p, "sl"));
        let m = GroupPricing { execution_mode: "MARKET".into(), ..p };
        assert!(!instant_honours(&m, "marketBuy"));
    }

    // ── Market execution: pending orders and SL / TP are priced AFTER the delay ──────────────────────────────

    fn grp(mode: &str, ticked: serde_json::Value) -> GroupPricing {
        GroupPricing {
            execution_mode: mode.into(),
            execution_delay_ms: 300,
            execution_apply_to: ticked,
            ..Default::default()
        }
    }
    fn all() -> serde_json::Value {
        serde_json::json!({})
    }
    fn only(kinds: &[&str]) -> serde_json::Value {
        let mut m = serde_json::Map::new();
        for k in ["marketBuy", "marketSell", "buyLimit", "sellLimit", "buyStop", "sellStop", "sl", "tp", "manualClose", "closeAll"] {
            m.insert(k.into(), serde_json::Value::Bool(kinds.contains(&k)));
        }
        serde_json::Value::Object(m)
    }

    #[test]
    fn level_rule_follows_mode_and_the_ticked_kinds() {
        assert_eq!(level_rule(&grp("MARKET", all()), "buyLimit"), LevelRule::Live);
        assert_eq!(level_rule(&grp("MARKET", only(&["buyLimit"])), "buyLimit"), LevelRule::Live);
        assert_eq!(level_rule(&grp("MARKET", only(&["buyLimit"])), "sellLimit"), LevelRule::LiveWithinLimit);
        assert_eq!(level_rule(&grp("INSTANT", all()), "buyStop"), LevelRule::Honour);
        assert_eq!(level_rule(&grp("INSTANT", only(&["sellStop"])), "buyStop"), LevelRule::LiveWithinLimit);
    }

    // Buy Limit at 100.00. The market reaches it, the delay passes, the market has moved.
    #[test]
    fn market_execution_buy_limit_is_never_worse_than_its_price() {
        assert_eq!(open_fill_price(LevelRule::Live, "BUY", Some(100.0), Some(100.0), None, 99.80, 2), 99.80);
        assert_eq!(open_fill_price(LevelRule::Live, "BUY", Some(100.0), Some(100.0), None, 100.00, 2), 100.0);
        assert_eq!(open_fill_price(LevelRule::Live, "BUY", Some(100.0), Some(100.0), None, 100.30, 2), 100.0);
    }

    #[test]
    fn market_execution_sell_limit_is_never_worse_than_its_price() {
        assert_eq!(open_fill_price(LevelRule::Live, "SELL", Some(100.0), Some(100.0), None, 100.20, 2), 100.20);
        assert_eq!(open_fill_price(LevelRule::Live, "SELL", Some(100.0), Some(100.0), None, 100.00, 2), 100.0);
        assert_eq!(open_fill_price(LevelRule::Live, "SELL", Some(100.0), Some(100.0), None, 99.70, 2), 100.0);
    }

    // The client's example: Buy Stop 4000 with a delay.
    #[test]
    fn market_execution_buy_stop_is_never_better_than_its_level() {
        assert_eq!(open_fill_price(LevelRule::Live, "BUY", Some(4000.0), None, Some(4000.0), 4005.0, 2), 4005.0);
        assert_eq!(open_fill_price(LevelRule::Live, "BUY", Some(4000.0), None, Some(4000.0), 3999.0, 2), 4000.0);
        assert_eq!(open_fill_price(LevelRule::Live, "BUY", Some(4000.0), None, Some(4000.0), 4000.0, 2), 4000.0);
    }

    #[test]
    fn market_execution_sell_stop_is_never_better_than_its_level() {
        assert_eq!(open_fill_price(LevelRule::Live, "SELL", Some(3000.0), None, Some(3000.0), 2900.0, 2), 2900.0);
        assert_eq!(open_fill_price(LevelRule::Live, "SELL", Some(3000.0), None, Some(3000.0), 3100.0, 2), 3000.0);
    }

    #[test]
    fn a_stop_limit_fills_by_its_limit_price_not_its_stop() {
        // BUY stop-limit: limit 100 (clamp). Stop level plays no part once the limit leg fills.
        assert_eq!(open_fill_price(LevelRule::Live, "BUY", Some(100.0), Some(100.0), None, 99.50, 2), 99.50);
        assert_eq!(open_fill_price(LevelRule::Live, "BUY", Some(100.0), Some(100.0), None, 100.50, 2), 100.0);
        assert_eq!(open_fill_price(LevelRule::Live, "SELL", Some(100.0), Some(100.0), None, 100.50, 2), 100.50);
        assert_eq!(open_fill_price(LevelRule::Live, "SELL", Some(100.0), Some(100.0), None, 99.50, 2), 100.0);
    }

    #[test]
    fn instant_execution_still_honours_the_pending_level_exactly() {
        assert_eq!(open_fill_price(LevelRule::Honour, "BUY", Some(100.0), Some(100.0), None, 100.30, 2), 100.0);
        assert_eq!(open_fill_price(LevelRule::Honour, "SELL", Some(100.0), None, None, 99.55, 2), 100.0);
        assert_eq!(open_fill_price(LevelRule::Honour, "BUY", Some(4000.0), None, Some(4000.0), 3999.0, 2), 4000.0);
    }

    #[test]
    fn an_unticked_limit_kind_keeps_its_old_rule_never_worse_than_the_limit() {
        assert_eq!(open_fill_price(LevelRule::LiveWithinLimit, "BUY", Some(100.0), Some(100.0), None, 100.30, 2), 100.0);
        assert_eq!(open_fill_price(LevelRule::LiveWithinLimit, "BUY", Some(100.0), Some(100.0), None, 99.80, 2), 99.80);
        assert_eq!(open_fill_price(LevelRule::LiveWithinLimit, "SELL", Some(100.0), Some(100.0), None, 99.70, 2), 100.0);
        assert_eq!(open_fill_price(LevelRule::LiveWithinLimit, "SELL", Some(100.0), Some(100.0), None, 100.20, 2), 100.20);
    }

    #[test]
    fn an_unticked_stop_kind_stays_the_immediate_live_price() {
        assert_eq!(open_fill_price(LevelRule::LiveWithinLimit, "BUY", Some(4000.0), None, Some(4000.0), 3999.0, 2), 3999.0);
    }

    #[test]
    fn a_plain_market_order_is_the_live_price_under_market_execution_and_its_click_under_instant() {
        assert_eq!(open_fill_price(LevelRule::Live, "BUY", Some(4030.1), None, None, 4030.4, 3), 4030.4);
        assert_eq!(open_fill_price(LevelRule::Live, "BUY", Some(4030.1), None, None, 4029.9, 3), 4029.9);
        assert_eq!(open_fill_price(LevelRule::Honour, "BUY", Some(4030.1), None, None, 4030.4, 3), 4030.1);
        assert_eq!(open_fill_price(LevelRule::LiveWithinLimit, "BUY", Some(4030.1), None, None, 4030.4, 3), 4030.4);
    }

    // SL is a stop on the closing side: long SL 3000 (sells), the level only triggers it.
    #[test]
    fn long_sl_is_never_better_than_its_level() {
        assert_eq!(protective_close_price("BUY", false, 2900.0, 3000.0), 2900.0);
        assert_eq!(protective_close_price("BUY", false, 3100.0, 3000.0), 3000.0);
        assert_eq!(protective_close_price("BUY", false, 3000.0, 3000.0), 3000.0);
    }

    #[test]
    fn short_sl_is_never_better_than_its_level() {
        assert_eq!(protective_close_price("SELL", false, 3100.0, 3000.0), 3100.0);
        assert_eq!(protective_close_price("SELL", false, 2900.0, 3000.0), 3000.0);
    }

    // TP is a limit on the closing side: the price may improve after the delay, never fall short of the level.
    #[test]
    fn long_tp_is_never_worse_than_its_level() {
        assert_eq!(protective_close_price("BUY", true, 3100.0, 3000.0), 3100.0);
        assert_eq!(protective_close_price("BUY", true, 2900.0, 3000.0), 3000.0);
    }

    #[test]
    fn short_tp_is_never_worse_than_its_level() {
        assert_eq!(protective_close_price("SELL", true, 2900.0, 3000.0), 2900.0);
        assert_eq!(protective_close_price("SELL", true, 3100.0, 3000.0), 3000.0);
    }

    #[test]
    fn sl_tp_fill_exactly_at_the_level_only_under_instant_execution_on_a_ticked_kind() {
        assert!(protective_honours_level(&grp("INSTANT", all()), "sl"));
        assert!(protective_honours_level(&grp("INSTANT", only(&["tp"])), "tp"));
        assert!(!protective_honours_level(&grp("INSTANT", only(&["tp"])), "sl"));
        assert!(!protective_honours_level(&grp("MARKET", all()), "sl"));
        assert!(!protective_honours_level(&grp("MARKET", only(&["sl", "tp"])), "tp"));
    }

    #[test]
    fn the_group_delay_applies_to_every_ticked_kind_and_only_those() {
        let g = grp("MARKET", only(&["buyLimit", "sellStop", "sl", "manualClose"]));
        for k in ["buyLimit", "sellStop", "sl", "manualClose"] {
            assert_eq!(market_execution_delay_ms(&g, k), 300, "{k}");
        }
        for k in ["marketBuy", "marketSell", "sellLimit", "buyStop", "tp", "closeAll"] {
            assert_eq!(market_execution_delay_ms(&g, k), 0, "{k}");
        }
        for k in ["buyLimit", "sl", "tp", "closeAll"] {
            assert_eq!(market_execution_delay_ms(&grp("INSTANT", all()), k), 0, "instant never waits: {k}");
        }
    }
}
