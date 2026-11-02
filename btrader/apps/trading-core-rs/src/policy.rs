use crate::calc::{execution_applies, market_execution_delay_ms, GroupPricing};
use std::time::Instant;
use tokio::time::{sleep, Duration};

#[derive(Debug, Clone)]
pub struct ExecutionPlan {
    pub kind: String,
    pub mode: String,
    pub delay_ms: i32,
    pub trigger_mono: Instant,
    pub trigger_wall: i64,
    pub deadline: Instant,
}

pub fn create_plan(pricing: &GroupPricing, kind: &str, trigger_mono: Instant, trigger_wall: i64) -> ExecutionPlan {
    let mode = if pricing.execution_mode.eq_ignore_ascii_case("INSTANT") {
        "INSTANT"
    } else {
        "MARKET"
    };
    let delay_ms = market_execution_delay_ms(pricing, kind);
    ExecutionPlan {
        kind: kind.to_string(),
        mode: mode.to_string(),
        delay_ms,
        trigger_mono,
        trigger_wall,
        deadline: trigger_mono + Duration::from_millis(delay_ms.max(0) as u64),
    }
}

/// Sleep until `plan.deadline` — never longer than remaining time.
/// Coarse sleep then short yields so MARKET delay stays at the configured ms
/// (no full restart, no extra 1ms+ cushion on top of the group value).
pub async fn wait_for_deadline(plan: Option<&ExecutionPlan>) {
    let Some(plan) = plan else { return };
    if plan.delay_ms <= 0 {
        return;
    }
    loop {
        let now = Instant::now();
        if now >= plan.deadline {
            return;
        }
        let left = plan.deadline.saturating_duration_since(now);
        if left.is_zero() {
            return;
        }
        if left > Duration::from_millis(4) {
            // Wake slightly early so the final spin lands on the deadline.
            let early = left
                .checked_sub(Duration::from_millis(1))
                .unwrap_or(Duration::from_millis(1));
            sleep(early).await;
        } else {
            tokio::task::yield_now().await;
        }
    }
}

/// Wait until an absolute Instant (used for SL/TP claim deadlines on retries).
pub async fn wait_until_instant(deadline: Instant, delay_ms: i32) {
    if delay_ms <= 0 {
        return;
    }
    wait_for_deadline(Some(&ExecutionPlan {
        kind: String::new(),
        mode: String::new(),
        delay_ms,
        trigger_mono: deadline
            .checked_sub(Duration::from_millis(delay_ms.max(0) as u64))
            .unwrap_or(deadline),
        trigger_wall: 0,
        deadline,
    }))
    .await;
}

pub fn close_apply_kind(protective_kind: Option<&str>, close_all: bool, stop_out: bool, dealer: bool) -> Option<&'static str> {
    if stop_out || dealer {
        return None;
    }
    if let Some(k) = protective_kind {
        return Some(if k == "tp" { "tp" } else { "sl" });
    }
    if close_all {
        return Some("closeAll");
    }
    Some("manualClose")
}

/// Whether a close must re-check that the quote is still live after its delay: client-initiated closes (manual
/// close, Close All) do, exactly as an open does. SL / TP are automatic, stop-out is forced and a dealer's
/// manual-price close is the dealer's own call: none of those are held up by it.
pub fn close_requires_live_quote(protective_kind: Option<&str>, floor_balance: bool, price_override: bool, staff: bool) -> bool {
    protective_kind.is_none() && !floor_balance && !price_override && !staff
}

pub fn audit_comment(plan: Option<&ExecutionPlan>, extra: serde_json::Value) -> String {
    let mut body = serde_json::json!({
        "exec": plan.map(|p| p.kind.as_str()).unwrap_or("unknown"),
        "delayMs": plan.map(|p| p.delay_ms).unwrap_or(0),
        "triggerWall": plan.map(|p| p.trigger_wall),
        "engine": crate::engine_id(),
    });
    if let Some(obj) = extra.as_object() {
        if let Some(map) = body.as_object_mut() {
            for (k, v) in obj {
                map.insert(k.clone(), v.clone());
            }
        }
    }
    let s = body.to_string();
    if s.len() > 480 {
        s[..480].to_string()
    } else {
        s
    }
}

