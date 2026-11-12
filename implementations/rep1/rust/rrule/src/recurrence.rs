//! The recurrence engine: period-by-period expansion of a rule (SPEC §2–§7).

use crate::calendar;
use crate::datetime::{Date, DateTime};
use crate::rule::{Freq, Rule};
use crate::weeknum::YearWeeks;

/// Last year for which periods are enumerated.
const MAX_YEAR: i32 = 9999;

/// A lazily evaluated sequence of occurrences of a [`Rule`] from a start
/// date-time. Implements [`Iterator`]; it yields strictly increasing
/// date-times and honours the rule's `COUNT` and `UNTIL`.
///
/// Every period (year, month, week or day) is enumerated and every candidate
/// day in it is tested against the filters, each in constant time.
#[derive(Debug, Clone)]
pub struct Recurrence {
    start: DateTime,
    start_day: i64,
    /// Time of day shared by all occurrences, seconds since midnight.
    tod: u32,
    freq: Freq,
    interval: i64,
    wkst: u32,
    remaining: Option<u64>,
    until: Option<(i64, u32)>,
    filters: Filters,
    set_pos: Vec<i32>,
    /// Day number of the last day of year 9999.
    max_day: i64,
    /// Index of the next period to expand.
    period: i64,
    /// Occurrence days of the current period and the read position.
    buf: Vec<i64>,
    pos: usize,
    scratch: Vec<i64>,
    marks: Vec<bool>,
    done: bool,
}

/// Filters after the DTSTART defaults have been applied.
#[derive(Debug, Clone)]
struct Filters {
    month_mask: u32,
    month_day: Option<(u32, u32)>, // (bit d for d, bit k for -k)
    year_day: Option<(Vec<bool>, Vec<bool>)>,
    week_no: Option<(u64, u64)>,
    plain_days: u32, // weekday mask, 0 = no plain filter
    ordinals: Vec<(i32, u32)>,
}

/// Position within the calendar of one day.
#[derive(Clone, Copy)]
struct Cursor {
    num: i64,
    year: i32,
    month: u32,
    day: u32,
    year_index: u32,
    weekday: u32,
    month_len: u32,
    year_len: u32,
}

impl Cursor {
    fn at(num: i64) -> Cursor {
        let (year, month, day) = calendar::civil_from_days(num);
        let year_index = (num - calendar::days_from_civil(year, 1, 1)) as u32;
        Cursor {
            num,
            year,
            month,
            day,
            year_index,
            weekday: calendar::weekday_of_days(num),
            month_len: calendar::days_in_month(year, month),
            year_len: calendar::days_in_year(year),
        }
    }

    fn advance(&mut self) {
        self.num += 1;
        self.weekday = (self.weekday + 1) % 7;
        self.year_index += 1;
        if self.day < self.month_len {
            self.day += 1;
            return;
        }
        self.day = 1;
        if self.month < 12 {
            self.month += 1;
        } else {
            self.month = 1;
            self.year += 1;
            self.year_index = 0;
            self.year_len = calendar::days_in_year(self.year);
        }
        self.month_len = calendar::days_in_month(self.year, self.month);
    }
}

/// What the current period contributes to the filters.
struct PeriodCtx<'a> {
    first_day: i64,
    weeks: Option<YearWeeks>,
    marks: &'a [bool],
}

