//! Floating (zone-less) dates and date-times.

use std::fmt;

use crate::calendar;
use crate::error::ParseError;

/// A calendar date in the proleptic Gregorian calendar.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct Date {
    year: i32,
    month: u32,
    day: u32,
}

impl Date {
    /// Creates a date, returning `None` if it does not exist (or `year < 1`).
    pub fn new(year: i32, month: u32, day: u32) -> Option<Date> {
        calendar::is_valid_date(year, month, day).then_some(Date { year, month, day })
    }

    /// Year (>= 1).
    pub fn year(&self) -> i32 {
        self.year
    }

    /// Month, 1–12.
    pub fn month(&self) -> u32 {
        self.month
    }

    /// Day of month, 1–31.
    pub fn day(&self) -> u32 {
        self.day
    }

    /// Day number: days since 0001-01-01.
    pub fn to_days(&self) -> i64 {
        calendar::days_from_civil(self.year, self.month, self.day)
    }

    /// Inverse of [`Date::to_days`]; `days` must be non-negative.
    pub fn from_days(days: i64) -> Date {
        let (year, month, day) = calendar::civil_from_days(days);
        Date { year, month, day }
    }

    /// Weekday, 0 = Monday … 6 = Sunday.
    pub fn weekday(&self) -> u32 {
        calendar::weekday_of_days(self.to_days())
    }
}

/// A date together with a time of day (no time zone).
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct DateTime {
    /// The date part.
    pub date: Date,
    /// Hour, 0–23.
    pub hour: u32,
    /// Minute, 0–59.
    pub minute: u32,
    /// Second, 0–59.
    pub second: u32,
}

impl DateTime {
    /// Creates a date-time, returning `None` if any component is out of range.
    pub fn new(year: i32, month: u32, day: u32, hour: u32, minute: u32, second: u32) -> Option<DateTime> {
        if hour > 23 || minute > 59 || second > 59 {
            return None;
        }
        Some(DateTime { date: Date::new(year, month, day)?, hour, minute, second })
    }

    /// Seconds since midnight.
    pub fn seconds_of_day(&self) -> u32 {
        self.hour * 3600 + self.minute * 60 + self.second
    }

    /// Parses the `YYYYMMDDTHHMMSS` form.
    pub fn parse(s: &str) -> Result<DateTime, ParseError> {
        let bad = || ParseError::new(format!("invalid date-time {s:?}"));
        let b = s.as_bytes();
        if b.len() != 15 || b[8] != b'T' {
            return Err(bad());
        }
        let num = |range: std::ops::Range<usize>| -> Result<u32, ParseError> {
            let mut v = 0;
            for &c in &b[range] {
                if !c.is_ascii_digit() {
                    return Err(bad());
                }
                v = v * 10 + u32::from(c - b'0');
            }
            Ok(v)
        };
        DateTime::new(num(0..4)? as i32, num(4..6)?, num(6..8)?, num(9..11)?, num(11..13)?, num(13..15)?)
            .ok_or_else(bad)
    }

    /// Appends the `YYYYMMDDTHHMMSS` form to `out`.
    pub fn write_to(&self, out: &mut String) {
        fn push(out: &mut String, v: u32, width: usize) {
            let mut digits = [b'0'; 4];
            let mut v = v;
            for i in (0..width).rev() {
                digits[i] = b'0' + (v % 10) as u8;
                v /= 10;
            }
            out.push_str(std::str::from_utf8(&digits[..width]).unwrap());
        }
        push(out, self.date.year as u32, 4);
        push(out, self.date.month, 2);
        push(out, self.date.day, 2);
        out.push('T');
        push(out, self.hour, 2);
        push(out, self.minute, 2);
        push(out, self.second, 2);
    }
}

impl fmt::Display for DateTime {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let mut s = String::with_capacity(15);
        self.write_to(&mut s);
        f.write_str(&s)
    }
}

impl std::str::FromStr for DateTime {
    type Err = ParseError;
    fn from_str(s: &str) -> Result<DateTime, ParseError> {
        DateTime::parse(s)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_and_display() {
        let dt = DateTime::parse("19970902T090000").unwrap();
        assert_eq!(dt.date.year(), 1997);
        assert_eq!(dt.to_string(), "19970902T090000");
        assert_eq!(dt.seconds_of_day(), 9 * 3600);
    }

    #[test]
    fn rejects_bad_input() {
        for s in ["", "19970902", "19970230T000000", "19970902T240000", "19970902 090000", "1997090aT090000", "19970902T096000"] {
            assert!(DateTime::parse(s).is_err(), "{s}");
        }
    }

    #[test]
    fn ordering_is_chronological() {
        let a = DateTime::parse("20240101T235959").unwrap();
        let b = DateTime::parse("20240102T000000").unwrap();
        assert!(a < b);
    }

    #[test]
    fn day_number_round_trip() {
        let d = Date::new(2024, 2, 29).unwrap();
        assert_eq!(Date::from_days(d.to_days()), d);
        assert_eq!(d.weekday(), 3); // Thursday
    }
}
