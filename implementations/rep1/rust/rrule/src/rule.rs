//! The recurrence rule data model and its parser.

use std::str::FromStr;

use crate::datetime::DateTime;
use crate::error::ParseError;

/// Recurrence frequency.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Freq {
    /// One period per calendar year.
    Yearly,
    /// One period per calendar month.
    Monthly,
    /// One period per week (starting on the rule's `WKST`).
    Weekly,
    /// One period per day.
    Daily,
}

/// Day of the week; `Mo` is 0 and `Su` is 6.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Weekday {
    /// Monday
    Mo,
    /// Tuesday
    Tu,
    /// Wednesday
    We,
    /// Thursday
    Th,
    /// Friday
    Fr,
    /// Saturday
    Sa,
    /// Sunday
    Su,
}

impl Weekday {
    const ALL: [Weekday; 7] = [Weekday::Mo, Weekday::Tu, Weekday::We, Weekday::Th, Weekday::Fr, Weekday::Sa, Weekday::Su];
    const CODES: [&'static str; 7] = ["MO", "TU", "WE", "TH", "FR", "SA", "SU"];

    /// Index 0 (Monday) … 6 (Sunday).
    pub fn index(self) -> u32 {
        self as u32
    }

    /// Weekday for an index 0–6.
    pub fn from_index(i: u32) -> Option<Weekday> {
        Weekday::ALL.get(i as usize).copied()
    }

    /// Parses a two-letter code such as `"MO"`.
    pub fn from_code(code: &str) -> Option<Weekday> {
        Weekday::CODES.iter().position(|&c| c == code).map(|i| Weekday::ALL[i])
    }
}

/// An entry of a `BYDAY` list: a weekday with an optional ordinal (`2MO`, `-1FR`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct ByDay {
    /// Signed ordinal counted within the month or year, if present.
    pub ordinal: Option<i32>,
    /// The weekday.
    pub weekday: Weekday,
}

/// A parsed recurrence rule. Defaults derived from DTSTART are *not* applied
/// here; they are applied when a [`Recurrence`](crate::Recurrence) is built.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Rule {
    /// `FREQ`
    pub freq: Freq,
    /// `INTERVAL` (default 1)
    pub interval: u32,
    /// `COUNT`
    pub count: Option<u32>,
    /// `UNTIL` (inclusive)
    pub until: Option<DateTime>,
    /// `WKST` (default Monday)
    pub wkst: Weekday,
    /// `BYMONTH`, values 1–12
    pub by_month: Vec<u32>,
    /// `BYMONTHDAY`, values ±1–31
    pub by_month_day: Vec<i32>,
    /// `BYYEARDAY`, values ±1–366
    pub by_year_day: Vec<i32>,
    /// `BYWEEKNO`, values ±1–53
    pub by_week_no: Vec<i32>,
    /// `BYDAY`
    pub by_day: Vec<ByDay>,
    /// `BYSETPOS`, values ±1–366
    pub by_set_pos: Vec<i32>,
}

impl Rule {
    /// A rule with the given frequency and every other part at its default.
    pub fn new(freq: Freq) -> Rule {
        Rule {
            freq,
            interval: 1,
            count: None,
            until: None,
            wkst: Weekday::Mo,
            by_month: Vec::new(),
            by_month_day: Vec::new(),
            by_year_day: Vec::new(),
            by_week_no: Vec::new(),
            by_day: Vec::new(),
            by_set_pos: Vec::new(),
        }
    }

    /// Parses an RFC 5545 `RRULE` value such as `FREQ=MONTHLY;BYDAY=-1FR`.
    pub fn parse(s: &str) -> Result<Rule, ParseError> {
        let mut freq = None;
        let mut rule = Rule::new(Freq::Daily);
        let mut seen: Vec<&str> = Vec::new();
        for part in s.split(';') {
            let (name, value) = part
                .split_once('=')
                .ok_or_else(|| ParseError::new(format!("rule part {part:?} is not NAME=VALUE")))?;
            if seen.contains(&name) {
                return Err(ParseError::new(format!("duplicate rule part {name}")));
            }
            seen.push(name);
            match name {
                "FREQ" => {
                    freq = Some(match value {
                        "YEARLY" => Freq::Yearly,
                        "MONTHLY" => Freq::Monthly,
                        "WEEKLY" => Freq::Weekly,
                        "DAILY" => Freq::Daily,
                        _ => return Err(ParseError::new(format!("unsupported FREQ {value:?}"))),
                    })
                }
                "INTERVAL" => rule.interval = parse_int(name, value, 1, 100)? as u32,
                "COUNT" => rule.count = Some(parse_int(name, value, 1, 100_000)? as u32),
                "UNTIL" => rule.until = Some(DateTime::parse(value)?),
                "WKST" => {
                    rule.wkst = Weekday::from_code(value)
                        .ok_or_else(|| ParseError::new(format!("invalid WKST {value:?}")))?
                }
                "BYMONTH" => {
                    rule.by_month =
                        parse_list(name, value, |v| Ok(parse_int(name, v, 1, 12)? as u32))?
                }
                "BYMONTHDAY" => rule.by_month_day = parse_signed_list(name, value, 31)?,
                "BYYEARDAY" => rule.by_year_day = parse_signed_list(name, value, 366)?,
                "BYWEEKNO" => rule.by_week_no = parse_signed_list(name, value, 53)?,
                "BYSETPOS" => rule.by_set_pos = parse_signed_list(name, value, 366)?,
                "BYDAY" => rule.by_day = parse_list(name, value, parse_by_day)?,
                _ => return Err(ParseError::new(format!("unknown rule part {name}"))),
            }
        }
        rule.freq = freq.ok_or_else(|| ParseError::new("missing FREQ"))?;
        rule.validate()?;
        Ok(rule)
    }

