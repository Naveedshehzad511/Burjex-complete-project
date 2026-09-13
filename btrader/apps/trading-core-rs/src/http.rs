use crate::engine::{Engine, PlaceReq};
use crate::error::{BtError, UNAUTHORIZED};
use axum::extract::{Path, State};
use axum::http::HeaderMap;
use axum::routing::{delete, get, patch, post};
use axum::{Json, Router};
use serde::Deserialize;
use serde_json::{json, Value};
use std::sync::Arc;

#[derive(Clone)]
pub struct AppState {
    pub engine: Arc<Engine>,
    pub token: Option<String>,
}

fn auth(headers: &HeaderMap, token: &Option<String>) -> Result<(), BtError> {
    let Some(expected) = token.as_ref().filter(|s| !s.is_empty()) else {
        return Ok(());
    };
    let got = headers
        .get("x-engine-token")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("");
    if got != expected {
        return Err(BtError::new(UNAUTHORIZED, "bad engine token"));
    }
    Ok(())
}

#[derive(Deserialize)]
pub struct PlaceBody {
    #[serde(rename = "tenantId")]
    tenant_id: String,
    #[serde(rename = "accountId")]
    account_id: String,
    symbol: String,
    side: String,
    #[serde(rename = "type")]
    order_type: String,
    volume: f64,
    price: Option<f64>,
    stop_price: Option<f64>,
    #[serde(rename = "stopPrice")]
    stop_price2: Option<f64>,
    sl_price: Option<f64>,
    #[serde(rename = "slPrice")]
    sl_price2: Option<f64>,
    tp_price: Option<f64>,
    #[serde(rename = "tpPrice")]
    tp_price2: Option<f64>,
    #[serde(rename = "timeInForce")]
    time_in_force: Option<String>,
    #[serde(rename = "expiresAt")]
    expires_at: Option<String>,
    comment: Option<String>,
    #[serde(rename = "oneClick")]
    one_click: Option<bool>,
    #[serde(rename = "clientOrderId")]
    client_order_id: Option<String>,
    source: Option<String>,
}

async fn place(State(st): State<AppState>, headers: HeaderMap, Json(b): Json<PlaceBody>) -> Result<Json<Value>, BtError> {
    auth(&headers, &st.token)?;
    let req = PlaceReq {
        account_id: b.account_id,
        symbol: b.symbol,
        side: b.side,
        order_type: b.order_type,
        volume: b.volume,
        price: b.price,
        stop_price: b.stop_price.or(b.stop_price2),
        sl_price: b.sl_price.or(b.sl_price2),
        tp_price: b.tp_price.or(b.tp_price2),
        time_in_force: b.time_in_force,
        expires_at: b.expires_at,
        comment: b.comment,
        one_click: b.one_click,
        client_order_id: b.client_order_id,
        source: b.source,
    };
    Ok(Json(st.engine.place_order(&b.tenant_id, req).await?.json()))
}

#[derive(Deserialize)]
struct TenantBody {
    #[serde(rename = "tenantId")]
    tenant_id: String,
}

#[derive(Deserialize)]
struct CloseBody {
    #[serde(rename = "tenantId")]
    tenant_id: String,
    volume: Option<f64>,
    #[serde(rename = "closePriceOverride")]
    close_price_override: Option<f64>,
    #[serde(rename = "requireAccountId")]
    require_account_id: Option<String>,
    #[serde(rename = "accountIdForQueue")]
    account_id_for_queue: Option<String>,
}

async fn close(
    State(st): State<AppState>,
    headers: HeaderMap,
    Path(id): Path<String>,
    Json(b): Json<CloseBody>,
) -> Result<Json<Value>, BtError> {
    auth(&headers, &st.token)?;
    Ok(Json(
        st.engine
            .close_position(
                &b.tenant_id,
                &id,
                b.volume,
                b.close_price_override,
                None,
                None,
                false,
                b.require_account_id.as_deref(),
                false,
                false,
                b.account_id_for_queue,
            )
            .await?
            .json(),
    ))
}

#[derive(Deserialize)]
struct CloseAllBody {
    #[serde(rename = "tenantId")]
    tenant_id: String,
    #[serde(rename = "accountId")]
    account_id: String,
}

