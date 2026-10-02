//! Bid/Ask crossing rules — same as Node `packages/engine-core/src/trigger.ts`.

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PendingAction {
    None,
    Fill,
    ArmStopLimit,
}

pub fn pending_fires(
    order_type: &str,
    side: &str,
    bid: f64,
    ask: f64,
    trigger: f64,
    stop_price: Option<f64>,
    limit_price: Option<f64>,
    stop_triggered: bool,
) -> PendingAction {
    let t = order_type.to_ascii_uppercase();
    let side = side.to_ascii_uppercase();
    if !(bid > 0.0) || !(ask > 0.0) || !(trigger > 0.0) {
        return PendingAction::None;
    }

    if t == "STOP_LIMIT" {
        let stop = stop_price.filter(|v| *v > 0.0).unwrap_or(trigger);
        let limit = limit_price.filter(|v| *v > 0.0).unwrap_or(trigger);
        let stop_hit = if side == "BUY" { ask >= stop } else { bid <= stop };
        let limit_hit = if side == "BUY" { ask <= limit } else { bid >= limit };
        if !stop_triggered {
            if stop_hit && limit_hit {
                return PendingAction::Fill;
            }
            if stop_hit {
                return PendingAction::ArmStopLimit;
            }
            return PendingAction::None;
        }
        return if limit_hit {
            PendingAction::Fill
        } else {
            PendingAction::None
        };
    }

    match t.as_str() {
        "BUY_LIMIT" => {
            if ask <= trigger {
                PendingAction::Fill
            } else {
                PendingAction::None
            }
        }
        "SELL_LIMIT" => {
            if bid >= trigger {
                PendingAction::Fill
            } else {
                PendingAction::None
            }
        }
        "BUY_STOP" => {
            if ask >= trigger {
                PendingAction::Fill
            } else {
                PendingAction::None
            }
        }
        "SELL_STOP" => {
            if bid <= trigger {
                PendingAction::Fill
            } else {
                PendingAction::None
            }
        }
        "LIMIT" => {
            if side == "BUY" {
                if ask <= trigger {
                    PendingAction::Fill
                } else {
                    PendingAction::None
                }
            } else if bid >= trigger {
                PendingAction::Fill
            } else {
                PendingAction::None
            }
        }
        "STOP" => {
            if side == "BUY" {
                if ask >= trigger {
                    PendingAction::Fill
                } else {
                    PendingAction::None
                }
            } else if bid <= trigger {
                PendingAction::Fill
            } else {
                PendingAction::None
            }
        }
        _ => PendingAction::None,
    }
}

/// STOP_LIMIT price relationship (MT5 rule): the stop is the trigger and the limit is
/// the fill price. Buy Stop Limit needs limit < stop; Sell Stop Limit needs limit > stop.
/// Returns the price SL / TP must be validated against — the limit (where it fills) for
/// STOP_LIMIT, otherwise the order's trigger. Non-STOP_LIMIT types are passed through.
pub fn pending_reference_price(
    order_type: &str,
    side: &str,
    stop_price: Option<f64>,
    limit_price: Option<f64>,
) -> Result<Option<f64>, String> {
    if !order_type.eq_ignore_ascii_case("STOP_LIMIT") {
        return Ok(stop_price.or(limit_price));
    }
    let (Some(stop), Some(limit)) = (stop_price.filter(|v| *v > 0.0), limit_price.filter(|v| *v > 0.0)) else {
        return Err("Stop Limit needs both a stop price and a limit price".into());
    };
    if side.eq_ignore_ascii_case("BUY") {
        if !(limit < stop) {
            return Err(format!("Buy Stop Limit: limit price must be below the stop price ({stop})"));
        }
    } else if !(limit > stop) {
        return Err(format!("Sell Stop Limit: limit price must be above the stop price ({stop})"));
    }
    Ok(Some(limit))
}

pub fn is_limit_fill_type(order_type: &str) -> bool {
    matches!(
        order_type.to_ascii_uppercase().as_str(),
        "BUY_LIMIT" | "SELL_LIMIT" | "LIMIT" | "STOP_LIMIT"
    )
}

pub fn protective_hit(
    side: &str,
    bid: f64,
    ask: f64,
    sl: Option<f64>,
    tp: Option<f64>,
) -> (Option<&'static str>, Option<f64>) {
    let is_buy = side.eq_ignore_ascii_case("BUY");
    let mkt = if is_buy { bid } else { ask };
    let sl = sl.filter(|v| *v > 0.0);
    let tp = tp.filter(|v| *v > 0.0);
    let hit_sl = sl.is_some_and(|sl| if is_buy { mkt <= sl } else { mkt >= sl });
    let hit_tp = tp.is_some_and(|tp| if is_buy { mkt >= tp } else { mkt <= tp });
    if hit_sl {
        (Some("SL"), sl)
    } else if hit_tp {
        (Some("TP"), tp)
    } else {
        (None, None)
    }
}

