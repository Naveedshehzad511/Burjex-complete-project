use chrono::{DateTime, Utc};
use dashmap::DashMap;

#[derive(Debug, Clone)]
pub struct BookRow {
    pub id: String,
    pub tenant_id: String,
    pub account_id: String,
    pub symbol_id: String,
    pub side: String,
    pub volume: f64,
    pub open_price: f64,
    pub sl_price: Option<f64>,
    pub tp_price: Option<f64>,
    pub margin_used: f64,
    pub swap: f64,
    pub commission: f64,
    pub covered_volume: f64,
    pub opened_at: DateTime<Utc>,
    pub account_currency: String,
    pub group_id: Option<String>,
    pub exec_claim_kind: Option<String>,
}

#[derive(Debug, Clone)]
pub struct PendingRow {
    pub id: String,
    pub tenant_id: String,
    pub account_id: String,
    pub symbol_id: String,
    pub side: String,
    pub order_type: String,
    pub status: String,
    pub volume: f64,
    pub price: Option<f64>,
    pub stop_price: Option<f64>,
    pub sl_price: Option<f64>,
    pub tp_price: Option<f64>,
    pub expires_at: Option<DateTime<Utc>>,
    pub updated_at: DateTime<Utc>,
    pub stop_triggered: bool,
}

fn bucket_key(tenant_id: &str, symbol_id: &str) -> String {
    format!("{tenant_id}\u{0000}{symbol_id}")
}

pub struct PositionBook {
    buckets: DashMap<String, DashMap<String, BookRow>>,
    where_id: DashMap<String, String>,
}

impl PositionBook {
    pub fn new() -> Self {
        Self {
            buckets: DashMap::new(),
            where_id: DashMap::new(),
        }
    }

    pub fn load(&self, rows: Vec<BookRow>) {
        self.buckets.clear();
        self.where_id.clear();
        for r in rows {
            self.upsert(r);
        }
    }

    pub fn upsert(&self, row: BookRow) {
        let k = bucket_key(&row.tenant_id, &row.symbol_id);
        if let Some(prev) = self.where_id.get(&row.id) {
            if prev.as_str() != k {
                if let Some(b) = self.buckets.get(prev.as_str()) {
                    b.remove(&row.id);
                }
            }
        }
        self.buckets
            .entry(k.clone())
            .or_insert_with(DashMap::new)
            .insert(row.id.clone(), row.clone());
        self.where_id.insert(row.id.clone(), k);
    }

    pub fn remove(&self, id: &str) {
        if let Some((_, k)) = self.where_id.remove(id) {
            if let Some(b) = self.buckets.get(&k) {
                b.remove(id);
            }
        }
    }

    pub fn map(&self, id: &str, f: impl FnOnce(&mut BookRow)) {
        if let Some(k) = self.where_id.get(id) {
            if let Some(b) = self.buckets.get(k.as_str()) {
                if let Some(mut row) = b.get_mut(id) {
                    f(&mut *row);
                }
            }
        }
    }

    pub fn patch_claim(&self, id: &str, kind: &str) {
        if let Some(k) = self.where_id.get(id) {
            if let Some(b) = self.buckets.get(k.as_str()) {
                if let Some(mut row) = b.get_mut(id) {
                    row.exec_claim_kind = Some(kind.to_string());
                }
            }
        }
    }

    pub fn for_symbol(&self, tenant_id: &str, symbol_id: &str) -> Vec<BookRow> {
        match self.buckets.get(&bucket_key(tenant_id, symbol_id)) {
            Some(b) => b.iter().map(|e| e.value().clone()).collect(),
            None => Vec::new(),
        }
    }

    pub fn accounts_for_symbol(&self, tenant_id: &str, symbol_id: &str) -> Vec<String> {
        let mut out = Vec::new();
        let mut seen = std::collections::HashSet::new();
        for p in self.for_symbol(tenant_id, symbol_id) {
            if seen.insert(p.account_id.clone()) {
                out.push(p.account_id);
            }
        }
        out
    }
}

pub struct PendingBook {
    buckets: DashMap<String, DashMap<String, PendingRow>>,
    where_id: DashMap<String, String>,
}

