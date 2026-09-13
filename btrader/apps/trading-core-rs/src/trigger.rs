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
    fn sl_long_on_bid() {
        let (hit, lvl) = protective_hit("BUY", 1.099, 1.0992, Some(1.1), None);
        assert_eq!(hit, Some("SL"));
        assert_eq!(lvl, Some(1.1));
    }
}