impl Filters {
    fn new(rule: &Rule, start: Date) -> Filters {
        let mut by_month = rule.by_month.clone();
        let mut by_month_day = rule.by_month_day.clone();
        let mut by_day = rule.by_day.clone();
        if by_month_day.is_empty() && rule.by_year_day.is_empty() && rule.by_week_no.is_empty() && by_day.is_empty() {
            match rule.freq {
                Freq::Yearly => {
                    if by_month.is_empty() {
                        by_month.push(start.month());
                    }
                    by_month_day.push(start.day() as i32);
                }
                Freq::Monthly => by_month_day.push(start.day() as i32),
                Freq::Weekly => by_day.push(crate::rule::ByDay {
                    ordinal: None,
                    weekday: crate::rule::Weekday::from_index(start.weekday()).unwrap(),
                }),
                Freq::Daily => {}
            }
        }
        let month_mask = by_month.iter().fold(0u32, |m, &v| m | 1 << v);
        let month_day = (!by_month_day.is_empty()).then(|| {
            by_month_day.iter().fold((0u32, 0u32), |(p, n), &v| {
                if v > 0 {
                    (p | 1 << v, n)
                } else {
                    (p, n | 1 << -v)
                }
            })
        });
        let year_day = (!rule.by_year_day.is_empty()).then(|| {
            let mut pos = vec![false; 367];
            let mut neg = vec![false; 367];
            for &v in &rule.by_year_day {
                if v > 0 {
                    pos[v as usize] = true;
                } else {
                    neg[(-v) as usize] = true;
                }
            }
            (pos, neg)
        });
        let week_no = (!rule.by_week_no.is_empty()).then(|| {
            rule.by_week_no.iter().fold((0u64, 0u64), |(p, n), &v| {
                if v > 0 {
                    (p | 1 << v, n)
                } else {
                    (p, n | 1 << -v)
                }
            })
        });
        let mut plain_days = 0;
        let mut ordinals = Vec::new();
        for d in &by_day {
            match d.ordinal {
                None => plain_days |= 1 << d.weekday.index(),
                Some(n) => ordinals.push((n, d.weekday.index())),
            }
        }
        Filters { month_mask, month_day, year_day, week_no, plain_days, ordinals }
    }

    /// O(1) test of one candidate day.
    fn matches(&self, c: &Cursor, ctx: &PeriodCtx<'_>) -> bool {
        if self.month_mask != 0 && self.month_mask >> c.month & 1 == 0 {
            return false;
        }
        if let (Some((pos, neg)), Some(weeks)) = (self.week_no, &ctx.weeks) {
            if !weeks.matches(c.year_index, pos, neg) {
                return false;
            }
        }
        if self.plain_days != 0 && self.plain_days >> c.weekday & 1 == 0 {
            return false;
        }
        if !self.ordinals.is_empty() && !ctx.marks[(c.num - ctx.first_day) as usize] {
            return false;
        }
        if let Some((pos, neg)) = self.month_day {
            if pos >> c.day & 1 == 0 && neg >> (c.month_len - c.day + 1) & 1 == 0 {
                return false;
            }
        }
        if let Some((pos, neg)) = &self.year_day {
            let yd = c.year_index + 1;
            if !pos[yd as usize] && !neg[(c.year_len - yd + 1) as usize] {
                return false;
            }
        }
        true
    }
}

/// Marks in `marks` (indexed from `first_day`) the days designated by the
/// ordinal codes within the range `[range_start, range_start + len)`.
fn mark_ordinals(marks: &mut [bool], first_day: i64, range_start: i64, len: i64, ordinals: &[(i32, u32)]) {
    let base = range_start - first_day;
    let start_wd = i64::from(calendar::weekday_of_days(range_start));
    let end_wd = (start_wd + len - 1) % 7;
    for &(n, wd) in ordinals {
        let wd = i64::from(wd);
        let n = i64::from(n);
        let idx = if n > 0 {
            (wd - start_wd).rem_euclid(7) + 7 * (n - 1)
        } else {
            len - 1 - (end_wd - wd).rem_euclid(7) + 7 * (n + 1)
        };
        if (0..len).contains(&idx) {
            marks[(base + idx) as usize] = true;
        }
    }
}

impl Recurrence {
    /// Creates the expansion of `rule` starting at `start`.
    pub fn new(start: DateTime, rule: &Rule) -> Recurrence {
        Recurrence {
            start,
            start_day: start.date.to_days(),
            tod: start.seconds_of_day(),
            freq: rule.freq,
            interval: i64::from(rule.interval),
            wkst: rule.wkst.index(),
            remaining: rule.count.map(u64::from),
            until: rule.until.map(|u| (u.date.to_days(), u.seconds_of_day())),
            filters: Filters::new(rule, start.date),
            set_pos: rule.by_set_pos.clone(),
            max_day: calendar::days_from_civil(MAX_YEAR, 12, 31),
            period: 0,
            buf: Vec::new(),
            pos: 0,
            scratch: Vec::new(),
            marks: Vec::new(),
            done: false,
        }
    }