pub fn execution_applies_kind(pricing: &GroupPricing, kind: &str) -> bool {
    execution_applies(&pricing.execution_apply_to, kind)
}

/// Accounts holding a symbol whose stop-out is checked on this tick: every one not checked within the last
/// [`STOP_OUT_RECHECK_MS`], up to [`STOP_OUT_PER_TICK`] per tick. An account checked a moment ago does not take a slot,
/// so the others are reached on the next ticks - none is left out however many clients hold the symbol (it used to be
/// the first four only, every tick the same four).
pub const STOP_OUT_RECHECK_MS: i64 = 1000;
pub const STOP_OUT_PER_TICK: usize = 32;

pub fn stop_out_due(accounts: Vec<String>, last_checked: impl Fn(&str) -> i64, now_ms: i64) -> Vec<String> {
    accounts
        .into_iter()
        .filter(|a| now_ms - last_checked(a) >= STOP_OUT_RECHECK_MS)
        .take(STOP_OUT_PER_TICK)
        .collect()
}

/// Whether an account's positions are stopped out now: its margin level is at or below the stop-out level, or its
/// equity is below zero whatever the margin (a fully hedged account can hold no margin and still lose: it used to be
/// skipped, so its equity could fall below zero with every position left open).
pub fn stop_out_needed(equity: f64, margin: f64, margin_level: f64, stop_out_level: f64) -> bool {
    equity < 0.0 || (margin > 0.0 && margin_level <= stop_out_level)
}

/// Negative balance protection: a close that leaves the account with no open position and a balance below zero is
/// followed by a correction of that amount, so the balance is 0 and the client never owes more than they put in (the
/// broker absorbs the rest). While positions are still open nothing is corrected - their profit may still cover it.
/// Returns the correction (positive), or None. Off with `ENGINE_NEGATIVE_BALANCE_PROTECTION=off`.
pub fn negative_balance_correction(balance_after: f64, positions_left: bool, enabled: bool) -> Option<f64> {
    if !enabled || positions_left || !(balance_after < -1e-8) {
        return None;
    }
    Some(-balance_after)
}

