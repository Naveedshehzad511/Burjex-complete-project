use crate::engine::Engine;
use crate::prices::{PriceSource, Tick};
use dashmap::DashMap;
use futures_util::StreamExt;
use redis::AsyncCommands;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::Mutex;

/// Consume the same Redis tick stream Node market-data publishes:
/// channel `bt:{tenantId}:ticks` payload `{symbol,bid,ask,ts}`.
pub async fn run_feed(
    redis_url: &str,
    prices: Arc<PriceSource>,
    engine: Arc<Engine>,
) -> Result<(), redis::RedisError> {
    let client = redis::Client::open(redis_url)?;
    warmup_lastticks(&client, &prices).await.ok();

    let dirty_fast: Arc<DashMap<String, (String, String)>> = Arc::new(DashMap::new());
    let dirty_slow: Arc<DashMap<String, (String, String)>> = Arc::new(DashMap::new());

    let mut fast_ms = std::env::var("ENGINE_FAST_INTERVAL_MS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(1u64);
    // Cap so we never sleep tens of ms between SL checks in news.
    if fast_ms > 5 {
        tracing::warn!(fast_ms, "ENGINE_FAST_INTERVAL_MS capped at 5ms for SL/TP latency");
        fast_ms = 5;
    }
    fast_ms = fast_ms.max(1);
    let slow_ms = std::env::var("ENGINE_TICK_INTERVAL_MS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(250u64)
        .max(50);

    let df = dirty_fast.clone();
    let eng = engine.clone();
    tokio::spawn(async move {
        let mut tick = tokio::time::interval(Duration::from_millis(fast_ms));
        loop {
            tick.tick().await;
            let batch: Vec<(String, String)> = df.iter().map(|e| e.value().clone()).collect();
            df.clear();
            for (tenant, symbol) in batch {
                eng.on_tick_fast(&tenant, &symbol).await;
            }
        }
    });
    let ds = dirty_slow.clone();
    let eng = engine.clone();
    tokio::spawn(async move {
        let mut tick = tokio::time::interval(Duration::from_millis(slow_ms));
        loop {
            tick.tick().await;
            let batch: Vec<(String, String)> = ds.iter().map(|e| e.value().clone()).collect();
            ds.clear();
            for (tenant, symbol) in batch {
                eng.on_tick_slow(&tenant, &symbol).await;
            }
        }
    });

    let redis_owned = redis_url.to_string();
    let cfg_eng = engine.clone();
    tokio::spawn(async move {
        loop {
            if let Err(e) = subscribe_ticks(&redis_owned, prices.clone(), dirty_fast.clone(), dirty_slow.clone(), cfg_eng.clone()).await {
                tracing::error!(error=%e, "tick subscribe dropped; reconnecting");
                tokio::time::sleep(Duration::from_secs(1)).await;
            }
        }
    });
    Ok(())
}

async fn warmup_lastticks(client: &redis::Client, prices: &PriceSource) -> Result<(), redis::RedisError> {
    let mut con = client.get_multiplexed_async_connection().await?;
    let keys: Vec<String> = redis::cmd("KEYS").arg("bt:*:lastticks").query_async(&mut con).await?;
    for key in keys {
        let parts: Vec<&str> = key.split(':').collect();
        if parts.len() < 3 {
            continue;
        }
        let tenant = parts[1];
        let map: std::collections::HashMap<String, String> = con.hgetall(&key).await?;
        for (_sym, payload) in map {
            if let Ok(tick) = serde_json::from_str::<Tick>(&payload) {
                prices.set(tenant, tick);
            }
        }
    }
    tracing::info!("price cache warmed from Redis lastticks");
    Ok(())
}

async fn subscribe_ticks(
    redis_url: &str,
    prices: Arc<PriceSource>,
    dirty_fast: Arc<DashMap<String, (String, String)>>,
    dirty_slow: Arc<DashMap<String, (String, String)>>,
    engine: Arc<Engine>,
) -> Result<(), redis::RedisError> {
    let client = redis::Client::open(redis_url)?;
    let mut pubsub = client.get_async_pubsub().await?;
    pubsub.psubscribe("bt:*:ticks").await?;
    pubsub.subscribe("bt:engine.cfg").await?;
    let mut stream = pubsub.on_message();
    while let Some(msg) = stream.next().await {
        let channel: String = msg.get_channel_name().to_string();
        let payload: String = msg.get_payload().unwrap_or_default();
        if channel == "bt:engine.cfg" {
            let id = serde_json::from_str::<serde_json::Value>(&payload)
                .ok()
                .and_then(|v| v.get("id").and_then(|x| x.as_str()).map(|s| s.to_string()));
            engine.invalidate_group(id.as_deref());
            continue;
        }
        let tenant = channel.split(':').nth(1).unwrap_or("").to_string();
        let Ok(tick) = serde_json::from_str::<Tick>(&payload) else {
            continue;
        };
        let symbol = tick.symbol.clone();
        prices.set(&tenant, tick);
        let dkey = format!("{tenant}\u{0000}{symbol}");
        dirty_fast.insert(dkey.clone(), (tenant.clone(), symbol.clone()));
        dirty_slow.insert(dkey, (tenant, symbol));
    }
    Ok(())
}

pub async fn acquire_lock(redis_url: &str) -> Result<Mutex<()>, String> {
    if std::env::var("ENGINE_INSTANCE_LOCK").ok().as_deref() == Some("off") {
        tracing::warn!("INSTANCE LOCK DISABLED");
        return Ok(Mutex::new(()));
    }
    let client = redis::Client::open(redis_url).map_err(|e| e.to_string())?;
    let mut con = client.get_multiplexed_async_connection().await.map_err(|e| e.to_string())?;
    let id = uuid::Uuid::new_v4().to_string();
    let key = "bt:engine:instance-lock";
    let ttl: u64 = std::env::var("ENGINE_LOCK_TTL_MS").ok().and_then(|v| v.parse().ok()).unwrap_or(30_000);
    let ok: Option<String> = redis::cmd("SET")
        .arg(key)
        .arg(&id)
        .arg("PX")
        .arg(ttl)
        .arg("NX")
        .query_async(&mut con)
        .await
        .map_err(|e| e.to_string())?;
    if ok.as_deref() != Some("OK") {
        return Err(format!("another matching engine already holds {key}"));
    }
    let id2 = id.clone();
    tokio::spawn(async move {
        let mut interval = tokio::time::interval(Duration::from_millis((ttl / 3).max(1000)));
        loop {
            interval.tick().await;
            let script = r#"if redis.call('get', KEYS[1]) == ARGV[1] then return redis.call('pexpire', KEYS[1], ARGV[2]) else return 0 end"#;
            let ok: Result<i32, _> = redis::cmd("EVAL")
                .arg(script)
                .arg(1)
                .arg(key)
                .arg(&id2)
                .arg(ttl)
                .query_async(&mut con)
                .await;
            match ok {
                Ok(1) => {}
                _ => {
                    tracing::error!("lost matching-engine instance lock");
                    std::process::exit(1);
                }
            }
        }
    });
    Ok(Mutex::new(()))
}
