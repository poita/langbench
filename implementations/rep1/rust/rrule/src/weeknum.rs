//! Week numbering for `BYWEEKNO` (SPEC §4).
//!
//! Weeks start on the rule's `WKST`; week 1 of a year is the first week that
//! contains at least four days of that year.

use crate::calendar;

/// Week-numbering facts about one calendar year.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct YearWeeks {
    year_len: i32,
    /// Day index (0-based from 1 January) on which week 1 starts; may be
    /// negative (-3..=-1) when week 1 begins in the previous December.
    start: i32,
    /// Number of weeks in the year (52 or 53).
    weeks: i32,
    /// The week number assigned to the days before `start` (case (b)).
    leading_label: i32,
}

/// Day index on which week 1 of `year` starts.
fn week1_start(year: i32, wkst: u32) -> i32 {
    let jan1 = calendar::weekday_of_days(calendar::days_from_civil(year, 1, 1));
    let first = ((wkst + 7 - jan1) % 7) as i32;
    if first < 4 {
        first
    } else {
        first - 7
    }
}

fn weeks_from(year_len: i32, start: i32) -> i32 {
    let l = year_len - start;
    l / 7 + i32::from(l % 7 >= 4)
}

impl YearWeeks {
    /// Computes the week structure of `year` (>= 2) for weeks starting on
    /// weekday index `wkst` (0 = Monday).
    pub fn new(year: i32, wkst: u32) -> YearWeeks {
        let year_len = calendar::days_in_year(year) as i32;
        let start = week1_start(year, wkst);
        let weeks = weeks_from(year_len, start);
        let prev_start = week1_start(year - 1, wkst);
        let leading_label = if prev_start < 0 {
            weeks_from(calendar::days_in_year(year - 1) as i32, prev_start)
        } else {
            52 + i32::from((year_len - start) % 7 >= 4)
        };
        YearWeeks { year_len, start, weeks, leading_label }
    }

    /// Number of weeks in the year.
    pub fn weeks(&self) -> u32 {
        self.weeks as u32
    }

    /// Returns whether the day with 0-based year index `i` matches a
    /// `BYWEEKNO` list given as bit sets: bit `w` of `pos` is set for value
    /// `w`, bit `k` of `neg` for value `-k`.
    pub fn matches(&self, i: u32, pos: u64, neg: u64) -> bool {
        let i = i as i32;
        debug_assert!(i < self.year_len);
        if i < self.start {
            // (b) tail of the previous year's last week.
            return neg & 2 != 0 || pos >> self.leading_label & 1 != 0;
        }
        let w = (i - self.start) / 7 + 1;
        if w > self.weeks {
            // (c) head of week 1 of the next year.
            return pos & 2 != 0;
        }
        pos >> w & 1 != 0 || neg >> (self.weeks + 1 - w) & 1 != 0
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pos(vals: &[u32]) -> u64 {
        vals.iter().fold(0, |m, v| m | 1 << v)
    }

    #[test]
    fn iso_week_counts() {
        // With Monday week starts these are the ISO-8601 week counts.
        assert_eq!(YearWeeks::new(2020, 0).weeks(), 53);
        assert_eq!(YearWeeks::new(2026, 0).weeks(), 53);
        assert_eq!(YearWeeks::new(2021, 0).weeks(), 52);
        assert_eq!(YearWeeks::new(2015, 0).weeks(), 53);
    }

    #[test]
    fn leading_label_quirk() {
        // 2011 (WKST=MO): 1 and 2 January get week "53" even though 2010 has 52 weeks.
        let y = YearWeeks::new(2011, 0);
        assert!(y.matches(0, pos(&[53]), 0));
        assert!(y.matches(1, pos(&[53]), 0));
        assert!(!y.matches(2, pos(&[53]), 0));
        // 2012: 1 January is a Sunday and is labelled 52.
        let y = YearWeeks::new(2012, 0);
        assert!(y.matches(0, pos(&[52]), 0));
        assert!(!y.matches(0, pos(&[53]), 0));
    }

    #[test]
    fn trailing_days_belong_to_week_one() {
        // 29 December 2014 (index 362) is Monday of ISO week 1 of 2015.
        let y = YearWeeks::new(2014, 0);
        assert!(y.matches(362, pos(&[1]), 0));
        assert!(!y.matches(361, pos(&[1]), 0));
        assert!(!y.matches(362, 0, 1 << 1));
    }

    #[test]
    fn negative_week_numbers() {
        let y = YearWeeks::new(2021, 0); // 52 weeks, week 1 starts 4 Jan (index 3)
        assert!(y.matches(3 + 51 * 7, 0, 1 << 1));
        assert!(!y.matches(3 + 50 * 7, 0, 1 << 1));
        assert!(y.matches(3 + 50 * 7, 0, 1 << 2));
    }
}