async fn close_all(State(st): State<AppState>, headers: HeaderMap, Json(b): Json<CloseAllBody>) -> Result<Json<Value>, BtError> {
    auth(&headers, &st.token)?;
    let n = st.engine.close_all(&b.tenant_id, &b.account_id).await?;
    Ok(Json(json!({"closed": n})))
}

async fn modify_pos(
    State(st): State<AppState>,
    headers: HeaderMap,
    Path(id): Path<String>,
    Json(b): Json<Value>,
) -> Result<Json<Value>, BtError> {
    auth(&headers, &st.token)?;
    let tenant = b.get("tenantId").and_then(|v| v.as_str()).unwrap_or("");
    let sl = if b.get("slPrice").is_some() {
        Some(b.get("slPrice").and_then(|v| v.as_f64()))
    } else {
        None
    };
    let tp = if b.get("tpPrice").is_some() {
        Some(b.get("tpPrice").and_then(|v| v.as_f64()))
    } else {
        None
    };
    Ok(Json(st.engine.modify_position(tenant, &id, sl, tp).await?))
}

async fn cancel(
    State(st): State<AppState>,
    headers: HeaderMap,
    Path(id): Path<String>,
    Json(b): Json<TenantBody>,
) -> Result<Json<Value>, BtError> {
    auth(&headers, &st.token)?;
    st.engine.cancel_order(&b.tenant_id, &id).await?;
    Ok(Json(json!({"ok": true})))
}

async fn modify_order(
    State(st): State<AppState>,
    headers: HeaderMap,
    Path(id): Path<String>,
    Json(b): Json<Value>,
) -> Result<Json<Value>, BtError> {
    auth(&headers, &st.token)?;
    let tenant = b.get("tenantId").and_then(|v| v.as_str()).unwrap_or("");
    let price = opt_num(&b, "price");
    let stop = opt_num(&b, "stopPrice");
    let sl = opt_num(&b, "slPrice");
    let tp = opt_num(&b, "tpPrice");
    st.engine.modify_order(tenant, &id, price, stop, sl, tp).await?;
    Ok(Json(json!({"ok": true})))
}

fn opt_num(b: &Value, key: &str) -> Option<Option<f64>> {
    if !b.get(key).is_some() {
        return None;
    }
    Some(b.get(key).and_then(|v| if v.is_null() { None } else { v.as_f64() }))
}

#[derive(Deserialize)]
struct OpenPx {
    #[serde(rename = "tenantId")]
    tenant_id: String,
    #[serde(rename = "openPrice")]
    open_price: f64,
}

async fn set_open(
    State(st): State<AppState>,
    headers: HeaderMap,
    Path(id): Path<String>,
    Json(b): Json<OpenPx>,
) -> Result<Json<Value>, BtError> {
    auth(&headers, &st.token)?;
    st.engine.set_open_price(&b.tenant_id, &id, b.open_price).await?;
    Ok(Json(json!({"ok": true})))
}

#[derive(Deserialize)]
struct CoverMore {
    #[serde(rename = "tenantId")]
    tenant_id: String,
    lots: f64,
}

async fn cover_more(
    State(st): State<AppState>,
    headers: HeaderMap,
    Path(id): Path<String>,
    Json(b): Json<CoverMore>,
) -> Result<Json<Value>, BtError> {
    auth(&headers, &st.token)?;
    Ok(Json(st.engine.cover_more(&b.tenant_id, &id, b.lots).await?))
}

async fn health() -> Json<Value> {
    Json(json!({"ok": true, "role": "matching"}))
}

async fn invalidate(State(st): State<AppState>, headers: HeaderMap, Json(b): Json<Value>) -> Result<Json<Value>, BtError> {
    auth(&headers, &st.token)?;
    let id = b.get("id").and_then(|v| v.as_str());
    st.engine.invalidate_group(id);
    Ok(Json(json!({"ok": true})))
}

pub fn router(state: AppState) -> Router {
    Router::new()
        .route("/health", get(health))
        .route("/v1/place", post(place))
        .route("/v1/positions/{id}/close", post(close))
        .route("/v1/close-all", post(close_all))
        .route("/v1/positions/{id}", patch(modify_pos))
        .route("/v1/positions/{id}/open-price", patch(set_open))
        .route("/v1/positions/{id}/cover-more", post(cover_more))
        .route("/v1/orders/{id}", delete(cancel).patch(modify_order))
        .route("/v1/cfg/invalidate", post(invalidate))
        .with_state(state)
}
