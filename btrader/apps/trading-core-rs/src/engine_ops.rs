use crate::calc::{
    point_size, resolve_fx_factor, spread_markup_from_band, GroupPricing, OpenPositionView,
};
use crate::engine::{Engine, ExecResult, GroupBundle, MarkupRule, MappingRow, CONFIG_CACHE_MS, SYMBOL_CACHE_MS};
use crate::error::{BtError, BtResult, FX_RATE_UNAVAILABLE, RISK_LIMIT_BREACH, SYMBOL_DISABLED};
use crate::models::{account_from_row, symbol_from_row, AccountRow, Snapshot, SymbolRow, ACCOUNT_SELECT};
use crate::routing::RoutingRuleLike;
use chrono::Utc;
use serde_json::json;
use sqlx::{Postgres, Row, Transaction};
use std::collections::HashSet;
use std::time::Instant;
use uuid::Uuid;

impl Engine {
    pub async fn load_account(&self, tenant_id: &str, id: &str) -> BtResult<Option<AccountRow>> {
        let row = sqlx::query(&format!("{ACCOUNT_SELECT} WHERE id = $1 AND \"tenantId\" = $2"))
            .bind(id)
            .bind(tenant_id)
            .fetch_optional(&self.pool)
            .await?;
        Ok(row.map(|r| account_from_row(&r)))
    }

    pub async fn load_symbol(&self, tenant_id: &str, symbol: &str) -> BtResult<Option<SymbolRow>> {
        let key = format!("{tenant_id}\u{0000}{symbol}");
        if let Some(hit) = self.symbol_cache.get(&key) {
            if hit.1.elapsed().as_millis() < SYMBOL_CACHE_MS {
                return Ok(Some(hit.0.clone()));
            }
        }
        let row = sqlx::query(&format!(
            "{} WHERE \"tenantId\" = $1 AND symbol = $2",
            crate::models::SYMBOL_SELECT
        ))
        .bind(tenant_id)
        .bind(symbol)
        .fetch_optional(&self.pool)
        .await?;
        let parsed = row.map(|r| symbol_from_row(&r));
        if let Some(s) = parsed.clone() {
            self.symbol_cache.insert(key, (s, Instant::now()));
        }
        Ok(parsed)
    }

    pub(crate) async fn find_client_order(&self, tenant_id: &str, account_id: &str, cid: &str) -> BtResult<Option<ExecResult>> {
        let row = sqlx::query(
            r#"SELECT id, status::text AS status, "positionId", "avgFillPrice"::float8 AS "avgFillPrice",
                      "filledVolume"::float8 AS "filledVolume"
               FROM orders WHERE "tenantId"=$1 AND "accountId"=$2 AND "clientOrderId"=$3 LIMIT 1"#,
        )
        .bind(tenant_id)
        .bind(account_id)
        .bind(cid)
        .fetch_optional(&self.pool)
        .await?;
        Ok(row.map(|r| {
            let status: String = r.try_get("status").unwrap_or_default();
            ExecResult {
                accepted: matches!(status.as_str(), "FILLED" | "PENDING" | "PARTIAL"),
                order_id: Some(r.try_get("id").unwrap_or_default()),
                position_id: r.try_get::<Option<String>, _>("positionId").ok().flatten(),
                status,
                fill_price: r.try_get("avgFillPrice").ok(),
                filled_volume: r.try_get("filledVolume").ok(),
                reason: None,
                account: None,
            }
        }))
    }

