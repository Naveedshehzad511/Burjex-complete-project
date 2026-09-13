use chrono::{DateTime, Utc};
use serde_json::Value;
use sqlx::Row;

#[derive(Debug, Clone)]
pub struct AccountRow {
    pub id: String,
    pub tenant_id: String,
    pub login: String,
    pub status: String,
    pub currency: String,
    pub leverage: i32,
    pub is_demo: bool,
    pub book: Option<String>,
    pub group_id: Option<String>,
    pub balance: f64,
    pub credit: f64,
    pub margin_call_level: i32,
    pub stop_out_level: i32,
}

#[derive(Debug, Clone)]
pub struct SymbolRow {
    pub id: String,
    pub tenant_id: String,
    pub symbol: String,
    pub class: String,
    pub enabled: bool,
    pub digits: i32,
    pub pip_size: f64,
    pub contract_size: f64,
    pub min_lot: f64,
    pub max_lot: f64,
    pub lot_step: f64,
    pub margin_rate: f64,
    pub margin_percent: Option<f64>,
    pub quote_currency: String,
    pub base_currency: String,
    pub slippage_points: i32,
    pub spread_markup: i32,
    pub stops_level: i32,
    pub news_mode: bool,
    pub news_spread_points: i32,
    pub news_halt_opens: bool,
    pub force_book: Option<String>,
    pub group_id: Option<String>,
    pub trading_sessions: Option<Value>,
}

pub fn f8(row: &sqlx::postgres::PgRow, col: &str) -> f64 {
    row.try_get::<f64, _>(col).unwrap_or(0.0)
}

pub fn opt_f8(row: &sqlx::postgres::PgRow, col: &str) -> Option<f64> {
    row.try_get::<Option<f64>, _>(col).ok().flatten()
}

pub fn s(row: &sqlx::postgres::PgRow, col: &str) -> String {
    row.try_get::<String, _>(col).unwrap_or_default()
}

pub fn opt_s(row: &sqlx::postgres::PgRow, col: &str) -> Option<String> {
    row.try_get::<Option<String>, _>(col).ok().flatten()
}

pub fn i32c(row: &sqlx::postgres::PgRow, col: &str) -> i32 {
    row.try_get::<i32, _>(col).unwrap_or(0)
}

pub fn b(row: &sqlx::postgres::PgRow, col: &str) -> bool {
    row.try_get::<bool, _>(col).unwrap_or(false)
}

pub fn account_from_row(row: &sqlx::postgres::PgRow) -> AccountRow {
    AccountRow {
        id: s(row, "id"),
        tenant_id: s(row, "tenantId"),
        login: s(row, "login"),
        status: s(row, "status"),
        currency: s(row, "currency"),
        leverage: i32c(row, "leverage"),
        is_demo: b(row, "isDemo"),
        book: opt_s(row, "book"),
        group_id: opt_s(row, "groupId"),
        balance: f8(row, "balance"),
        credit: f8(row, "credit"),
        margin_call_level: i32c(row, "marginCallLevel"),
        stop_out_level: i32c(row, "stopOutLevel"),
    }
}

pub fn symbol_from_row(row: &sqlx::postgres::PgRow) -> SymbolRow {
    SymbolRow {
        id: s(row, "id"),
        tenant_id: s(row, "tenantId"),
        symbol: s(row, "symbol"),
        class: s(row, "class"),
        enabled: b(row, "enabled"),
        digits: i32c(row, "digits"),
        pip_size: f8(row, "pipSize"),
        contract_size: f8(row, "contractSize"),
        min_lot: f8(row, "minLot"),
        max_lot: f8(row, "maxLot"),
        lot_step: f8(row, "lotStep"),
        margin_rate: f8(row, "marginRate"),
        margin_percent: opt_f8(row, "marginPercent"),
        quote_currency: s(row, "quoteCurrency"),
        base_currency: s(row, "baseCurrency"),
        slippage_points: i32c(row, "slippagePoints"),
        spread_markup: i32c(row, "spreadMarkup"),
        stops_level: i32c(row, "stopsLevel"),
        news_mode: b(row, "newsMode"),
        news_spread_points: i32c(row, "newsSpreadPoints"),
        news_halt_opens: b(row, "newsHaltOpens"),
        force_book: opt_s(row, "forceBook"),
        group_id: opt_s(row, "groupId"),
        trading_sessions: row.try_get::<Option<Value>, _>("tradingSessions").ok().flatten(),
    }
}

pub const ACCOUNT_SELECT: &str = r#"
SELECT id, "tenantId", login, status::text AS status, currency, leverage, "isDemo",
       book::text AS book, "groupId",
       balance::float8 AS balance, credit::float8 AS credit,
       "marginCallLevel", "stopOutLevel"
FROM accounts
"#;

pub const SYMBOL_SELECT: &str = r#"
SELECT id, "tenantId", symbol, class::text AS class, enabled, digits,
       "pipSize"::float8 AS "pipSize", "contractSize"::float8 AS "contractSize",
       "minLot"::float8 AS "minLot", "maxLot"::float8 AS "maxLot", "lotStep"::float8 AS "lotStep",
       "marginRate"::float8 AS "marginRate", "marginPercent"::float8 AS "marginPercent",
       "quoteCurrency", "baseCurrency", "slippagePoints", "spreadMarkup", "stopsLevel",
       "newsMode", "newsSpreadPoints", "newsHaltOpens", "forceBook"::text AS "forceBook",
       "groupId", "tradingSessions"
FROM symbols
"#;

#[derive(Debug, Clone)]
pub struct Snapshot {
    pub account_id: String,
    pub login: String,
    pub currency: String,
    pub leverage: i32,
    pub balance: f64,
    pub credit: f64,
    pub equity: f64,
    pub margin: f64,
    pub free_margin: f64,
    pub margin_level: f64,
    pub floating_pl: f64,
    pub ts: i64,
}

impl Snapshot {
    pub fn json(&self) -> serde_json::Value {
        serde_json::json!({
            "accountId": self.account_id,
            "login": self.login,
            "currency": self.currency,
            "leverage": self.leverage,
            "balance": self.balance,
            "credit": self.credit,
            "equity": self.equity,
            "margin": self.margin,
            "freeMargin": self.free_margin,
            "marginLevel": self.margin_level,
            "floatingPL": self.floating_pl,
            "closedPL": 0,
            "bonus": self.credit,
            "dividend": 0,
            "ts": self.ts,
        })
    }
}

pub fn now_ms() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

pub fn ts(dt: DateTime<Utc>) -> String {
    dt.to_rfc3339_opts(chrono::SecondsFormat::Millis, true)
}