    fn validate(&self) -> Result<(), ParseError> {
        if self.count.is_some() && self.until.is_some() {
            return Err(ParseError::new("COUNT and UNTIL are mutually exclusive"));
        }
        if self.freq != Freq::Yearly && !(self.by_year_day.is_empty() && self.by_week_no.is_empty()) {
            return Err(ParseError::new("BYYEARDAY and BYWEEKNO require FREQ=YEARLY"));
        }
        let ordinals = self.by_day.iter().filter(|d| d.ordinal.is_some()).count();
        if ordinals > 0 {
            if ordinals != self.by_day.len() {
                return Err(ParseError::new("BYDAY mixes plain and ordinal codes"));
            }
            if !matches!(self.freq, Freq::Monthly | Freq::Yearly) {
                return Err(ParseError::new("ordinal BYDAY requires FREQ=MONTHLY or FREQ=YEARLY"));
            }
            if !self.by_week_no.is_empty() {
                return Err(ParseError::new("ordinal BYDAY cannot be combined with BYWEEKNO"));
            }
        }
        Ok(())
    }
}

impl FromStr for Rule {
    type Err = ParseError;
    fn from_str(s: &str) -> Result<Rule, ParseError> {
        Rule::parse(s)
    }
}

fn parse_int(name: &str, s: &str, min: i64, max: i64) -> Result<i64, ParseError> {
    let bad = || ParseError::new(format!("invalid value {s:?} for {name}"));
    let digits = s.strip_prefix('-').unwrap_or(s);
    if digits.is_empty() || digits.len() > 9 || !digits.bytes().all(|c| c.is_ascii_digit()) {
        return Err(bad());
    }
    let v: i64 = s.parse().map_err(|_| bad())?;
    if v < min || v > max {
        return Err(ParseError::new(format!("value {v} out of range for {name}")));
    }
    Ok(v)
}

fn parse_list<T>(
    _name: &str,
    value: &str,
    mut f: impl FnMut(&str) -> Result<T, ParseError>,
) -> Result<Vec<T>, ParseError> {
    value.split(',').map(&mut f).collect()
}

fn parse_signed_list(name: &str, value: &str, max: i64) -> Result<Vec<i32>, ParseError> {
    parse_list(name, value, |v| {
        let n = parse_int(name, v, -max, max)?;
        if n == 0 {
            return Err(ParseError::new(format!("zero is not allowed in {name}")));
        }
        Ok(n as i32)
    })
}

fn parse_by_day(s: &str) -> Result<ByDay, ParseError> {
    if s.len() < 2 || !s.is_char_boundary(s.len() - 2) {
        return Err(ParseError::new(format!("invalid BYDAY value {s:?}")));
    }
    let (num, code) = s.split_at(s.len() - 2);
    let weekday =
        Weekday::from_code(code).ok_or_else(|| ParseError::new(format!("invalid BYDAY value {s:?}")))?;
    let ordinal = if num.is_empty() {
        None
    } else {
        let n = parse_int("BYDAY", num, -53, 53)?;
        if n == 0 {
            return Err(ParseError::new("zero ordinal in BYDAY"));
        }
        Some(n as i32)
    };
    Ok(ByDay { ordinal, weekday })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_full_rule() {
        let r = Rule::parse("FREQ=MONTHLY;INTERVAL=2;WKST=SU;BYDAY=-1FR,2MO;BYMONTH=1,2;BYSETPOS=-1;UNTIL=20200101T000000")
            .unwrap();
        assert_eq!(r.freq, Freq::Monthly);
        assert_eq!(r.interval, 2);
        assert_eq!(r.wkst, Weekday::Su);
        assert_eq!(r.by_day.len(), 2);
        assert_eq!(r.by_day[0], ByDay { ordinal: Some(-1), weekday: Weekday::Fr });
        assert_eq!(r.by_day[1], ByDay { ordinal: Some(2), weekday: Weekday::Mo });
        assert_eq!(r.by_month, vec![1, 2]);
        assert_eq!(r.by_set_pos, vec![-1]);
        assert!(r.until.is_some());
    }

    #[test]
    fn rejects_invalid() {
        for s in [
            "",
            "INTERVAL=2",
            "FREQ=HOURLY",
            "FREQ=DAILY;FREQ=DAILY",
            "FREQ=DAILY;COUNT=1;UNTIL=20200101T000000",
            "FREQ=DAILY;BYMONTH=13",
            "FREQ=DAILY;BYMONTHDAY=0",
            "FREQ=DAILY;BYDAY=XX",
            "FREQ=DAILY;BYDAY=1MO",
            "FREQ=MONTHLY;BYYEARDAY=1",
            "FREQ=MONTHLY;BYDAY=1MO,TU",
            "FREQ=YEARLY;BYWEEKNO=1;BYDAY=1MO",
            "FREQ=DAILY;FOO=1",
            "FREQ=DAILY;INTERVAL=0",
            "FREQ",
        ] {
            assert!(Rule::parse(s).is_err(), "{s:?} should be rejected");
        }
    }

    #[test]
    fn weekday_codes() {
        for i in 0..7 {
            let w = Weekday::from_index(i).unwrap();
            assert_eq!(w.index(), i);
        }
        assert_eq!(Weekday::from_code("SU"), Some(Weekday::Su));
        assert_eq!(Weekday::from_code("su"), None);
    }
}
