//! Proleptic Gregorian calendar arithmetic implemented from first principles.
//!
//! Dates are represented as *day numbers*: the number of days since
//! 0001-01-01, which is day 0 and a Monday. All conversions are closed-form
//! (O(1)) and based on the 400-year Gregorian cycle.

/// Days in a 400-year Gregorian cycle.
const DAYS_PER_400Y: i64 = 146_097;
/// Days in a 100-year span that does not contain a leap-century year.
const DAYS_PER_100Y: i64 = 36_524;
/// Days in a 4-year span that contains a leap day.
const DAYS_PER_4Y: i64 = 1_461;

/// Cumulative days before each month in a non-leap year.
const CUM_DAYS: [u16; 13] = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334, 365];

/// Returns `true` if `year` is a leap year in the Gregorian calendar.
pub fn is_leap_year(year: i32) -> bool {
    year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
}

/// Number of days in `year` (365 or 366).
pub fn days_in_year(year: i32) -> u32 {
    if is_leap_year(year) {
        366
    } else {
        365
    }
}

/// Number of days in `month` (1–12) of `year`.
pub fn days_in_month(year: i32, month: u32) -> u32 {
    debug_assert!((1..=12).contains(&month));
    let base = (CUM_DAYS[month as usize] - CUM_DAYS[month as usize - 1]) as u32;
    if month == 2 && is_leap_year(year) {
        29
    } else {
        base
    }
}

/// Returns `true` if `(year, month, day)` is a valid calendar date.
pub fn is_valid_date(year: i32, month: u32, day: u32) -> bool {
    year >= 1 && (1..=12).contains(&month) && day >= 1 && day <= days_in_month(year, month)
}

/// Converts a valid calendar date (`year >= 1`) to a day number.
pub fn days_from_civil(year: i32, month: u32, day: u32) -> i64 {
    debug_assert!(is_valid_date(year, month, day));
    let y = i64::from(year) - 1;
    let mut days = 365 * y + y / 4 - y / 100 + y / 400;
    days += i64::from(CUM_DAYS[month as usize - 1]);
    if month > 2 && is_leap_year(year) {
        days += 1;
    }
    days + i64::from(day) - 1
}

/// Converts a day number (`>= 0`) to `(year, month, day)`.
pub fn civil_from_days(days: i64) -> (i32, u32, u32) {
    debug_assert!(days >= 0);
    let cycles = days / DAYS_PER_400Y;
    let mut rem = days % DAYS_PER_400Y;
    // Century within the cycle; the last century has one extra day.
    let mut centuries = rem / DAYS_PER_100Y;
    if centuries == 4 {
        centuries = 3;
    }
    rem -= centuries * DAYS_PER_100Y;
    let quads = rem / DAYS_PER_4Y;
    rem -= quads * DAYS_PER_4Y;
    let mut years = rem / 365;
    if years == 4 {
        years = 3;
    }
    rem -= years * 365;
    let year = (cycles * 400 + centuries * 100 + quads * 4 + years + 1) as i32;
    // `rem` is now the 0-based day of the year.
    let leap = is_leap_year(year);
    let mut month = 1usize;
    while month < 12 {
        let end = i64::from(CUM_DAYS[month]) + i64::from(leap && month >= 2);
        if rem < end {
            break;
        }
        month += 1;
    }
    let start = i64::from(CUM_DAYS[month - 1]) + i64::from(leap && month > 2);
    (year, month as u32, (rem - start) as u32 + 1)
}

/// Weekday of a day number, `0` = Monday … `6` = Sunday.
pub fn weekday_of_days(days: i64) -> u32 {
    days.rem_euclid(7) as u32
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn leap_years() {
        assert!(is_leap_year(2000));
        assert!(is_leap_year(2024));
        assert!(!is_leap_year(1900));
        assert!(!is_leap_year(2023));
        assert!(is_leap_year(1600));
    }

    #[test]
    fn month_lengths() {
        assert_eq!(days_in_month(2024, 2), 29);
        assert_eq!(days_in_month(2023, 2), 28);
        assert_eq!(days_in_month(2023, 12), 31);
        assert_eq!(days_in_month(2023, 4), 30);
        assert_eq!(days_in_year(2024), 366);
    }

    #[test]
    fn anchors() {
        assert_eq!(days_from_civil(1, 1, 1), 0);
        assert_eq!(weekday_of_days(days_from_civil(1, 1, 1)), 0);
        // 2000-01-01 is a Saturday.
        assert_eq!(weekday_of_days(days_from_civil(2000, 1, 1)), 5);
        // 1970-01-01 is 719162 days after 0001-01-01 (a Thursday).
        assert_eq!(days_from_civil(1970, 1, 1), 719_162);
        assert_eq!(weekday_of_days(719_162), 3);
    }

    #[test]
    fn round_trip_all_days() {
        let start = days_from_civil(1000, 1, 1);
        let end = days_from_civil(10_001, 12, 31);
        let mut expected_day = start;
        for y in 1000..=10_001 {
            for m in 1..=12 {
                for d in 1..=days_in_month(y, m) {
                    assert_eq!(days_from_civil(y, m, d), expected_day);
                    assert_eq!(civil_from_days(expected_day), (y, m, d));
                    expected_day += 1;
                }
            }
        }
        assert_eq!(expected_day, end + 1);
    }

    #[test]
    fn cycle_boundaries() {
        for &(y, m, d) in &[(400, 12, 31), (800, 2, 29), (1600, 12, 31), (2000, 2, 29), (2100, 3, 1), (1, 1, 1)] {
            assert_eq!(civil_from_days(days_from_civil(y, m, d)), (y, m, d));
        }
    }
}
