use chrono::{DateTime, Utc};

#[derive(Debug, Clone)]
pub struct RoutingRuleLike {
    pub id: String,
    pub trading_group_id: Option<String>,
    pub symbol_id: Option<String>,
    pub instrument_class: Option<String>,
    pub book: String,
    pub venue_mode: String,
    pub lp_provider_id: Option<String>,
    pub lp_driver: Option<String>,
    pub coverage_ratio: f64,
    pub priority: i32,
    pub created_at: DateTime<Utc>,
}

pub struct RoutingContext<'a> {
    pub account_group_id: Option<&'a str>,
    pub symbol_id: &'a str,
    pub symbol_class: &'a str,
    pub account_book: Option<&'a str>,
    pub symbol_force_book: Option<&'a str>,
    pub symbol_group_default_book: Option<&'a str>,
}

pub struct RoutingResolution {
    pub book: String,
    pub venue_mode: String,
    pub lp_provider_id: Option<String>,
    pub lp_driver: Option<String>,
    pub coverage_ratio: f64,
}

fn matches(rule: &RoutingRuleLike, ctx: &RoutingContext<'_>) -> bool {
    if let Some(g) = &rule.trading_group_id {
        if ctx.account_group_id != Some(g.as_str()) {
            return false;
        }
    }
    if let Some(s) = &rule.symbol_id {
        if s != ctx.symbol_id {
            return false;
        }
    }
    if let Some(c) = &rule.instrument_class {
        if c != ctx.symbol_class {
            return false;
        }
    }
    true
}

fn specificity(rule: &RoutingRuleLike) -> i32 {
    (if rule.symbol_id.is_some() { 4 } else { 0 })
        + (if rule.trading_group_id.is_some() { 2 } else { 0 })
        + (if rule.instrument_class.is_some() { 1 } else { 0 })
}

pub fn resolve_routing(rules: &[RoutingRuleLike], ctx: RoutingContext<'_>) -> RoutingResolution {
    let mut best: Option<&RoutingRuleLike> = None;
    let mut best_score = -1;
    for r in rules {
        if !matches(r, &ctx) {
            continue;
        }
        let score = specificity(r);
        match best {
            None => {
                best = Some(r);
                best_score = score;
            }
            Some(_b) if score > best_score => {
                best = Some(r);
                best_score = score;
            }
            Some(b) if score == best_score => {
                if r.priority > b.priority || (r.priority == b.priority && r.created_at < b.created_at) {
                    best = Some(r);
                }
            }
            _ => {}
        }
    }

    let book = if let Some(fb) = ctx.symbol_force_book {
        fb.to_string()
    } else if let Some(m) = best {
        m.book.clone()
    } else if let Some(ab) = ctx.account_book {
        ab.to_string()
    } else if let Some(gb) = ctx.symbol_group_default_book {
        gb.to_string()
    } else {
        "B".into()
    };

    let matched = best;
    RoutingResolution {
        book,
        venue_mode: matched_or(matched, "FIXED"),
        lp_provider_id: matched.and_then(|m| m.lp_provider_id.clone()),
        lp_driver: matched.and_then(|m| m.lp_driver.clone()),
        coverage_ratio: matched.map(|m| m.coverage_ratio).unwrap_or(100.0),
    }
}

fn matched_or(matched: Option<&RoutingRuleLike>, fallback: &str) -> String {
    matched
        .map(|m| {
            if m.venue_mode.is_empty() {
                fallback.to_string()
            } else {
                m.venue_mode.clone()
            }
        })
        .unwrap_or_else(|| fallback.to_string())
}