/// Validate SL/TP vs the executable prices the trader sees (Redis/client tick).
/// BUY: SL must be strictly below bid, TP strictly above ask.
/// SELL: SL strictly above ask, TP strictly below bid.
pub fn validate_sl_tp(
    side: &str,
    bid: f64,
    ask: f64,
    sl: Option<f64>,
    tp: Option<f64>,
) -> Result<(), String> {
    let is_buy = side.eq_ignore_ascii_case("BUY");
    if let Some(slv) = sl.filter(|v| *v > 0.0) {
        let ok = if is_buy { slv < bid } else { slv > ask };
        if !ok {
            return Err(format!(
                "stop loss must be {} {}",
                if is_buy { "below bid" } else { "above ask" },
                if is_buy { bid } else { ask }
            ));
        }
    }
    if let Some(tpv) = tp.filter(|v| *v > 0.0) {
        let ok = if is_buy { tpv > ask } else { tpv < bid };
        if !ok {
            return Err(format!(
                "take profit must be {} {}",
                if is_buy { "above ask" } else { "below bid" },
                if is_buy { ask } else { bid }
            ));
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn buy_stop_fires_on_ask() {
        assert_eq!(
            pending_fires("BUY_STOP", "BUY", 1.0998, 1.1, 1.1, None, None, false),
            PendingAction::Fill
        );
    }

    #[test]
    fn buy_stop_gap() {
        assert_eq!(
            pending_fires("BUY_STOP", "BUY", 1.0997, 1.0998, 1.1, None, None, false),
            PendingAction::None
        );
        assert_eq!(
            pending_fires("BUY_STOP", "BUY", 1.1004, 1.1005, 1.1, None, None, false),
            PendingAction::Fill
        );
    }

    #[test]
    fn buy_stop_limit_arms_then_fills_at_limit() {
        // stop 1.1010 (trigger), limit 1.1005 (fill).
        let s = Some(1.1010);
        let l = Some(1.1005);
        assert_eq!(pending_fires("STOP_LIMIT", "BUY", 1.0999, 1.1000, 1.1010, s, l, false), PendingAction::None);
        assert_eq!(pending_fires("STOP_LIMIT", "BUY", 1.1009, 1.1010, 1.1010, s, l, false), PendingAction::ArmStopLimit);
        assert_eq!(pending_fires("STOP_LIMIT", "BUY", 1.1007, 1.1008, 1.1010, s, l, true), PendingAction::None);
        assert_eq!(pending_fires("STOP_LIMIT", "BUY", 1.1003, 1.1005, 1.1010, s, l, true), PendingAction::Fill);
    }

    #[test]
    fn sell_stop_limit_arms_then_fills_at_limit() {
        // stop 1.0990 (trigger), limit 1.0995 (fill).
        let s = Some(1.0990);
        let l = Some(1.0995);
        assert_eq!(pending_fires("STOP_LIMIT", "SELL", 1.1000, 1.1001, 1.0990, s, l, false), PendingAction::None);
        assert_eq!(pending_fires("STOP_LIMIT", "SELL", 1.0990, 1.0991, 1.0990, s, l, false), PendingAction::ArmStopLimit);
        assert_eq!(pending_fires("STOP_LIMIT", "SELL", 1.0992, 1.0993, 1.0990, s, l, true), PendingAction::None);
        assert_eq!(pending_fires("STOP_LIMIT", "SELL", 1.0995, 1.0996, 1.0990, s, l, true), PendingAction::Fill);
    }

    #[test]
    fn buy_stop_limit_price_relationship() {
        assert_eq!(pending_reference_price("STOP_LIMIT", "BUY", Some(1.1010), Some(1.1005)), Ok(Some(1.1005)));
        assert!(pending_reference_price("STOP_LIMIT", "BUY", Some(1.1010), Some(1.1010)).is_err());
        assert!(pending_reference_price("STOP_LIMIT", "BUY", Some(1.1010), Some(1.1015)).is_err());
        assert!(pending_reference_price("STOP_LIMIT", "BUY", Some(1.1010), None).is_err());
    }

    #[test]
    fn sell_stop_limit_price_relationship() {
        assert_eq!(pending_reference_price("STOP_LIMIT", "SELL", Some(1.0990), Some(1.0995)), Ok(Some(1.0995)));
        assert!(pending_reference_price("STOP_LIMIT", "SELL", Some(1.0990), Some(1.0990)).is_err());
        assert!(pending_reference_price("STOP_LIMIT", "SELL", Some(1.0990), Some(1.0985)).is_err());
        assert!(pending_reference_price("STOP_LIMIT", "SELL", None, Some(1.0995)).is_err());
    }

    #[test]
    fn other_types_reference_is_trigger() {
        assert_eq!(pending_reference_price("BUY_STOP", "BUY", Some(1.2), None), Ok(Some(1.2)));
        assert_eq!(pending_reference_price("BUY_LIMIT", "BUY", None, Some(1.1)), Ok(Some(1.1)));
    }

    #[test]
    fn sl_long_on_bid() {
        let (hit, lvl) = protective_hit("BUY", 1.099, 1.0992, Some(1.1), None);
        assert_eq!(hit, Some("SL"));
        assert_eq!(lvl, Some(1.1));
    }
}
