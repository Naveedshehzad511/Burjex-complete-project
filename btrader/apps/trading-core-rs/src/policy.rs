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

pub async fn wait_for_deadline(plan: Option<&ExecutionPlan>) {
    let Some(plan) = plan else { return };
    if plan.delay_ms <= 0 {
        return;
    }
    let now = Instant::now();
    if now >= plan.deadline {
        return;
    }
    sleep(plan.deadline.saturating_duration_since(now)).await;
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
