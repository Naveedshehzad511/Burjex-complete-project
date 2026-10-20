//! One answer to "may a client act on this symbol right now?".
//!
//! Used by every client-initiated order action (new orders, SL/TP edits, pending-order edits and
//! cancels, closes) so the market-session rule and the live-price rule are decided in ONE place
//! and cannot drift apart. It never runs for automatic execution (SL/TP triggers, pending fills,
//! stop-out, DAY expiry): those keep working on their own rules.
//!
//! Inputs are plain numbers so the rule is unit-testable; the engine supplies them from the
//! symbol's admin-configured sessions and the live price cache.

use crate::error::{BtError, BtResult, MARKET_CLOSED, NO_PRICE};
use std::future::Future;

tokio::task_local! {
    /// True while an action runs on behalf of staff (admin / dealer), who are exempt from the
    /// client-action restriction. Set only by the HTTP layer, from the gateway's authenticated
    /// `byStaff` flag; a task-local so no engine signature changes and nothing can leak to
    /// another request.
    static STAFF_ACTION: bool;
}

/// Whether the current action was made by staff rather than a client.
pub fn is_staff_action() -> bool {
    STAFF_ACTION.try_with(|v| *v).unwrap_or(false)
}

/// Run `fut` as a staff action when `staff`, else as a normal client action.
pub async fn run_as<F: Future>(staff: bool, fut: F) -> F::Output {
    if staff {
        STAFF_ACTION.scope(true, fut).await
    } else {
        fut.await
    }
}

/// Why a client action is refused (or `Open` when it is allowed).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Gate {
    Open,
    /// The symbol's configured session says the market is shut.
    Closed,
    /// No price has been received for the symbol at all.
    NoPrice,
    /// The last price is older than the freshness limit (feed stale / disconnected).
    Stale(i64),
    /// No price anywhere on the tenant has moved for longer than the freeze limit.
    Frozen(i64),
}

/// `market_open` comes from the symbol's sessions. `tick_age_ms` is the age of the symbol's last
/// price (None = never received). `feed_still_ms` is how long the tenant's whole feed has shown no
/// price movement (None = nothing recorded yet). A limit of 0 or less switches that rule off.
///
/// A closed market is reported as closed even when the price is also old: the weekend is a
/// closed market, not a feed outage.
pub fn evaluate(
    market_open: bool,
    tick_age_ms: Option<i64>,
    feed_still_ms: Option<i64>,
    max_age_ms: i64,
    max_still_ms: i64,
) -> Gate {
    if !market_open {
        return Gate::Closed;
    }
    let Some(age) = tick_age_ms else {
        return Gate::NoPrice;
    };
    if max_age_ms > 0 && age > max_age_ms {
        return Gate::Stale(age);
    }
    if max_still_ms > 0 {
        if let Some(still) = feed_still_ms {
            if still > max_still_ms {
                return Gate::Frozen(still);
            }
        }
    }
    Gate::Open
}

pub const MSG_MARKET_CLOSED: &str = "Market is closed";
pub const MSG_PRICE_UNAVAILABLE: &str = "Live market price is unavailable";

impl Gate {
    pub fn is_open(self) -> bool {
        self == Gate::Open
    }

    /// The error for a refused action. The first words are the client-facing message; the rest
    /// says which condition failed, so a feed outage can be told apart from a closed market.
    pub fn error(self) -> Option<BtError> {
        match self {
            Gate::Open => None,
            Gate::Closed => Some(BtError::new(MARKET_CLOSED, MSG_MARKET_CLOSED)),
            Gate::NoPrice => Some(BtError::new(NO_PRICE, format!("{MSG_PRICE_UNAVAILABLE} (no price received)"))),
            Gate::Stale(age) => Some(BtError::new(
                NO_PRICE,
                format!("{MSG_PRICE_UNAVAILABLE} (last price is {}s old)", age / 1000),
            )),
            Gate::Frozen(still) => Some(BtError::new(
                NO_PRICE,
                format!("{MSG_PRICE_UNAVAILABLE} (the price feed has not moved for {}s)", still / 1000),
            )),
        }
    }

    pub fn into_result(self) -> BtResult<()> {
        match self.error() {
            Some(e) => Err(e),
            None => Ok(()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const AGE: i64 = 15_000;
    const STILL: i64 = 120_000;

    fn g(open: bool, age: Option<i64>, still: Option<i64>) -> Gate {
        evaluate(open, age, still, AGE, STILL)
    }

    #[test]
    fn open_market_with_a_fresh_price_is_allowed() {
        assert_eq!(g(true, Some(0), Some(0)), Gate::Open);
        assert_eq!(g(true, Some(AGE), Some(STILL)), Gate::Open); // limits are inclusive
        assert!(g(true, Some(2_000), None).is_open()); // nothing recorded on the feed yet
    }

    #[test]
    fn a_closed_market_is_closed_whatever_the_price_says() {
        assert_eq!(g(false, Some(0), Some(0)), Gate::Closed);
        assert_eq!(g(false, None, None), Gate::Closed);
        assert_eq!(g(false, Some(10 * AGE), Some(10 * STILL)), Gate::Closed);
    }

    #[test]
    fn a_missing_price_is_not_a_closed_market() {
        assert_eq!(g(true, None, Some(0)), Gate::NoPrice);
    }

    #[test]
    fn a_price_older_than_the_limit_is_stale() {
        assert_eq!(g(true, Some(AGE + 1), Some(0)), Gate::Stale(AGE + 1));
    }

    #[test]
    fn a_frozen_tenant_feed_is_refused_even_when_the_symbol_tick_looks_new() {
        assert_eq!(g(true, Some(1_000), Some(STILL + 1)), Gate::Frozen(STILL + 1));
    }

    #[test]
    fn the_two_thresholds_are_independent() {
        // 15 s freshness does not weaken the 120 s freeze rule, and vice versa.
        assert_eq!(g(true, Some(AGE - 1), Some(STILL - 1)), Gate::Open);
        assert!(matches!(g(true, Some(AGE + 1), Some(0)), Gate::Stale(_)));
        assert!(matches!(g(true, Some(0), Some(STILL + 1)), Gate::Frozen(_)));
    }

    #[test]
    fn a_limit_of_zero_switches_that_rule_off() {
        assert_eq!(evaluate(true, Some(10 * AGE), Some(0), 0, STILL), Gate::Open);
        assert_eq!(evaluate(true, Some(0), Some(10 * STILL), AGE, 0), Gate::Open);
        // ...but a missing price and a closed market are still refused.
        assert_eq!(evaluate(true, None, None, 0, 0), Gate::NoPrice);
        assert_eq!(evaluate(false, Some(0), Some(0), 0, 0), Gate::Closed);
    }

    #[test]
    fn errors_use_the_existing_codes_and_client_messages() {
        let closed = Gate::Closed.error().unwrap();
        assert_eq!(closed.code, MARKET_CLOSED);
        assert_eq!(closed.message, "Market is closed");
        for gate in [Gate::NoPrice, Gate::Stale(21_000), Gate::Frozen(130_000)] {
            let e = gate.error().unwrap();
            assert_eq!(e.code, NO_PRICE);
            assert!(e.message.starts_with("Live market price is unavailable"), "{}", e.message);
        }
        assert!(Gate::Stale(21_000).error().unwrap().message.contains("21s"));
        assert!(Gate::Open.error().is_none());
        assert!(Gate::Open.into_result().is_ok());
        assert!(Gate::Closed.into_result().is_err());
    }
}
