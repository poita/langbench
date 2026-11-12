//! Integer and float literals: validation, conversion and canonical text.

/// Parses the digits of a number in `radix`, allowing single underscores
/// between digits. Returns `None` for empty input, a leading, trailing or
/// doubled underscore, any non-digit, or a value that does not fit in `u64`.
fn digits_value(d: &[u8], radix: u32) -> Option<u64> {
    if d.is_empty() || d[0] == b'_' || d[d.len() - 1] == b'_' {
        return None;
    }
    let mut value: u64 = 0;
    let mut prev_underscore = false;
    for &c in d {
        if c == b'_' {
            if prev_underscore {
                return None;
            }
            prev_underscore = true;
            continue;
        }
        prev_underscore = false;
        let digit = (c as char).to_digit(radix)?;
        value = value.checked_mul(radix as u64)?.checked_add(digit as u64)?;
    }
    Some(value)
}

/// Checks the `[0-9] ( "_"? [0-9] )*` shape (leading zeros allowed) and
/// appends the digits, without underscores, to `out`.
fn push_digits(d: &[u8], out: &mut String) -> Option<()> {
    if d.is_empty() || d[0] == b'_' || d[d.len() - 1] == b'_' {
        return None;
    }
    let mut prev_underscore = false;
    for &c in d {
        if c == b'_' {
            if prev_underscore {
                return None;
            }
            prev_underscore = true;
        } else if c.is_ascii_digit() {
            prev_underscore = false;
            out.push(c as char);
        } else {
            return None;
        }
    }
    Some(())
}

/// Parses a TOML integer literal (decimal, `0x`, `0o` or `0b`), enforcing the
/// signed 64-bit range in every base.
pub fn parse_integer(tok: &str) -> Option<i64> {
    let b = tok.as_bytes();
    if b.len() > 2 && b[0] == b'0' {
        let radix = match b[1] {
            b'x' => Some(16),
            b'o' => Some(8),
            b'b' => Some(2),
            _ => None,
        };
        if let Some(radix) = radix {
            let v = digits_value(&b[2..], radix)?;
            return i64::try_from(v).ok();
        }
    }
    let (neg, digits) = match b.first()? {
        b'-' => (true, &b[1..]),
        b'+' => (false, &b[1..]),
        _ => (false, b),
    };
    if digits.len() > 1 && digits[0] == b'0' {
        return None;
    }
    let mag = digits_value(digits, 10)?;
    if neg {
        if mag <= 1u64 << 63 {
            Some((mag as i128).wrapping_neg() as i64)
        } else {
            None
        }
    } else {
        i64::try_from(mag).ok()
    }
}

/// Parses a TOML float literal (including `inf` and `nan`). Overflow becomes
/// infinity and underflow becomes zero.
pub fn parse_float(tok: &str) -> Option<f64> {
    let b = tok.as_bytes();
    let (neg, body) = match b.first()? {
        b'-' => (true, &b[1..]),
        b'+' => (false, &b[1..]),
        _ => (false, b),
    };
    match body {
        b"inf" => return Some(if neg { f64::NEG_INFINITY } else { f64::INFINITY }),
        b"nan" => return Some(f64::NAN),
        _ => {}
    }
    // Integer part: "0" or [1-9] ( "_"? [0-9] )*
    let int_end = body
        .iter()
        .position(|&c| matches!(c, b'.' | b'e' | b'E'))
        .unwrap_or(body.len());
    let int_part = &body[..int_end];
    if int_part.len() > 1 && int_part[0] == b'0' {
        return None;
    }
    let mut text = String::with_capacity(tok.len() + 1);
    if neg {
        text.push('-');
    }
    push_digits(int_part, &mut text)?;
    let mut rest = &body[int_end..];
    let mut has_frac_or_exp = false;
    if let Some((b'.', after)) = rest.split_first() {
        let frac_end = after
            .iter()
            .position(|&c| matches!(c, b'e' | b'E'))
            .unwrap_or(after.len());
        text.push('.');
        push_digits(&after[..frac_end], &mut text)?;
        rest = &after[frac_end..];
        has_frac_or_exp = true;
    }
    if let Some((b'e' | b'E', after)) = rest.split_first() {
        text.push('e');
        let after = match after.first() {
            Some(b'-') => {
                text.push('-');
                &after[1..]
            }
            Some(b'+') => &after[1..],
            _ => after,
        };
        push_digits(after, &mut text)?;
        rest = &[];
        has_frac_or_exp = true;
    }
    if !rest.is_empty() || !has_frac_or_exp {
        return None;
    }
    text.parse::<f64>().ok()
}

