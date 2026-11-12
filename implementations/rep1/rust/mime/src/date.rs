//! `Date` header parsing and calendar arithmetic.

use crate::scan::skip_comment;

/// A successfully parsed date.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ParsedDate {
    /// Seconds since 1970-01-01T00:00:00Z.
    pub epoch: i64,
    /// Zone offset in minutes east of UTC.
    pub offset_minutes: i64,
}

impl ParsedDate {
    /// The instant rendered as `YYYY-MM-DDTHH:MM:SSZ`.
    pub fn utc(&self) -> String {
        let days = self.epoch.div_euclid(86400);
        let secs = self.epoch.rem_euclid(86400);
        let (y, m, d) = civil_from_days(days);
        format!(
            "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z",
            y,
            m,
            d,
            secs / 3600,
            secs % 3600 / 60,
            secs % 60
        )
    }

    /// The zone offset rendered as `±HHMM` (more digits if needed).
    pub fn offset(&self) -> String {
        let sign = if self.offset_minutes < 0 { '-' } else { '+' };
        let abs = self.offset_minutes.abs();
        format!("{}{:02}{:02}", sign, abs / 60, abs % 60)
    }
}

/// Days from 1970-01-01 to the given proleptic Gregorian date.
pub fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y.rem_euclid(400);
    let mp = (m + 9) % 12;
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146097 + doe - 719468
}

/// Inverse of [`days_from_civil`]: returns `(year, month, day)`.
pub fn civil_from_days(z: i64) -> (i64, i64, i64) {
    let z = z + 719468;
    let era = z.div_euclid(146097);
    let doe = z.rem_euclid(146097);
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    (if m <= 2 { y + 1 } else { y }, m, d)
}

fn is_leap(y: i64) -> bool {
    (y % 4 == 0 && y % 100 != 0) || y % 400 == 0
}

fn days_in_month(y: i64, m: i64) -> i64 {
    match m {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        _ => {
            if is_leap(y) {
                29
            } else {
                28
            }
        }
    }
}

fn remove_comments(value: &str) -> String {
    let chars: Vec<char> = value.chars().collect();
    let mut out = String::new();
    let mut i = 0;
    while i < chars.len() {
        if chars[i] == '(' {
            i = skip_comment(&chars, i);
        } else {
            out.push(chars[i]);
            i += 1;
        }
    }
    out
}

/// Parses `s` as one or two ASCII digits (`min_len..=max_len`).
fn digits(s: &str, min_len: usize, max_len: usize) -> Option<i64> {
    if s.len() < min_len || s.len() > max_len || !s.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    s.parse().ok()
}

fn zone_offset(tok: &str) -> i64 {
    let b = tok.as_bytes();
    if b.len() == 5 && (b[0] == b'+' || b[0] == b'-') && b[1..].iter().all(u8::is_ascii_digit) {
        let hh = digits(&tok[1..3], 2, 2).unwrap_or(0);
        let mm = digits(&tok[3..5], 2, 2).unwrap_or(0);
        let v = hh * 60 + mm;
        return if b[0] == b'-' { -v } else { v };
    }
    match tok.to_ascii_uppercase().as_str() {
        "UT" | "GMT" | "Z" => 0,
        "EST" => -300,
        "EDT" => -240,
        "CST" => -360,
        "CDT" => -300,
        "MST" => -420,
        "MDT" => -360,
        "PST" => -480,
        "PDT" => -420,
        _ => 0,
    }
}

/// Parses a `Date` header value; `None` if it is not a valid date.
pub fn parse_date(value: &str) -> Option<ParsedDate> {
    let cleaned = remove_comments(value);
    let mut tokens: Vec<&str> =
        cleaned.split(|c| c == ' ' || c == '\t' || c == ',').filter(|t| !t.is_empty()).collect();
    if let Some(first) = tokens.first() {
        const DAYS: [&str; 7] = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"];
        if DAYS.iter().any(|d| first.eq_ignore_ascii_case(d)) {
            tokens.remove(0);
        }
    }
    if tokens.len() < 4 {
        return None;
    }

    let day = digits(tokens[0], 1, 2).filter(|d| (1..=31).contains(d))?;

    const MONTHS: [&str; 12] =
        ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"];
    let month = MONTHS.iter().position(|m| tokens[1].eq_ignore_ascii_case(m))? as i64 + 1;

    let ytok = tokens[2];
    let mut year = digits(ytok, 2, 4)?;
    match ytok.len() {
        2 => year += if year >= 50 { 1900 } else { 2000 },
        3 => year += 1900,
        _ => {}
    }
    if !(1..=9999).contains(&year) {
        return None;
    }

    let fields: Vec<&str> = tokens[3].split(':').collect();
    if fields.len() < 2 || fields.len() > 3 {
        return None;
    }
    let hh = digits(fields[0], 1, 2).filter(|&v| v <= 23)?;
    let mm = digits(fields[1], 1, 2).filter(|&v| v <= 59)?;
    let ss = match fields.get(2) {
        Some(f) => digits(f, 1, 2).filter(|&v| v <= 60)?,
        None => 0,
    };

    let offset_minutes = tokens.get(4).map_or(0, |z| zone_offset(z));

    if day > days_in_month(year, month) {
        return None;
    }
    let epoch =
        days_from_civil(year, month, day) * 86400 + hh * 3600 + mm * 60 + ss - offset_minutes * 60;
    Some(ParsedDate { epoch, offset_minutes })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn check(raw: &str, epoch: i64, utc: &str, offset: &str) {
        let d = parse_date(raw).unwrap_or_else(|| panic!("{raw} should parse"));
        assert_eq!((d.epoch, d.utc(), d.offset()), (epoch, utc.to_string(), offset.to_string()), "{raw}");
    }

    #[test]
    fn spec_examples() {
        check("Sun, 29 Feb 2004 22:03:22 -0800", 1078121002, "2004-03-01T06:03:22Z", "-0800");
        check("3 Jan 70 00:00:00 GMT", 172800, "1970-01-03T00:00:00Z", "+0000");
        check("Tue, 1 Jan 2036 00:00:60 +0000", 2082758460, "2036-01-01T00:01:00Z", "+0000");
        check("Mon, 3 Mar 1969 12:00 (GMT) -0500", -26204400, "1969-03-03T17:00:00Z", "-0500");
        check("Sun, 07 Mar 2004 15:21:26 -0000", 1078672886, "2004-03-07T15:21:26Z", "+0000");
        check("1 Jan 2000 00:00:00 +2359", 946598460, "1999-12-31T00:01:00Z", "+2359");
        assert!(parse_date("not a date").is_none());
    }

    #[test]
    fn edge_cases() {
        assert!(parse_date("30 Feb 2004 00:00").is_none());
        assert!(parse_date("29 Feb 1900 00:00").is_none());
        assert!(parse_date("29 Feb 2000 00:00").is_some());
        assert!(parse_date("1 Jan 2000").is_none());
        assert_eq!(parse_date("1 Jan 2000 00:00 +9999").unwrap().offset(), "+10039");
        assert_eq!(parse_date("1 Jan 2000 00:00 EST").unwrap().offset(), "-0500");
        assert_eq!(parse_date("1 Jan 2000 00:00 junk").unwrap().offset(), "+0000");
    }

    #[test]
    fn civil_round_trip() {
        for days in [-800000, -1, 0, 1, 11016, 2_000_000] {
            let (y, m, d) = civil_from_days(days);
            assert_eq!(days_from_civil(y, m, d), days);
        }
        assert_eq!(days_from_civil(1970, 1, 1), 0);
    }
}
