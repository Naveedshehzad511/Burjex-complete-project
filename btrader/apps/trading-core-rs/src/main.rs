#![allow(clippy::too_many_arguments, clippy::type_complexity, dead_code)]

mod books;
mod calc;
mod close_sync;
mod engine;
mod engine_ops;
mod engine_tick;
mod engine_trade;
mod error;
mod feed;
mod http;
mod models;
mod policy;
mod prices;
mod routing;
mod sessions;
mod trigger;

use engine::Engine;
use prices::PriceSource;
use std::sync::Arc;

pub fn engine_id() -> String {
    std::env::var("ENGINE_INSTANCE_ID").unwrap_or_else(|_| {
        let host = hostname::get()
            .ok()
            .and_then(|h| h.into_string().ok())
            .unwrap_or_else(|| "eng".into());
        format!("{host}-{}", std::process::id())
    })
}

fn pg_url(raw: &str) -> String {
    // Prisma adds schema= / connection_limit= which sqlx does not want.
    let Some((base, query)) = raw.split_once('?') else {
        return raw.to_string();
    };
    let kept: Vec<&str> = query
        .split('&')
        .filter(|p| {
            let k = p.split('=').next().unwrap_or("");
            !matches!(k, "schema" | "connection_limit" | "pool_timeout")
        })
        .collect();
    if kept.is_empty() {
        base.to_string()
    } else {
        format!("{base}?{}", kept.join("&"))
    }
}

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt()
        .with_env_filter(std::env::var("RUST_LOG").unwrap_or_else(|_| "info".into()))
        .init();

    let database_url = std::env::var("DATABASE_URL").expect("DATABASE_URL");
    let redis_url = std::env::var("REDIS_URL").unwrap_or_else(|_| "redis://127.0.0.1:6379".into());
    let port: u16 = std::env::var("ENGINE_HTTP_PORT")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(4300);

    if let Err(e) = feed::acquire_lock(&redis_url).await {
        tracing::error!(error=%e, "matching engine lock");
        std::process::exit(1);
    }

    let pool = sqlx::postgres::PgPoolOptions::new()
        .max_connections(
            std::env::var("ENGINE_PG_POOL")
                .ok()
                .and_then(|v| v.parse().ok())
                .unwrap_or(20),
        )
        .connect(&pg_url(&database_url))
        .await
        .expect("postgres");

    let redis = redis::Client::open(redis_url.as_str()).expect("redis url");
    let redis_con = redis.get_multiplexed_async_connection().await.expect("redis connect");
    let prices = Arc::new(PriceSource::new());
    let engine = Arc::new(Engine::new(pool, redis_con, prices.clone()));
    let held = engine.hydrate().await.unwrap_or(0);
    tracing::info!(positions = held, "position book hydrated");

    if let Err(e) = feed::run_feed(&redis_url, prices, engine.clone()).await {
        tracing::error!(error=%e, "feed start");
        std::process::exit(1);
    }

    let token = std::env::var("RUST_ENGINE_TOKEN").ok().filter(|s| !s.is_empty());
    let app = http::router(http::AppState {
        engine,
        token,
    });
    let addr = std::net::SocketAddr::from(([0, 0, 0, 0], port));
    tracing::info!(%addr, "matching engine listening");
    let listener = tokio::net::TcpListener::bind(addr).await.expect("bind");
    axum::serve(listener, app).await.expect("serve");
}