/// Formats a float in the canonical text form: `nan`, `inf`, `-inf`, or
/// exactly 17 significant digits in scientific notation (`%.16e`).
pub fn format_float(x: f64) -> String {
    if x.is_nan() {
        return "nan".to_string();
    }
    if x.is_infinite() {
        return if x < 0.0 { "-inf" } else { "inf" }.to_string();
    }
    let s = format!("{:.16e}", x);
    let (mantissa, exp) = s.split_once('e').expect("exponent marker");
    let (sign, digits) = match exp.strip_prefix('-') {
        Some(d) => ('-', d),
        None => ('+', exp),
    };
    format!("{mantissa}e{sign}{digits:0>2}")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn integers() {
        assert_eq!(parse_integer("0"), Some(0));
        assert_eq!(parse_integer("+17"), Some(17));
        assert_eq!(parse_integer("-17"), Some(-17));
        assert_eq!(parse_integer("1_000"), Some(1000));
        assert_eq!(parse_integer("0xdead_BEEF"), Some(0xdeadbeef));
        assert_eq!(parse_integer("0o755"), Some(0o755));
        assert_eq!(parse_integer("0b1101"), Some(13));
        assert_eq!(parse_integer("9223372036854775807"), Some(i64::MAX));
        assert_eq!(parse_integer("-9223372036854775808"), Some(i64::MIN));
        assert_eq!(parse_integer("9223372036854775808"), None);
        assert_eq!(parse_integer("0xFFFFFFFFFFFFFFFF"), None);
        assert_eq!(parse_integer("0x7FFFFFFFFFFFFFFF"), Some(i64::MAX));
    }

    #[test]
    fn bad_integers() {
        for bad in [
            "", "+", "01", "+01", "1__0", "_1", "1_", "0X1", "-0x1", "0x", "0x_1", "0o8", "0b2",
            "1.0", "٣",
        ] {
            assert_eq!(parse_integer(bad), None, "{bad}");
        }
    }

    #[test]
    fn floats() {
        assert_eq!(parse_float("1.5"), Some(1.5));
        assert_eq!(parse_float("-0.0").map(f64::is_sign_negative), Some(true));
        assert_eq!(parse_float("1e3"), Some(1000.0));
        assert_eq!(parse_float("0e00"), Some(0.0));
        assert_eq!(parse_float("6.02_2e+2_3"), Some(6.022e23));
        assert_eq!(parse_float("1e400"), Some(f64::INFINITY));
        assert_eq!(parse_float("1e-400"), Some(0.0));
        assert!(parse_float("-nan").unwrap().is_nan());
        assert_eq!(parse_float("+inf"), Some(f64::INFINITY));
    }

    #[test]
    fn bad_floats() {
        for bad in [
            ".5", "5.", "1.e2", "1e", "01.5", "1", "Inf", "NaN", "1._5", "1.5_", "1e_5", "1.5e+",
            "e5", "0x1.0", "+-1.0", "1.5f",
        ] {
            assert_eq!(parse_float(bad), None, "{bad}");
        }
    }

    #[test]
    fn float_text() {
        assert_eq!(format_float(1.0), "1.0000000000000000e+00");
        assert_eq!(format_float(3.1415), "3.1415000000000002e+00");
        assert_eq!(format_float(-0.0), "-0.0000000000000000e+00");
        assert_eq!(format_float(1e308), "1.0000000000000000e+308");
        assert_eq!(format_float(6.626e-34), "6.6259999999999998e-34");
        assert_eq!(format_float(5e-324), "4.9406564584124654e-324");
        assert_eq!(format_float(f64::NAN), "nan");
        assert_eq!(format_float(f64::NEG_INFINITY), "-inf");
    }
}
