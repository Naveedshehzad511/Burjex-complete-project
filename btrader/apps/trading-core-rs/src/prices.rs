use dashmap::DashMap;
use serde::{Deserialize, Serialize};
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Tick {
    pub symbol: String,
    pub bid: f64,
    pub ask: f64,
    pub ts: i64,
}

pub struct PriceSource {
    ticks: DashMap<String, Tick>,
    changed_at: DashMap<String, i64>,
}

impl PriceSource {
    pub fn new() -> Self {
        Self {
            ticks: DashMap::new(),
            changed_at: DashMap::new(),
        }
    }

    fn key(tenant_id: &str, symbol: &str) -> String {
        format!("{tenant_id}:{symbol}")
    }

    fn now_ms() -> i64 {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_millis() as i64)
            .unwrap_or(0)
    }

    pub fn set(&self, tenant_id: &str, tick: Tick) {
        let k = Self::key(tenant_id, &tick.symbol);
        let changed = match self.ticks.get(&k) {
            Some(prev) => prev.bid != tick.bid || prev.ask != tick.ask,
            None => true,
        };
        if changed {
            self.changed_at.insert(tenant_id.to_string(), Self::now_ms());
        }
        self.ticks.insert(k, tick);
    }

    pub fn get(&self, tenant_id: &str, symbol: &str) -> Option<Tick> {
        self.ticks.get(&Self::key(tenant_id, symbol)).map(|t| t.clone())
    }

    pub fn buy_price(&self, tenant_id: &str, symbol: &str) -> Option<f64> {
        self.get(tenant_id, symbol).map(|t| t.ask)
    }

    pub fn sell_price(&self, tenant_id: &str, symbol: &str) -> Option<f64> {
        self.get(tenant_id, symbol).map(|t| t.bid)
    }

    pub fn age_ms(&self, tenant_id: &str, symbol: &str) -> Option<i64> {
        self.get(tenant_id, symbol).map(|t| Self::now_ms() - t.ts)
    }

    pub fn still_ms(&self, tenant_id: &str) -> Option<i64> {
        self.changed_at.get(tenant_id).map(|at| Self::now_ms() - *at)
    }

    pub fn mid(&self, tenant_id: &str, symbol: &str) -> Option<f64> {
        let t = self.get(tenant_id, symbol)?;
        Some((t.bid + t.ask) / 2.0)
    }
}