impl PendingBook {
    pub fn new() -> Self {
        Self {
            buckets: DashMap::new(),
            where_id: DashMap::new(),
        }
    }

    pub fn load(&self, rows: Vec<PendingRow>) {
        self.buckets.clear();
        self.where_id.clear();
        for r in rows {
            self.upsert(r);
        }
    }

    pub fn upsert(&self, row: PendingRow) {
        let k = bucket_key(&row.tenant_id, &row.symbol_id);
        if let Some(prev) = self.where_id.get(&row.id) {
            if prev.as_str() != k {
                if let Some(b) = self.buckets.get(prev.as_str()) {
                    b.remove(&row.id);
                }
            }
        }
        self.buckets
            .entry(k.clone())
            .or_insert_with(DashMap::new)
            .insert(row.id.clone(), row.clone());
        self.where_id.insert(row.id.clone(), k);
    }

    pub fn remove(&self, id: &str) {
        if let Some((_, k)) = self.where_id.remove(id) {
            if let Some(b) = self.buckets.get(&k) {
                b.remove(id);
            }
        }
    }

    pub fn map(&self, id: &str, f: impl FnOnce(&mut PendingRow)) {
        if let Some(k) = self.where_id.get(id) {
            if let Some(b) = self.buckets.get(k.as_str()) {
                if let Some(mut row) = b.get_mut(id) {
                    f(&mut *row);
                    row.updated_at = Utc::now();
                }
            }
        }
    }

    pub fn patch(&self, id: &str, status: Option<&str>, stop_triggered: Option<bool>) {
        if let Some(k) = self.where_id.get(id) {
            if let Some(b) = self.buckets.get(k.as_str()) {
                if let Some(mut row) = b.get_mut(id) {
                    if let Some(s) = status {
                        row.status = s.to_string();
                    }
                    if let Some(st) = stop_triggered {
                        row.stop_triggered = st;
                    }
                    row.updated_at = Utc::now();
                }
            }
        }
    }

    pub fn for_symbol(&self, tenant_id: &str, symbol_id: &str) -> Vec<PendingRow> {
        match self.buckets.get(&bucket_key(tenant_id, symbol_id)) {
            Some(b) => b.iter().map(|e| e.value().clone()).collect(),
            None => Vec::new(),
        }
    }
}

pub struct MemoryClaims {
    inner: DashMap<String, Claim>,
}

#[derive(Debug, Clone)]
pub struct Claim {
    pub kind: String,
    pub level: Option<f64>,
    pub bid: f64,
    pub ask: f64,
    pub trigger_wall: i64,
    /// Absolute mono deadline for MARKET delay (trigger + executionDelayMs).
    /// Retries must wait only until this — never restart the delay.
    pub deadline: std::time::Instant,
    pub delay_ms: i32,
}

impl MemoryClaims {
    pub fn new() -> Self {
        Self {
            inner: DashMap::new(),
        }
    }

    pub fn claim(&self, id: &str, rec: Claim) -> bool {
        match self.inner.entry(id.to_string()) {
            dashmap::mapref::entry::Entry::Occupied(_) => false,
            dashmap::mapref::entry::Entry::Vacant(v) => {
                v.insert(rec);
                true
            }
        }
    }

    pub fn get(&self, id: &str) -> Option<Claim> {
        self.inner.get(id).map(|c| c.clone())
    }

    pub fn has(&self, id: &str) -> bool {
        self.inner.contains_key(id)
    }

    pub fn mark_closed(&self, id: &str) {
        self.inner.remove(id);
    }
}

#[cfg(test)]
mod stop_limit_book_tests {
    //! Several Stop Limit orders — different accounts, prices and volumes — resting in
    //! the real pending book and driven through the same per-order evaluation the tick
    //! loop runs (`engine_tick::trigger_pending`): every price comes from the order row,
    //! every market price from the tick, and the armed state is kept per order id.
    use super::*;
    use crate::trigger::{pending_fires, PendingAction};

    fn row(id: &str, acct: &str, side: &str, stop: f64, limit: f64, vol: f64) -> PendingRow {
        PendingRow {
            id: id.into(),
            tenant_id: "t1".into(),
            account_id: acct.into(),
            symbol_id: "BTCUSD".into(),
            side: side.into(),
            order_type: "STOP_LIMIT".into(),
            status: "PENDING".into(),
            volume: vol,
            price: Some(limit),
            stop_price: Some(stop),
            sl_price: None,
            tp_price: None,
            expires_at: None,
            updated_at: Utc::now(),
            stop_triggered: false,
        }
    }