    fn after_until(&self, day: i64) -> bool {
        matches!(self.until, Some((ud, ut)) if day > ud || (day == ud && self.tod > ut))
    }

    /// Expands the next period into `self.buf`. Returns `false` when the
    /// enumeration is finished.
    fn fill_period(&mut self) -> bool {
        let k = self.period;
        self.period += 1;
        let y0 = i64::from(self.start.date.year());
        // (first day, length) of the period; `None` when past year 9999.
        let (first, len) = match self.freq {
            Freq::Yearly => {
                let year = y0 + k * self.interval;
                if year > i64::from(MAX_YEAR) {
                    return false;
                }
                (calendar::days_from_civil(year as i32, 1, 1), i64::from(calendar::days_in_year(year as i32)))
            }
            Freq::Monthly => {
                let total = y0 * 12 + i64::from(self.start.date.month()) - 1 + k * self.interval;
                let year = (total / 12) as i32;
                if year > MAX_YEAR {
                    return false;
                }
                let month = (total % 12) as u32 + 1;
                (calendar::days_from_civil(year, month, 1), i64::from(calendar::days_in_month(year, month)))
            }
            Freq::Weekly => {
                let wd = i64::from(self.start.date.weekday());
                let week_a = self.start_day - (wd - i64::from(self.wkst)).rem_euclid(7);
                if k == 0 {
                    (self.start_day, week_a + 7 - self.start_day)
                } else {
                    (week_a + 7 * k * self.interval, 7)
                }
            }
            Freq::Daily => (self.start_day + k * self.interval, 1),
        };
        if first > self.max_day && matches!(self.freq, Freq::Weekly | Freq::Daily) {
            return false;
        }
        if self.after_until(first) {
            return false;
        }

        let mut ctx = PeriodCtx { first_day: first, weeks: None, marks: &[] };
        let mut cursor = Cursor::at(first);
        match self.freq {
            Freq::Yearly => {
                if self.filters.week_no.is_some() {
                    ctx.weeks = Some(YearWeeks::new(cursor.year, self.wkst));
                }
                if !self.filters.ordinals.is_empty() {
                    self.marks.clear();
                    self.marks.resize(len as usize, false);
                    if self.filters.month_mask == 0 {
                        mark_ordinals(&mut self.marks, first, first, len, &self.filters.ordinals);
                    } else {
                        for m in 1..=12u32 {
                            if self.filters.month_mask >> m & 1 != 0 {
                                let ms = calendar::days_from_civil(cursor.year, m, 1);
                                let ml = i64::from(calendar::days_in_month(cursor.year, m));
                                mark_ordinals(&mut self.marks, first, ms, ml, &self.filters.ordinals);
                            }
                        }
                    }
                }
            }
            Freq::Monthly => {
                if !self.filters.ordinals.is_empty() {
                    self.marks.clear();
                    self.marks.resize(len as usize, false);
                    mark_ordinals(&mut self.marks, first, first, len, &self.filters.ordinals);
                }
            }
            _ => {}
        }
        ctx.marks = &self.marks;

        let kept = if self.set_pos.is_empty() { &mut self.buf } else { &mut self.scratch };
        kept.clear();
        for _ in 0..len {
            if self.filters.matches(&cursor, &ctx) {
                kept.push(cursor.num);
            }
            cursor.advance();
        }

        if !self.set_pos.is_empty() {
            let n = self.scratch.len() as i64;
            self.buf.clear();
            let mut picked: Vec<i64> = Vec::new();
            for &p in &self.set_pos {
                let idx = if p > 0 { i64::from(p) - 1 } else { n + i64::from(p) };
                if (0..n).contains(&idx) {
                    picked.push(idx);
                }
            }
            picked.sort_unstable();
            picked.dedup();
            self.buf.extend(picked.iter().map(|&i| self.scratch[i as usize]));
        }
        self.pos = 0;
        true
    }
}

impl Iterator for Recurrence {
    type Item = DateTime;

