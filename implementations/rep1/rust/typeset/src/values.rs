//! Lexical parsers shared by the settings file and directive attributes.

/// Parses a length literal (`[-]digits[.digits][unit]`) into millipoints.
///
/// Returns `None` when the literal is malformed. Absurdly large values
/// saturate so that the caller's range check rejects them.
pub fn parse_length(s: &str) -> Option<i64> {
    let b = s.as_bytes();
    let mut i = 0;
    let neg = b.first() == Some(&b'-');
    if neg {
        i = 1;
    }
    let ws = i;
    while i < b.len() && b[i].is_ascii_digit() {
        i += 1;
    }
    if i == ws {
        return None;
    }
    let whole = saturating_digits(&b[ws..i]);
    let mut k = 0u32;
    let mut frac: i128 = 0;
    if i < b.len() && b[i] == b'.' {
        i += 1;
        let fs = i;
        while i < b.len() && b[i].is_ascii_digit() {
            i += 1;
        }
        k = (i - fs) as u32;
        if k == 0 || k > 3 {
            return None;
        }
        frac = saturating_digits(&b[fs..i]);
    }
    let unit: i128 = match &s[i..] {
        "" => 1,
        "pt" => 1000,
        "mm" => 2835,
        "cm" => 28350,
        "in" => 72000,
        "pc" => 12000,
        _ => return None,
    };
    let p = 10i128.pow(k);
    let v = (whole * p + frac) * unit / p;
    let v = v.min(1_000_000_000_000_000_000);
    Some(if neg { -(v as i64) } else { v as i64 })
}

/// Parses `[-]digits`. Huge values saturate.
pub fn parse_integer(s: &str) -> Option<i64> {
    let b = s.as_bytes();
    let (neg, d) = match b.first() {
        Some(b'-') => (true, &b[1..]),
        _ => (false, b),
    };
    if d.is_empty() || !d.iter().all(|c| c.is_ascii_digit()) {
        return None;
    }
    let v = saturating_digits(d).min(1_000_000_000_000_000_000) as i64;
    Some(if neg { -v } else { v })
}

fn saturating_digits(d: &[u8]) -> i128 {
    let mut v: i128 = 0;
    for &c in d {
        v = (v * 10 + (c - b'0') as i128).min(1_000_000_000_000_000_000_000);
    }
    v
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lengths() {
        assert_eq!(parse_length("2.5pt"), Some(2500));
        assert_eq!(parse_length("0.5pt"), Some(500));
        assert_eq!(parse_length("1.5mm"), Some(4252));
        assert_eq!(parse_length("-6pt"), Some(-6000));
        assert_eq!(parse_length("734"), Some(734));
        assert_eq!(parse_length("1in"), Some(72000));
        assert_eq!(parse_length(""), None);
        assert_eq!(parse_length("+1pt"), None);
        assert_eq!(parse_length("1.pt"), None);
        assert_eq!(parse_length(".5pt"), None);
        assert_eq!(parse_length("1.2345pt"), None);
        assert_eq!(parse_length("20px"), None);
    }

    #[test]
    fn integers() {
        assert_eq!(parse_integer("12"), Some(12));
        assert_eq!(parse_integer("-3"), Some(-3));
        assert_eq!(parse_integer("+3"), None);
        assert_eq!(parse_integer("3pt"), None);
        assert_eq!(parse_integer(""), None);
    }
}
