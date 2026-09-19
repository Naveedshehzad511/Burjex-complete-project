//! OPEN → CLOSE_PENDING → CLOSED. Pure state machine for SL/TP close-sync.
//! No MT5 / hedge-order coupling — this is client-position status only.

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PosLifecycle {
    Open,
    ClosePending,
    Closed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProtectiveClaim {
    /// First hit: atomically move OPEN → CLOSE_PENDING, then wait execution_ms.
    Claim,
    /// Already claimed or already closed — never start a second close.
    IgnoreDuplicate,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CloseExecute {
    /// Apply the fill and move to CLOSED.
    Close,
    /// Second close / already CLOSED — idempotent no-op.
    IgnoreDuplicate,
}

pub fn parse_lifecycle(status: &str) -> PosLifecycle {
    match status.to_ascii_uppercase().as_str() {
        "CLOSE_PENDING" => PosLifecycle::ClosePending,
        "CLOSED" => PosLifecycle::Closed,
        _ => PosLifecycle::Open,
    }
}

pub fn lifecycle_str(s: PosLifecycle) -> &'static str {
    match s {
        PosLifecycle::Open => "OPEN",
        PosLifecycle::ClosePending => "CLOSE_PENDING",
        PosLifecycle::Closed => "CLOSED",
    }
}

pub fn is_working(status: &str) -> bool {
    matches!(parse_lifecycle(status), PosLifecycle::Open | PosLifecycle::ClosePending)
}

/// Server tick SL/TP hit. Only OPEN may be claimed.
pub fn on_protective_hit(status: &str) -> ProtectiveClaim {
    match parse_lifecycle(status) {
        PosLifecycle::Open => ProtectiveClaim::Claim,
        PosLifecycle::ClosePending | PosLifecycle::Closed => ProtectiveClaim::IgnoreDuplicate,
    }
}

/// After execution_ms (or 0), the claimed closer fills the ticket.
pub fn on_protective_close(status: &str) -> CloseExecute {
    match parse_lifecycle(status) {
        PosLifecycle::Open | PosLifecycle::ClosePending => CloseExecute::Close,
        PosLifecycle::Closed => CloseExecute::IgnoreDuplicate,
    }
}

/// Discretionary user/dealer close. CLOSE_PENDING belongs to the protective
/// closer — a duplicate tap must not start a second fill.
pub fn on_user_close(status: &str) -> CloseExecute {
    match parse_lifecycle(status) {
        PosLifecycle::Open => CloseExecute::Close,
        PosLifecycle::ClosePending | PosLifecycle::Closed => CloseExecute::IgnoreDuplicate,
    }
}

/// Rank so a later OPEN snapshot cannot resurrect CLOSE_PENDING / CLOSED.
pub fn status_rank(status: &str) -> u8 {
    match parse_lifecycle(status) {
        PosLifecycle::Closed => 3,
        PosLifecycle::ClosePending => 2,
        PosLifecycle::Open => 1,
    }
}

pub fn prefer_status<'a>(prev: &'a str, next: &'a str) -> &'a str {
    if status_rank(next) >= status_rank(prev) {
        next
    } else {
        prev
    }
}

/// True when a WS/engine OPEN snapshot must be dropped.
pub fn stale_open_blocked(id: &str, status: &str, closed_ids: &[&str]) -> bool {
    if id.is_empty() {
        return false;
    }
    if parse_lifecycle(status) != PosLifecycle::Open {
        return false;
    }
    closed_ids.iter().any(|c| *c == id)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn open_to_close_pending_to_closed() {
        assert_eq!(on_protective_hit("OPEN"), ProtectiveClaim::Claim);
        assert_eq!(lifecycle_str(PosLifecycle::ClosePending), "CLOSE_PENDING");
        assert_eq!(on_protective_close("CLOSE_PENDING"), CloseExecute::Close);
        assert_eq!(on_protective_close("CLOSED"), CloseExecute::IgnoreDuplicate);
    }

    #[test]
    fn duplicate_protective_hit_is_ignored() {
        assert_eq!(on_protective_hit("CLOSE_PENDING"), ProtectiveClaim::IgnoreDuplicate);
        assert_eq!(on_protective_hit("CLOSED"), ProtectiveClaim::IgnoreDuplicate);
    }

    #[test]
    fn duplicate_user_close_is_ignored() {
        assert_eq!(on_user_close("CLOSE_PENDING"), CloseExecute::IgnoreDuplicate);
        assert_eq!(on_user_close("CLOSED"), CloseExecute::IgnoreDuplicate);
        assert_eq!(on_user_close("OPEN"), CloseExecute::Close);
    }

    #[test]
    fn stale_open_cannot_resurrect_closed() {
        assert!(stale_open_blocked("p1", "OPEN", &["p1"]));
        assert!(!stale_open_blocked("p1", "OPEN", &["p2"]));
        assert!(!stale_open_blocked("p1", "CLOSE_PENDING", &["p1"]));
        assert_eq!(prefer_status("OPEN", "CLOSED"), "CLOSED");
        assert_eq!(prefer_status("CLOSED", "OPEN"), "CLOSED");
        assert_eq!(prefer_status("OPEN", "CLOSE_PENDING"), "CLOSE_PENDING");
        assert_eq!(prefer_status("CLOSE_PENDING", "OPEN"), "CLOSE_PENDING");
    }
}