    fn next(&mut self) -> Option<DateTime> {
        if self.done || self.remaining == Some(0) {
            return None;
        }
        loop {
            if self.pos >= self.buf.len() {
                if !self.fill_period() {
                    self.done = true;
                    return None;
                }
                continue;
            }
            let day = self.buf[self.pos];
            self.pos += 1;
            if self.after_until(day) {
                self.done = true;
                return None;
            }
            if day < self.start_day {
                continue;
            }
            if let Some(r) = &mut self.remaining {
                *r -= 1;
            }
            return Some(DateTime {
                date: Date::from_days(day),
                hour: self.start.hour,
                minute: self.start.minute,
                second: self.start.second,
            });
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run(start: &str, rule: &str, n: usize) -> Vec<String> {
        let rule = Rule::parse(rule).unwrap();
        Recurrence::new(DateTime::parse(start).unwrap(), &rule).take(n).map(|d| d.to_string()).collect()
    }

    #[test]
    fn daily_interval() {
        assert_eq!(
            run("20240101T080000", "FREQ=DAILY;INTERVAL=3;COUNT=3", 10),
            ["20240101T080000", "20240104T080000", "20240107T080000"]
        );
    }

    #[test]
    fn leap_day_yearly() {
        assert_eq!(
            run("20240229T120000", "FREQ=YEARLY;COUNT=3", 10),
            ["20240229T120000", "20280229T120000", "20320229T120000"]
        );
    }

    #[test]
    fn until_is_inclusive() {
        assert_eq!(
            run("20240131T000000", "FREQ=MONTHLY;BYMONTHDAY=-1;UNTIL=20240430T000000", 10),
            ["20240131T000000", "20240229T000000", "20240331T000000", "20240430T000000"]
        );
    }

    #[test]
    fn setpos_discards_before_start() {
        assert_eq!(
            run("20240320T000000", "FREQ=MONTHLY;BYDAY=MO;BYSETPOS=1;COUNT=2", 10),
            ["20240401T000000", "20240506T000000"]
        );
    }

    #[test]
    fn impossible_rule_terminates() {
        assert!(run("20260101T000000", "FREQ=YEARLY;BYMONTH=2;BYMONTHDAY=30;COUNT=5", 10).is_empty());
    }

    #[test]
    fn ordinal_yearly_with_bymonth() {
        assert_eq!(
            run("20240101T000000", "FREQ=YEARLY;BYMONTH=1,7;BYDAY=2MO;COUNT=3", 10),
            ["20240108T000000", "20240708T000000", "20250113T000000"]
        );
    }

    #[test]
    fn ordinal_negative_and_missing_fifth() {
        assert_eq!(
            run("20240101T000000", "FREQ=MONTHLY;BYDAY=5MO;COUNT=2", 10),
            ["20240129T000000", "20240429T000000"]
        );
        assert_eq!(
            run("20240101T000000", "FREQ=MONTHLY;BYDAY=-2SU;COUNT=2", 10),
            ["20240121T000000", "20240218T000000"]
        );
    }

    #[test]
    fn weekly_wkst() {
        assert_eq!(
            run("19970902T090000", "FREQ=WEEKLY;INTERVAL=2;WKST=SU;BYDAY=TU,TH;COUNT=8", 100).len(),
            8
        );
        assert_eq!(
            run("19970902T090000", "FREQ=WEEKLY;INTERVAL=2;WKST=MO;BYDAY=TU,SU;COUNT=4", 4),
            ["19970902T090000", "19970907T090000", "19970916T090000", "19970921T090000"]
        );
    }

    #[test]
    fn yearly_week_numbers() {
        assert_eq!(
            run("20110101T000000", "FREQ=YEARLY;BYWEEKNO=53;COUNT=4", 10),
            ["20110101T000000", "20110102T000000", "20151228T000000", "20151229T000000"]
        );
    }

    #[test]
    fn daily_runs_into_year_9999() {
        let v = run("99991230T000000", "FREQ=DAILY", 10);
        assert_eq!(v, ["99991230T000000", "99991231T000000"]);
    }

    #[test]
    fn until_before_start_is_empty() {
        assert!(run("20240101T000000", "FREQ=DAILY;UNTIL=20231231T000000", 10).is_empty());
    }
}