    /// One tick through the book, as the engine does it. Returns the ids that fill.
    fn tick(book: &PendingBook, bid: f64, ask: f64) -> Vec<String> {
        let mut filled = vec![];
        for o in book.for_symbol("t1", "BTCUSD") {
            if o.status == "PARTIAL" {
                continue; // already triggered: the engine hands it to its fill task
            }
            let trigger = o.stop_price.or(o.price).unwrap();
            match pending_fires(&o.order_type, &o.side, bid, ask, trigger, o.stop_price, o.price, o.stop_triggered) {
                PendingAction::ArmStopLimit => book.patch(&o.id, None, Some(true)),
                PendingAction::Fill => {
                    book.patch(&o.id, Some("PARTIAL"), None);
                    filled.push(o.id.clone());
                }
                PendingAction::None => {}
            }
        }
        filled.sort();
        filled
    }

    fn armed(book: &PendingBook, id: &str) -> bool {
        book.for_symbol("t1", "BTCUSD").into_iter().find(|o| o.id == id).unwrap().stop_triggered
    }

    #[test]
    fn independent_orders_each_use_their_own_prices() {
        let book = PendingBook::new();
        book.upsert(row("a", "acct-1", "BUY", 68050.0, 68045.0, 0.10));
        book.upsert(row("b", "acct-2", "BUY", 68100.0, 68095.0, 0.50));
        book.upsert(row("c", "acct-3", "SELL", 67900.0, 67910.0, 1.25));
        book.upsert(row("d", "acct-1", "SELL", 67800.0, 67812.5, 0.03));

        // Quiet market: nothing arms.
        assert!(tick(&book, 67990.0, 68000.0).is_empty());
        assert!(!armed(&book, "a") && !armed(&book, "b") && !armed(&book, "c") && !armed(&book, "d"));

        // Ask reaches 68050: only order a's stop is crossed.
        assert!(tick(&book, 68040.0, 68050.0).is_empty());
        assert!(armed(&book, "a") && !armed(&book, "b"));

        // Ask 68100: b arms too. a is armed but ask is above its 68045 limit → waits.
        assert!(tick(&book, 68090.0, 68100.0).is_empty());
        assert!(armed(&book, "b"));

        // Pull back to ask 68095: b's limit (68095) is met, a's (68045) is not.
        assert_eq!(tick(&book, 68085.0, 68095.0), vec!["b"]);
        // Down to ask 68045: a fills at its own limit.
        assert_eq!(tick(&book, 68035.0, 68045.0), vec!["a"]);

        // Sell side: bid 67900 arms c only; d (stop 67800) untouched.
        assert!(tick(&book, 67900.0, 67910.0).is_empty());
        assert!(armed(&book, "c") && !armed(&book, "d"));
        // Bid back up to 67910 → c's limit met.
        assert!(tick(&book, 67910.0, 67920.0).contains(&"c".to_string()));

        // Each row still carries exactly the volume / account it was placed with.
        let rows = book.for_symbol("t1", "BTCUSD");
        let get = |id: &str| rows.iter().find(|o| o.id == id).unwrap().clone();
        assert_eq!((get("a").volume, get("a").account_id.as_str()), (0.10, "acct-1"));
        assert_eq!((get("b").volume, get("b").account_id.as_str()), (0.50, "acct-2"));
        assert_eq!((get("c").volume, get("c").account_id.as_str()), (1.25, "acct-3"));
        assert_eq!((get("d").volume, get("d").price, get("d").stop_price), (0.03, Some(67812.5), Some(67800.0)));
    }

    #[test]
    fn gap_through_stop_and_limit_fills_in_one_tick() {
        let book = PendingBook::new();
        // Sell Stop Limit whose limit is already satisfied when the stop is hit.
        book.upsert(row("s", "acct-9", "SELL", 3050.0, 3048.0, 2.0));
        assert_eq!(tick(&book, 3049.0, 3049.5), vec!["s"]);
    }
}
