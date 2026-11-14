use chrono::{DateTime, Datelike, Timelike, Utc};
use serde::Deserialize;

#[derive(Debug, Clone, Deserialize)]
pub struct SessionWindow {
    pub day: u32,
    pub open: String,
    pub close: String,
}

fn minutes(hhmm: &str) -> i32 {
    let mut parts = hhmm.split(':');
    let h: i32 = parts.next().and_then(|s| s.parse().ok()).unwrap_or(0);
    let m: i32 = parts.next().and_then(|s| s.parse().ok()).unwrap_or(0);
    h * 60 + m
}

pub fn is_market_open(sessions: &[SessionWindow], now: DateTime<Utc>) -> bool {
    if sessions.is_empty() {
        return true;
    }
    let day = now.weekday().num_days_from_sunday();
    let mins = now.hour() as i32 * 60 + now.minute() as i32;
    for s in sessions {
        if s.day != day {
            continue;
        }
        let open = minutes(&s.open);
        let close = minutes(&s.close);
        if open <= close {
            if mins >= open && mins < close {
                return true;
            }
        } else if mins >= open || mins < close {
            return true;
        }
    }
    false
}

/// UTC offset of New York (hours): -4 in US daylight time (2nd Sunday of March 07:00 UTC to 1st Sunday of
/// November 06:00 UTC), else -5. The forex week opens and closes at 17:00 New York time, so in UTC it moves with
/// US daylight saving: 21:00 UTC in summer, 22:00 UTC in winter.
pub fn new_york_offset_hours(now: DateTime<Utc>) -> i64 {
    use chrono::NaiveDate;
    let y = now.year();
    let first_sunday = |month: u32| -> u32 {
        let wd = NaiveDate::from_ymd_opt(y, month, 1).unwrap().weekday().num_days_from_sunday();
        1 + (7 - wd) % 7
    };
    let start = NaiveDate::from_ymd_opt(y, 3, first_sunday(3) + 7).unwrap().and_hms_opt(7, 0, 0).unwrap().and_utc();
    let end = NaiveDate::from_ymd_opt(y, 11, first_sunday(11)).unwrap().and_hms_opt(6, 0, 0).unwrap().and_utc();
    if now >= start && now < end {
        -4
    } else {
        -5
    }
}

/// The forex week roll, 17:00 New York time (Friday close / Sunday open).
const FX_ROLL_NY_HOUR: u32 = 17;

pub fn is_forex_week_open(now: DateTime<Utc>) -> bool {
    let ny = now + chrono::Duration::hours(new_york_offset_hours(now));
    let day = ny.weekday().num_days_from_sunday();
    let mins = ny.hour() as i32 * 60 + ny.minute() as i32;
    let roll = FX_ROLL_NY_HOUR as i32 * 60;
    if day == 6 {
        return false;
    }
    if day == 0 && mins < roll {
        return false;
    }
    if day == 5 && mins >= roll {
        return false;
    }
    true
}

pub fn is_symbol_tradable(sessions: &[SessionWindow], instrument_class: &str, now: DateTime<Utc>) -> bool {
    if !sessions.is_empty() {
        return is_market_open(sessions, now);
    }
    if instrument_class.eq_ignore_ascii_case("CRYPTO") {
        return true;
    }
    is_forex_week_open(now)
}

pub fn session_closes_at(sessions: &[SessionWindow], instrument_class: &str, now: DateTime<Utc>) -> DateTime<Utc> {
    if !sessions.is_empty() {
        let day = now.weekday().num_days_from_sunday();
        let mins = now.hour() as i32 * 60 + now.minute() as i32;
        let mut best: Option<DateTime<Utc>> = None;
        for s in sessions {
            let close_m = minutes(&s.close);
            let open_m = minutes(&s.open);
            let mut close_day = s.day;
            if open_m > close_m {
                close_day = (s.day + 1) % 7;
            }
            let add_days = (close_day as i32 - day as i32 + 7) % 7;
            if add_days == 0 && mins >= close_m {
                continue;
            }
            let d = now + chrono::Duration::days(add_days as i64);
            let d = d
                .date_naive()
                .and_hms_opt((close_m / 60) as u32, (close_m % 60) as u32, 0)
                .unwrap()
                .and_utc();
            if best.map(|b| d < b).unwrap_or(true) {
                best = Some(d);
            }
        }
        if let Some(b) = best {
            return b;
        }
    }
    if instrument_class.eq_ignore_ascii_case("CRYPTO") {
        let d = now.date_naive() + chrono::Duration::days(1);
        return d.and_hms_opt(0, 0, 0).unwrap().and_utc();
    }
    // Next Friday 17:00 New York time, in UTC.
    let ny = now + chrono::Duration::hours(new_york_offset_hours(now));
    let day = ny.weekday().num_days_from_sunday();
    let mins = ny.hour() as i32 * 60 + ny.minute() as i32;
    let mut add = (5 - day as i32 + 7) % 7;
    if day == 5 && mins >= FX_ROLL_NY_HOUR as i32 * 60 {
        add = 7;
    }
    if day == 6 {
        add = 6;
    }
    let local = (ny + chrono::Duration::days(add as i64))
        .date_naive()
        .and_hms_opt(FX_ROLL_NY_HOUR, 0, 0)
        .unwrap()
        .and_utc();
    // `local` is New York wall time written as UTC: shift it back by the offset in force at that moment.
    let guess = local - chrono::Duration::hours(new_york_offset_hours(now));
    local - chrono::Duration::hours(new_york_offset_hours(guess))
}

pub fn parse_sessions(raw: Option<&serde_json::Value>) -> Vec<SessionWindow> {
    match raw {
        Some(v) => serde_json::from_value(v.clone()).unwrap_or_default(),
        None => Vec::new(),
    }
}
