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
            // Redis Pub/Sub and bridge reconnects can deliver a delayed packet.
            // Equal timestamps are legitimate, but an older quote must never
            // overwrite the one an order or the portal can already see.
            Some(prev) if tick.ts < prev.ts => return,
            Some(prev) => prev.bid != tick.bid || prev.ask != tick.ask,
            None => true,
        };
        if changed {
            self.changed_at
                .insert(tenant_id.to_string(), Self::now_ms());
        }
        self.ticks.insert(k, tick);
    }

    pub fn get(&self, tenant_id: &str, symbol: &str) -> Option<Tick> {
        self.ticks
            .get(&Self::key(tenant_id, symbol))
            .map(|t| t.clone())
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
        self.changed_at
            .get(tenant_id)
            .map(|at| Self::now_ms() - *at)
    }

    pub fn mid(&self, tenant_id: &str, symbol: &str) -> Option<f64> {
        let t = self.get(tenant_id, symbol)?;
        Some((t.bid + t.ask) / 2.0)
    }
}

#[cfg(test)]
mod tests {
    use super::{PriceSource, Tick};

    #[test]
    fn older_tick_cannot_replace_newer_quote() {
        let prices = PriceSource::new();
        prices.set(
            "tenant",
            Tick {
                symbol: "EURUSD".into(),
                bid: 1.1000,
                ask: 1.1002,
                ts: 2,
            },
        );
        prices.set(
            "tenant",
            Tick {
                symbol: "EURUSD".into(),
                bid: 1.0000,
                ask: 1.0002,
                ts: 1,
            },
        );
        let quote = prices.get("tenant", "EURUSD").unwrap();
        assert_eq!(quote.bid, 1.1000);
        assert_eq!(quote.ts, 2);
    }
}
