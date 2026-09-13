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