pub fn negative_balance_protection_enabled() -> bool {
    !matches!(
        std::env::var("ENGINE_NEGATIVE_BALANCE_PROTECTION").map(|v| v.trim().to_ascii_lowercase()).as_deref(),
        Ok("off") | Ok("0") | Ok("false") | Ok("no")
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn stop_out_reaches_every_account_holding_the_symbol() {
        let accounts: Vec<String> = (0..10).map(|i| format!("a{i}")).collect();
        // The first four were checked a moment ago: the others are checked now (they used to be skipped every tick).
        let recent = |a: &str| if ["a0", "a1", "a2", "a3"].contains(&a) { 10_000 } else { 0 };
        let due = stop_out_due(accounts.clone(), recent, 10_500);
        assert_eq!(due, vec!["a4", "a5", "a6", "a7", "a8", "a9"]);
        // A second later all ten are due again.
        assert_eq!(stop_out_due(accounts, recent, 11_000).len(), 10);
    }

    #[test]
    fn stop_out_per_tick_is_bounded_and_rotates() {
        let accounts: Vec<String> = (0..100).map(|i| format!("a{i}")).collect();
        let checked = std::collections::HashMap::<String, i64>::new();
        let first = stop_out_due(accounts.clone(), |a| *checked.get(a).unwrap_or(&0), 5_000);
        assert_eq!(first.len(), STOP_OUT_PER_TICK);
        let mut checked = checked;
        for a in &first {
            checked.insert(a.clone(), 5_000);
        }
        let next = stop_out_due(accounts, |a| *checked.get(a).unwrap_or(&0), 5_010);
        assert_eq!(next.len(), STOP_OUT_PER_TICK);
        assert!(next.iter().all(|a| !first.contains(a)), "the next tick reaches the ones not checked yet");
    }

    #[test]
    fn stop_out_when_margin_level_falls_or_equity_goes_below_zero() {
        assert!(stop_out_needed(40.0, 100.0, 40.0, 50.0), "margin level under the stop-out level");
        assert!(!stop_out_needed(80.0, 100.0, 80.0, 50.0), "above it: kept open");
        assert!(stop_out_needed(-9.28, 0.0, 0.0, 50.0), "negative equity with no margin (fully hedged)");
        assert!(stop_out_needed(-9.28, 20.0, -46.4, 50.0), "negative equity");
        assert!(!stop_out_needed(30.0, 0.0, 0.0, 50.0), "no margin and positive equity: nothing to stop out");
    }

    #[test]
    fn negative_balance_is_brought_back_to_zero_when_nothing_is_left_open() {
        assert_eq!(negative_balance_correction(-62.6034, false, true), Some(62.6034));
        assert_eq!(negative_balance_correction(-62.6034, true, true), None, "open positions may still cover it");
        assert_eq!(negative_balance_correction(0.0, false, true), None);
        assert_eq!(negative_balance_correction(15.0, false, true), None);
        assert_eq!(negative_balance_correction(-1e-10, false, true), None, "rounding dust is not corrected");
        assert_eq!(negative_balance_correction(-50.0, false, false), None, "switched off");
    }

    fn group(mode: &str, delay_ms: i32) -> GroupPricing {
        GroupPricing {
            execution_mode: mode.into(),
            execution_delay_ms: delay_ms,
            execution_apply_to: json!({}),
            ..Default::default()
        }
    }

    async fn timed_wait(p: GroupPricing, kind: &'static str) -> u128 {
        let t0 = Instant::now();
        let plan = create_plan(&p, kind, Instant::now(), 0);
        wait_for_deadline(Some(&plan)).await;
        t0.elapsed().as_millis()
    }

    /// The group's delay is waited per order, in parallel: 12 rapid orders configured for
    /// 200 ms all finish their wait after ~200 ms, not after 12 x 200 ms.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn twelve_concurrent_delays_overlap_and_match_the_configured_ms() {
        let p = group("MARKET", 200);
        let t0 = Instant::now();
        let handles: Vec<_> = (0..12).map(|_| tokio::spawn(timed_wait(p.clone(), "marketBuy"))).collect();
        for h in handles {
            let waited = h.await.unwrap();
            assert!(waited >= 199, "waited {waited}ms, less than the configured 200ms");
            assert!(waited < 260, "waited {waited}ms, well over the configured 200ms");
        }
        assert!(t0.elapsed().as_millis() < 400, "orders waited one after another");
    }

    #[tokio::test]
    async fn instant_mode_never_waits() {
        assert!(timed_wait(group("INSTANT", 200), "marketBuy").await < 20);
    }

    #[tokio::test]
    async fn the_delay_is_the_configured_value_not_a_constant() {
        let w = timed_wait(group("MARKET", 50), "marketSell").await;
        assert!((49..110).contains(&(w as i64)), "waited {w}ms for a 50ms rule");
    }

    #[test]
    fn only_a_clients_close_re_checks_the_quote_after_its_delay() {
        assert!(close_requires_live_quote(None, false, false, false), "manual close / Close All");
        assert!(!close_requires_live_quote(Some("sl"), false, false, false), "SL is automatic");
        assert!(!close_requires_live_quote(Some("tp"), false, false, false), "TP is automatic");
        assert!(!close_requires_live_quote(None, true, false, false), "stop-out is forced");
        assert!(!close_requires_live_quote(None, false, true, false), "the dealer's own price");
        assert!(!close_requires_live_quote(None, false, false, true), "staff action");
    }
}