    pub(crate) async fn assert_group_symbol_access(&self, account: &AccountRow, sym: &SymbolRow) -> BtResult<()> {
        let Some(gid) = account.group_id.as_ref() else {
            return Ok(());
        };
        let picks: Vec<(String,)> = sqlx::query_as(r#"SELECT "symbolId" FROM trading_group_symbols WHERE "tradingGroupId"=$1"#)
            .bind(gid)
            .fetch_all(&self.pool)
            .await
            .unwrap_or_default();
        if !picks.is_empty() {
            if !picks.iter().any(|(id,)| id == &sym.id) {
                return Err(BtError::new(SYMBOL_DISABLED, "symbol not available for your account group"));
            }
            return Ok(());
        }
        let access: Vec<(String,)> =
            sqlx::query_as(r#"SELECT "symbolGroupId" FROM trading_group_symbol_access WHERE "tradingGroupId"=$1"#)
                .bind(gid)
                .fetch_all(&self.pool)
                .await
                .unwrap_or_default();
        if !access.is_empty() {
            let allowed: HashSet<String> = access.into_iter().map(|r| r.0).collect();
            if sym.group_id.as_ref().map(|g| !allowed.contains(g)).unwrap_or(true) {
                return Err(BtError::new(SYMBOL_DISABLED, "symbol not available for your account group"));
            }
        }
        Ok(())
    }

    pub(crate) async fn enforce_risk(&self, tenant_id: &str, account_id: &str, volume: f64) -> BtResult<()> {
        let rows = sqlx::query(
            r#"SELECT "maxLotPerOrder"::float8 AS max_lot, "maxOpenPositions", "maxOpenLots"::float8 AS max_open_lots, scope
               FROM risk_limits WHERE "tenantId"=$1 AND enabled=true AND (scope='tenant' OR scope=$2)"#,
        )
        .bind(tenant_id)
        .bind(format!("account:{account_id}"))
        .fetch_all(&self.pool)
        .await?;
        for r in rows {
            if let Ok(Some(max_lot)) = r.try_get::<Option<f64>, _>("max_lot") {
                if volume > max_lot {
                    return Err(BtError::new(RISK_LIMIT_BREACH, "max lot per order exceeded"));
                }
            }
            if let Ok(Some(max_pos)) = r.try_get::<Option<i32>, _>("maxOpenPositions") {
                let (count,): (i64,) = sqlx::query_as(
                    r#"SELECT COUNT(*) FROM positions WHERE "tenantId"=$1 AND "accountId"=$2 AND status='OPEN'"#,
                )
                .bind(tenant_id)
                .bind(account_id)
                .fetch_one(&self.pool)
                .await?;
                if count >= i64::from(max_pos) {
                    return Err(BtError::new(RISK_LIMIT_BREACH, "max open positions reached"));
                }
            }
            if let Ok(Some(max_lots)) = r.try_get::<Option<f64>, _>("max_open_lots") {
                let (sum,): (Option<f64>,) = sqlx::query_as(
                    r#"SELECT COALESCE(SUM(volume),0)::float8 FROM positions WHERE "tenantId"=$1 AND "accountId"=$2 AND status='OPEN'"#,
                )
                .bind(tenant_id)
                .bind(account_id)
                .fetch_one(&self.pool)
                .await?;
                if sum.unwrap_or(0.0) + volume > max_lots {
                    return Err(BtError::new(RISK_LIMIT_BREACH, "max open lots exceeded"));
                }
            }
        }
        Ok(())
    }

    pub(crate) async fn group_pricing(&self, group_id: Option<&str>, sym: &SymbolRow, tenant_id: &str) -> BtResult<GroupPricing> {
        let none = GroupPricing {
            execution_mode: "MARKET".into(),
            execution_apply_to: json!({}),
            ..Default::default()
        };
        let Some(gid) = group_id else {
            return Ok(none);
        };
        if let Some(hit) = self.group_cache.get(gid) {
            if hit.1.elapsed().as_millis() < CONFIG_CACHE_MS {
                return Ok(self.pricing_from_bundle(&hit.0, sym, tenant_id));
            }
        }
        let Some(g) = sqlx::query(
            r#"SELECT enabled, "markupPoints", "slippagePoints", "commissionType"::text AS "commissionType",
                      "commissionValue"::float8 AS "commissionValue", "executionMode"::text AS "executionMode",
                      "executionDelayMs", "executionApplyTo"
               FROM trading_groups WHERE id=$1"#,
        )
        .bind(gid)
        .fetch_optional(&self.pool)
        .await?
        else {
            return Ok(none);
        };
        let enabled: bool = g.try_get("enabled").unwrap_or(false);
        let rules = sqlx::query(
            r#"SELECT "symbolId", "instrumentClass"::text AS class, "markupPoints",
                      "commissionType"::text AS "commissionType", "commissionValue"::float8 AS "commissionValue"
               FROM group_markup_rules WHERE "groupId"=$1"#,
        )
        .bind(gid)
        .fetch_all(&self.pool)
        .await
        .unwrap_or_default();
        let mappings = sqlx::query(
            r#"SELECT enabled, "symbolId", "lpSymbol", "pricingMethod"::text AS "pricingMethod",
                      "minSpreadPoints", "maxSpreadPoints", "commissionType"::text AS "commissionType",
                      "commissionValue"::float8 AS "commissionValue"
               FROM trading_group_symbol_mappings WHERE "tradingGroupId"=$1"#,
        )
        .bind(gid)
        .fetch_all(&self.pool)
        .await
        .unwrap_or_default();
        let bundle = GroupBundle {
            enabled,
            markup_points: g.try_get::<i32, _>("markupPoints").unwrap_or(0) as f64,
            slippage_points: g.try_get::<i32, _>("slippagePoints").unwrap_or(0) as f64,
            commission_type: g.try_get("commissionType").unwrap_or_else(|_| "NONE".into()),
            commission_value: try_f(&g, "commissionValue"),
            execution_mode: g.try_get("executionMode").unwrap_or_else(|_| "MARKET".into()),
            execution_delay_ms: g.try_get("executionDelayMs").unwrap_or(0),
            execution_apply_to: g.try_get("executionApplyTo").unwrap_or(json!({})),
            rules: rules
                .into_iter()
                .map(|r| MarkupRule {
                    symbol_id: r.try_get("symbolId").ok(),
                    instrument_class: r.try_get("class").ok(),
                    markup_points: r.try_get::<i32, _>("markupPoints").unwrap_or(0) as f64,
                    commission_type: r.try_get("commissionType").ok(),
                    commission_value: r.try_get("commissionValue").ok(),
                })
                .collect(),
            mappings: mappings
                .into_iter()
                .map(|r| MappingRow {
                    enabled: r.try_get("enabled").unwrap_or(true),
                    symbol_id: r.try_get("symbolId").ok(),
                    lp_symbol: r.try_get("lpSymbol").unwrap_or_default(),
                    pricing_method: r.try_get("pricingMethod").unwrap_or_else(|_| "SPREAD_ONLY".into()),
                    min_spread_points: r.try_get::<i32, _>("minSpreadPoints").unwrap_or(0) as f64,
                    max_spread_points: r.try_get::<i32, _>("maxSpreadPoints").unwrap_or(0) as f64,
                    commission_type: r.try_get("commissionType").unwrap_or_else(|_| "NONE".into()),
                    commission_value: try_f(&r, "commissionValue"),
                })
                .collect(),
        };
        let out = self.pricing_from_bundle(&bundle, sym, tenant_id);
        self.group_cache.insert(gid.to_string(), (bundle, Instant::now()));
        Ok(out)
    }

    fn pricing_from_bundle(&self, group: &GroupBundle, sym: &SymbolRow, tenant_id: &str) -> GroupPricing {
        if !group.enabled {
            return GroupPricing {
                execution_mode: "MARKET".into(),
                execution_apply_to: json!({}),
                ..Default::default()
            };
        }
        let mapping = group.mappings.iter().find(|m| {
            m.enabled
                && (m.symbol_id.as_deref() == Some(sym.id.as_str())
                    || m.lp_symbol.eq_ignore_ascii_case(&sym.symbol))
        });
        let has_mappings = !group.mappings.is_empty();
        let mut markup_points = 0.0;
        let mut commission_type = "NONE".to_string();
        let mut commission_value = 0.0;
        let mut pricing_method = None;
        let mut min_spread_points = 0.0;
        let mut max_spread_points = 0.0;
        if let Some(mapping) = mapping {
            pricing_method = Some(mapping.pricing_method.clone());
            min_spread_points = mapping.min_spread_points;
            max_spread_points = mapping.max_spread_points;
            let tick = self.prices.get(tenant_id, &sym.symbol);
            let lp_spread = tick
                .map(|t| ((t.ask - t.bid) / point_size(sym.digits)).max(0.0))
                .unwrap_or(0.0);
            markup_points = spread_markup_from_band(
                lp_spread,
                Some(&mapping.pricing_method),
                mapping.min_spread_points,
                mapping.max_spread_points,
                0.0,
            );
            if mapping.pricing_method == "SPREAD_ONLY" {
                commission_type = "NONE".into();
                commission_value = 0.0;
            } else {
                commission_type = mapping.commission_type.clone();
                commission_value = if commission_type == "NONE" {
                    0.0
                } else {
                    mapping.commission_value
                };
            }
        } else if !has_mappings {
            let sym_rule = group.rules.iter().find(|r| r.symbol_id.as_deref() == Some(sym.id.as_str()));
            let class_rule = group
                .rules
                .iter()
                .find(|r| r.symbol_id.is_none() && r.instrument_class.as_deref() == Some(sym.class.as_str()));
            markup_points = sym_rule
                .map(|r| r.markup_points)
                .or_else(|| class_rule.map(|r| r.markup_points))
                .unwrap_or(group.markup_points);
            let comm_rule = if sym_rule.and_then(|r| r.commission_type.as_ref()).is_some() {
                sym_rule
            } else if class_rule.and_then(|r| r.commission_type.as_ref()).is_some() {
                class_rule
            } else {
                None
            };
            commission_type = comm_rule
                .and_then(|r| r.commission_type.clone())
                .unwrap_or_else(|| group.commission_type.clone());
            commission_value = if commission_type == "NONE" {
                0.0
            } else {
                comm_rule.and_then(|r| r.commission_value).unwrap_or(group.commission_value)
            };
        }
        GroupPricing {
            markup_points,
            slippage_points: group.slippage_points,
            commission_type,
            commission_value,
            min_spread_points,
            max_spread_points,
            pricing_method,
            execution_mode: group.execution_mode.clone(),
            instant_deviation_points: 0.0,
            execution_delay_ms: group.execution_delay_ms,
            execution_apply_to: group.execution_apply_to.clone(),
        }
    }

    pub(crate) async fn symbol_group_book(&self, group_id: &str) -> BtResult<Option<String>> {
        let row = sqlx::query(r#"SELECT "defaultBook"::text AS book FROM symbol_groups WHERE id=$1"#)
            .bind(group_id)
            .fetch_optional(&self.pool)
            .await?;
        Ok(row.and_then(|r| r.try_get("book").ok()))
    }

    pub(crate) async fn routing_rules(&self, tenant_id: &str) -> BtResult<Vec<RoutingRuleLike>> {
        if let Some(hit) = self.routing_cache.get(tenant_id) {
            if hit.1.elapsed().as_millis() < CONFIG_CACHE_MS {
                return Ok(hit.0.clone());
            }
        }
        let rows = sqlx::query(
            r#"SELECT id, "tradingGroupId", "symbolId", "instrumentClass"::text AS class, book::text AS book,
                      "venueMode"::text AS "venueMode", "lpProviderId", "lpDriver"::text AS "lpDriver",
                      "coverageRatio", priority, "createdAt"
               FROM routing_rules WHERE "tenantId"=$1 AND enabled=true"#,
        )
        .bind(tenant_id)
        .fetch_all(&self.pool)
        .await
        .unwrap_or_default();
        let rules: Vec<RoutingRuleLike> = rows
            .into_iter()
            .map(|r| RoutingRuleLike {
                id: r.try_get("id").unwrap_or_default(),
                trading_group_id: r.try_get("tradingGroupId").ok(),
                symbol_id: r.try_get("symbolId").ok(),
                instrument_class: r.try_get("class").ok(),
                book: r.try_get("book").unwrap_or_else(|_| "B".into()),
                venue_mode: r.try_get("venueMode").unwrap_or_else(|_| "FIXED".into()),
                lp_provider_id: r.try_get("lpProviderId").ok(),
                lp_driver: r.try_get("lpDriver").ok(),
                coverage_ratio: r.try_get::<i32, _>("coverageRatio").unwrap_or(100) as f64,
                priority: r.try_get("priority").unwrap_or(0),
                created_at: r.try_get("createdAt").unwrap_or_else(|_| Utc::now()),
            })
            .collect();
        self.routing_cache.insert(tenant_id.to_string(), (rules.clone(), Instant::now()));
        Ok(rules)
    }

    pub(crate) fn quote_to_account(&self, tenant_id: &str, account_ccy: &str, quote_ccy: &str) -> f64 {
        resolve_fx_factor(account_ccy, quote_ccy, |s| self.prices.mid(tenant_id, s)).unwrap_or(1.0)
    }

    pub(crate) fn quote_to_account_strict(&self, tenant_id: &str, account_ccy: &str, quote_ccy: &str) -> BtResult<f64> {
        resolve_fx_factor(account_ccy, quote_ccy, |s| self.prices.mid(tenant_id, s)).ok_or_else(|| {
            BtError::new(
                FX_RATE_UNAVAILABLE,
                format!("no {quote_ccy}->{account_ccy} conversion pair available; refusing to open a position that cannot be valued"),
            )
        })
    }

    pub(crate) async fn open_views_tx(
        &self,
        tx: &mut Transaction<'_, Postgres>,
        tenant_id: &str,
        account_id: &str,
        account_ccy: &str,
    ) -> BtResult<Vec<OpenPositionView>> {
        let rows = sqlx::query(
            r#"SELECT p.id, p.side::text AS side, p.volume::float8 AS volume, p."openPrice"::float8 AS "openPrice",
                      p."marginUsed"::float8 AS "marginUsed", p.swap::float8 AS swap, p.commission::float8 AS commission,
                      s.symbol, s.digits, s."pipSize"::float8 AS "pipSize", s."contractSize"::float8 AS "contractSize",
                      s."marginRate"::float8 AS "marginRate", s."marginPercent"::float8 AS "marginPercent",
                      s."quoteCurrency", s."baseCurrency"
               FROM positions p JOIN symbols s ON s.id = p."symbolId"
               WHERE p."tenantId"=$1 AND p."accountId"=$2 AND p.status='OPEN' ORDER BY p."openedAt""#,
        )
        .bind(tenant_id)
        .bind(account_id)
        .fetch_all(&mut **tx)
        .await?;
        Ok(self.map_views(tenant_id, account_ccy, &rows))
    }

    pub(crate) async fn open_views(
        &self,
        tenant_id: &str,
        account_id: &str,
        account_ccy: &str,
    ) -> BtResult<Vec<OpenPositionView>> {
        let rows = sqlx::query(
            r#"SELECT p.id, p.side::text AS side, p.volume::float8 AS volume, p."openPrice"::float8 AS "openPrice",
                      p."marginUsed"::float8 AS "marginUsed", p.swap::float8 AS swap, p.commission::float8 AS commission,
                      s.symbol, s.digits, s."pipSize"::float8 AS "pipSize", s."contractSize"::float8 AS "contractSize",
                      s."marginRate"::float8 AS "marginRate", s."marginPercent"::float8 AS "marginPercent",
                      s."quoteCurrency", s."baseCurrency"
               FROM positions p JOIN symbols s ON s.id = p."symbolId"
               WHERE p."tenantId"=$1 AND p."accountId"=$2 AND p.status='OPEN' ORDER BY p."openedAt""#,
        )
        .bind(tenant_id)
        .bind(account_id)
        .fetch_all(&self.pool)
        .await?;
        Ok(self.map_views(tenant_id, account_ccy, &rows))
    }

    fn map_views(&self, tenant_id: &str, account_ccy: &str, rows: &[sqlx::postgres::PgRow]) -> Vec<OpenPositionView> {
        rows.iter()
            .map(|r| {
                let symbol: String = r.try_get("symbol").unwrap_or_default();
                let side: String = r.try_get("side").unwrap_or_default();
                let open_price: f64 = r.try_get("openPrice").unwrap_or(0.0);
                let current = if side.eq_ignore_ascii_case("BUY") {
                    self.prices.sell_price(tenant_id, &symbol)
                } else {
                    self.prices.buy_price(tenant_id, &symbol)
                }
                .unwrap_or(open_price);
                let spec = crate::calc::SymbolCalcSpec {
                    digits: r.try_get("digits").unwrap_or(5),
                    pip_size: r.try_get("pipSize").unwrap_or(0.0001),
                    contract_size: r.try_get("contractSize").unwrap_or(100_000.0),
                    margin_rate: r.try_get("marginRate").unwrap_or(1.0),
                    margin_percent: r.try_get("marginPercent").ok(),
                    quote_currency: r.try_get("quoteCurrency").unwrap_or_else(|_| "USD".into()),
                    base_currency: r.try_get("baseCurrency").unwrap_or_else(|_| "USD".into()),
                };
                OpenPositionView {
                    id: r.try_get("id").unwrap_or_default(),
                    side,
                    volume: r.try_get("volume").unwrap_or(0.0),
                    open_price,
                    current_price: current,
                    margin_used: r.try_get("marginUsed").unwrap_or(0.0),
                    swap: r.try_get("swap").unwrap_or(0.0),
                    commission: r.try_get("commission").unwrap_or(0.0),
                    spec: spec.clone(),
                    quote_to_acct: self.quote_to_account(tenant_id, account_ccy, &spec.quote_currency),
                }
            })
            .collect()
    }

    pub(crate) async fn publish_after_fill(
        &self,
        tenant_id: &str,
        account_id: &str,
        position_id: &str,
        kind: &str,
        snap: &Snapshot,
        profit: Option<f64>,
    ) {
        self.emit(
            tenant_id,
            json!({
                "kind": "POSITION_UPDATE",
                "tenantId": tenant_id,
                "positionId": position_id,
                "accountId": account_id,
                "book": kind,
                "position": {
                    "id": position_id,
                    "accountId": account_id,
                    "status": if kind == "closed" { "CLOSED" } else { "OPEN" },
                    "profit": profit,
                }
            }),
        )
        .await;
        self.emit(tenant_id, json!({"kind":"ACCOUNT_UPDATE","tenantId":tenant_id,"account": snap.json()}))
            .await;
        self.crm_outbox(
            tenant_id,
            "account.snapshot",
            json!({
                "login": snap.login, "balance": snap.balance, "credit": snap.credit,
                "equity": snap.equity, "margin": snap.margin, "freeMargin": snap.free_margin,
                "marginLevel": snap.margin_level, "floatingPL": snap.floating_pl,
                "positionId": position_id, "profit": profit,
                "reason": if kind == "opened" { "position.opened" } else { "position.closed" }
            }),
        )
        .await;
        self.crm_outbox(
            tenant_id,
            if kind == "opened" { "position.opened" } else { "position.closed" },
            json!({"login": snap.login, "positionId": position_id, "profit": profit}),
        )
        .await;
    }

    pub(crate) async fn cover_open(
        &self,
        tenant_id: &str,
        position_id: &str,
        account_id: &str,
        sym: &SymbolRow,
        side: &str,
        volume: f64,
        reference_price: f64,
        routing: &crate::routing::RoutingResolution,
    ) {
        let mut driver = routing.lp_driver.clone().unwrap_or_else(|| "MOCK".into());
        let mut provider_id = routing.lp_provider_id.clone();
        let mut enabled = false;
        if let Some(pid) = &provider_id {
            if let Ok(Some(row)) = sqlx::query(
                r#"SELECT enabled, driver::text AS driver FROM lp_execution_configs WHERE "lpProviderId"=$1"#,
            )
            .bind(pid)
            .fetch_optional(&self.pool)
            .await
            {
                enabled = row.try_get("enabled").unwrap_or(false);
                driver = row.try_get("driver").unwrap_or(driver);
            }
        }
        if !enabled {
            if let Ok(Some(row)) = sqlx::query(
                r#"SELECT enabled, driver::text AS driver, "lpProviderId" FROM lp_execution_configs
                   WHERE "tenantId"=$1 AND enabled=true ORDER BY "isDefault" DESC, "createdAt" ASC LIMIT 1"#,
            )
            .bind(tenant_id)
            .fetch_optional(&self.pool)
            .await
            {
                enabled = row.try_get("enabled").unwrap_or(false);
                driver = row.try_get("driver").unwrap_or(driver);
                provider_id = row.try_get("lpProviderId").ok();
            }
        }
        let hedge_id = Uuid::new_v4().to_string();
        let status = if driver == "MT5" && enabled {
            "PENDING"
        } else if enabled {
            "FILLED"
        } else {
            "REJECTED"
        };
        let _ = sqlx::query(
            r#"INSERT INTO hedge_orders (
                 id, "tenantId", "positionId", "accountId", "symbolId", "symbolName", side, volume, status, kind, driver,
                 "lpProviderId", "requestPrice", "fillPrice", "rejectReason"
               ) VALUES (
                 $1,$2,$3,$4,$5,$6,$7::"OrderSide",$8,$9::"HedgeStatus",'CLIENT_COVER'::"HedgeKind",$10::"LpExecDriver",
                 $11,$12,$13,$14
               )"#,
        )
        .bind(&hedge_id)
        .bind(tenant_id)
        .bind(position_id)
        .bind(account_id)
        .bind(&sym.id)
        .bind(&sym.symbol)
        .bind(side)
        .bind(volume)
        .bind(status)
        .bind(&driver)
        .bind(&provider_id)
        .bind(reference_price)
        .bind(if status == "FILLED" { Some(reference_price) } else { None })
        .bind(if status == "REJECTED" { Some("no enabled LP bridge") } else { None })
        .execute(&self.pool)
        .await;
        if status == "REJECTED" {
            let _ = sqlx::query(
                r#"UPDATE positions SET "coveredVolume" = GREATEST(0, "coveredVolume" - $1) WHERE id=$2 AND status='OPEN'"#,
            )
            .bind(volume)
            .bind(position_id)
            .execute(&self.pool)
            .await;
            self.emit(tenant_id, json!({"kind":"HEDGE_UNCOVERED","tenantId":tenant_id,"positionId":position_id}))
                .await;
        }
    }
}

fn try_f(row: &sqlx::postgres::PgRow, col: &str) -> f64 {
    row.try_get::<f64, _>(col).unwrap_or(0.0)
}
