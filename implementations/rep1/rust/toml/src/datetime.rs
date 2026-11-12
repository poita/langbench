//! Date and time literals, validated and canonicalised as text.

use crate::value::{Scalar, ScalarKind};

fn num(b: &[u8]) -> Option<u32> {
    if b.is_empty() || !b.iter().all(u8::is_ascii_digit) {
        return None;
    }
    Some(b.iter().fold(0, |acc, &c| acc * 10 + (c - b'0') as u32))
}

fn is_leap(year: u32) -> bool {
    year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
}

/// Validates `YYYY-MM-DD` at the start of `b` (exactly ten bytes are used).
fn check_date(b: &[u8]) -> Option<()> {
    if b.len() < 10 || b[4] != b'-' || b[7] != b'-' {
        return None;
    }
    let year = num(&b[0..4])?;
    if year == 0 {
        return None; // the year range is 0001-9999
    }
    let month = num(&b[5..7])?;
    let day = num(&b[8..10])?;
    let days = match month {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        2 if is_leap(year) => 29,
        2 => 28,
        _ => return None,
    };
    (1..=days).contains(&day).then_some(())
}

/// Parses `HH:MM:SS[.frac]` at the start of `b`; returns the canonical text
/// (trailing fractional zeros removed) and the number of bytes consumed.
fn parse_time(b: &[u8]) -> Option<(String, usize)> {
    if b.len() < 8 || b[2] != b':' || b[5] != b':' {
        return None;
    }
    if num(&b[0..2])? > 23 || num(&b[3..5])? > 59 || num(&b[6..8])? > 59 {
        return None;
    }
    let mut text = String::from_utf8(b[..8].to_vec()).ok()?;
    let mut used = 8;
    if b.get(8) == Some(&b'.') {
        let frac_len = b[9..].iter().take_while(|c| c.is_ascii_digit()).count();
        if frac_len == 0 {
            return None;
        }
        let frac = &b[9..9 + frac_len];
        let keep = frac.iter().rposition(|&c| c != b'0').map_or(0, |i| i + 1);
        if keep > 0 {
            text.push('.');
            text.push_str(std::str::from_utf8(&frac[..keep]).ok()?);
        }
        used = 9 + frac_len;
    }
    Some((text, used))
}

/// Parses an offset (`Z`, `z`, `+HH:MM`, `-HH:MM`) occupying all of `b`.
fn parse_offset(b: &[u8]) -> Option<String> {
    match b {
        [b'Z' | b'z'] => Some("Z".to_string()),
        [sign @ (b'+' | b'-'), h1, h2, b':', m1, m2] => {
            let hour = num(&[*h1, *h2])?;
            let minute = num(&[*m1, *m2])?;
            if hour > 23 || minute > 59 {
                return None;
            }
            if hour == 0 && minute == 0 {
                return Some("Z".to_string());
            }
            Some(format!("{}{:02}:{:02}", *sign as char, hour, minute))
        }
        _ => None,
    }
}

/// Parses a date, time or date-time literal into its canonical [`Scalar`].
///
/// `tok` is the complete literal; a space separator between date and time may
/// appear inside it. Returns `None` if it is not a valid literal.
pub fn parse(tok: &str) -> Option<Scalar> {
    let b = tok.as_bytes();
    if b.len() >= 3 && b[2] == b':' {
        let (text, used) = parse_time(b)?;
        return (used == b.len()).then(|| Scalar::new(ScalarKind::TimeLocal, text));
    }
    check_date(b)?;
    let date = &tok[..10];
    if b.len() == 10 {
        return Some(Scalar::new(ScalarKind::DateLocal, date));
    }
    if !matches!(b[10], b'T' | b't' | b' ') {
        return None;
    }
    let (time, used) = parse_time(&b[11..])?;
    let rest = &b[11 + used..];
    if rest.is_empty() {
        return Some(Scalar::new(ScalarKind::DateTimeLocal, format!("{date}T{time}")));
    }
    let offset = parse_offset(rest)?;
    Some(Scalar::new(ScalarKind::DateTime, format!("{date}T{time}{offset}")))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn text(s: &str) -> Option<(ScalarKind, String)> {
        parse(s).map(|s| (s.kind, s.text))
    }

    #[test]
    fn canonical_forms() {
        use ScalarKind::*;
        assert_eq!(text("1979-05-27"), Some((DateLocal, "1979-05-27".into())));
        assert_eq!(text("07:32:00.500"), Some((TimeLocal, "07:32:00.5".into())));
        assert_eq!(text("07:32:00.000"), Some((TimeLocal, "07:32:00".into())));
        assert_eq!(
            text("1987-07-05 17:45:00z"),
            Some((DateTime, "1987-07-05T17:45:00Z".into()))
        );
        assert_eq!(
            text("1987-07-05t17:45:56.600+08:00"),
            Some((DateTime, "1987-07-05T17:45:56.6+08:00".into()))
        );
        assert_eq!(
            text("1979-05-27t07:32:00-00:00"),
            Some((DateTime, "1979-05-27T07:32:00Z".into()))
        );
        assert_eq!(
            text("1979-05-27T07:32:00"),
            Some((DateTimeLocal, "1979-05-27T07:32:00".into()))
        );
    }

    #[test]
    fn rejects() {
        for bad in [
            "1987-7-05",
            "1987-02-29",
            "1987-13-01",
            "1987-00-10",
            "0000-01-01",
            "1987-04-31",
            "1979-05-27T24:00:00",
            "1979-05-27T07:60:00",
            "1979-05-27T07:32:60",
            "1979-05-27T07:32",
            "1979-05-27T07:32:00.",
            "1979-05-27T07:32:00+24:00",
            "1979-05-27T07:32:00+08:60",
            "1979-05-27T07:32:00+0800",
            "1979-05-27T07:32:00Zx",
            "1979-05-27x07:32:00",
            "١٩٧٩-٠٥-٢٧",
            "7:32:00",
        ] {
            assert_eq!(text(bad), None, "{bad}");
        }
        assert!(text("2000-02-29").is_some());
        assert!(text("1900-02-29").is_none());
    }
}
