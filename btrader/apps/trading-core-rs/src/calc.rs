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

pub fn market_execution_delay_ms(pricing: &GroupPricing, kind: &str) -> i32 {
    if pricing.execution_mode.to_ascii_uppercase() != "MARKET" {
        return 0;
    }
    // SL/TP never wait under MARKET delay. Waiting left the position OPEN while
    // the chart printed through the stop; fill already honours the level when
    // apply-to includes sl/tp. Group ms still applies to market + pending + close.
    if kind.eq_ignore_ascii_case("sl") || kind.eq_ignore_ascii_case("tp") {
        return 0;
    }
    if !execution_applies(&pricing.execution_apply_to, kind) {
        return 0;
    }
    pricing.execution_delay_ms.max(0)
}

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
    let mut total = min;
    if max > 0.0 {
        total = max.min(min.max(lp));
    }
    total / 2.0
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
        assert_eq!(market_execution_delay_ms(&p, "sl"), 0);
        assert_eq!(market_execution_delay_ms(&p, "tp"), 0);
        assert_eq!(market_execution_delay_ms(&p, "marketBuy"), 80);
        assert_eq!(market_execution_delay_ms(&p, "buyStop"), 80);
    }

    #[test]
    fn protective_never_takes_market_delay() {
        let p = GroupPricing {
            execution_mode: "MARKET".into(),
            execution_delay_ms: 100,
            execution_apply_to: serde_json::json!({"sl": true, "tp": true, "marketBuy": true}),
            ..Default::default()
        };
        assert_eq!(market_execution_delay_ms(&p, "sl"), 0);
        assert_eq!(market_execution_delay_ms(&p, "tp"), 0);
        assert_eq!(market_execution_delay_ms(&p, "marketBuy"), 100);
    }
}
