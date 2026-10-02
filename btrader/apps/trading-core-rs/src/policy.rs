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

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

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
}
