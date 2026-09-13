use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::Json;
use serde::Serialize;

#[derive(Debug, Clone)]
pub struct BtError {
    pub code: &'static str,
    pub message: String,
}

impl BtError {
    pub fn new(code: &'static str, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
        }
    }
}

pub const UNAUTHORIZED: &str = "BT_UNAUTHORIZED";
pub const RATE_LIMITED: &str = "BT_RATE_LIMITED";
pub const SYMBOL_DISABLED: &str = "BT_SYMBOL_DISABLED";
pub const MARKET_CLOSED: &str = "BT_MARKET_CLOSED";
pub const INVALID_VOLUME: &str = "BT_INVALID_VOLUME";
pub const INVALID_PRICE: &str = "BT_INVALID_PRICE";
pub const STOPS_TOO_CLOSE: &str = "BT_STOPS_TOO_CLOSE";
pub const TRADING_DISABLED: &str = "BT_TRADING_DISABLED";
pub const INSUFFICIENT_MARGIN: &str = "BT_INSUFFICIENT_MARGIN";
pub const NO_PRICE: &str = "BT_NO_PRICE";
pub const FX_RATE_UNAVAILABLE: &str = "BT_FX_RATE_UNAVAILABLE";
pub const POSITION_NOT_FOUND: &str = "BT_POSITION_NOT_FOUND";
pub const ORDER_NOT_FOUND: &str = "BT_ORDER_NOT_FOUND";
pub const RISK_LIMIT_BREACH: &str = "BT_RISK_LIMIT_BREACH";
pub const VALIDATION: &str = "BT_VALIDATION";
pub const INTERNAL: &str = "BT_INTERNAL";

#[derive(Serialize)]
struct Body<'a> {
    code: &'a str,
    message: &'a str,
}

impl IntoResponse for BtError {
    fn into_response(self) -> Response {
        let status = match self.code {
            UNAUTHORIZED => StatusCode::UNAUTHORIZED,
            RATE_LIMITED => StatusCode::TOO_MANY_REQUESTS,
            POSITION_NOT_FOUND | ORDER_NOT_FOUND => StatusCode::NOT_FOUND,
            TRADING_DISABLED => StatusCode::FORBIDDEN,
            NO_PRICE | FX_RATE_UNAVAILABLE => StatusCode::SERVICE_UNAVAILABLE,
            INTERNAL => StatusCode::INTERNAL_SERVER_ERROR,
            _ => StatusCode::BAD_REQUEST,
        };
        (status, Json(Body { code: self.code, message: &self.message })).into_response()
    }
}

impl From<sqlx::Error> for BtError {
    fn from(e: sqlx::Error) -> Self {
        tracing::error!(error = %e, "db error");
        BtError::new(INTERNAL, e.to_string())
    }
}

impl From<redis::RedisError> for BtError {
    fn from(e: redis::RedisError) -> Self {
        tracing::error!(error = %e, "redis error");
        BtError::new(INTERNAL, e.to_string())
    }
}

pub type BtResult<T> = Result<T, BtError>;
