//! Number formatting and parsing helpers (section 14.3, 15.2, 15.3).

/// `showFloatAt`: fixed notation with `digits` decimals, rounding the exact
/// value half to even; `nan`, `inf`, `-inf` for non-finite values.
pub fn show_float_at(x: f64, digits: usize) -> String {
    if x.is_nan() {
        return "nan".to_string();
    }
    if x.is_infinite() {
        return if x > 0.0 { "inf".to_string() } else { "-inf".to_string() };
    }
    let body = format!("{:.*}", digits, x.abs());
    if x.is_sign_negative() {
        format!("-{}", body)
    } else {
        body
    }
}

/// `showIntRadix`: the magnitude is formatted as an unsigned 64-bit value.
pub fn show_int_radix(x: i64, radix: u32) -> String {
    let mut m = x.unsigned_abs();
    if m == 0 {
        return "0".to_string();
    }
    let mut digits = Vec::new();
    while m > 0 {
        let d = (m % radix as u64) as u32;
        digits.push(std::char::from_digit(d, radix).unwrap());
        m /= radix as u64;
    }
    if x < 0 {
        digits.push('-');
    }
    digits.iter().rev().collect()
}

/// `parseIntRadix`: optional sign, at least one digit, no other characters.
pub fn parse_int_radix(s: &[char], radix: u32) -> Option<i64> {
    let (neg, digits) = match s.first() {
        Some('+') => (false, &s[1..]),
        Some('-') => (true, &s[1..]),
        _ => (false, s),
    };
    if digits.is_empty() {
        return None;
    }
    let mut acc: u128 = 0;
    for &c in digits {
        let d = c.to_digit(radix)?;
        acc = acc * radix as u128 + d as u128;
        if acc > (1u128 << 63) {
            return None;
        }
    }
    if neg {
        Some((acc as i128).wrapping_neg() as i64)
    } else if acc > i64::MAX as u128 {
        None
    } else {
        Some(acc as i64)
    }
}

/// `parseFloat`: the grammar of section 15.3, correctly rounded.
pub fn parse_float(s: &[char]) -> Option<f64> {
    let mut i = 0;
    let n = s.len();
    let mut text = String::new();
    if i < n && (s[i] == '+' || s[i] == '-') {
        text.push(s[i]);
        i += 1;
    }
    let digit = |c: char| c.is_ascii_digit();
    let start_int = i;
    while i < n && digit(s[i]) {
        text.push(s[i]);
        i += 1;
    }
    let int_digits = i - start_int;
    let mut frac_digits = 0;
    if i < n && s[i] == '.' {
        text.push('.');
        i += 1;
        let st = i;
        while i < n && digit(s[i]) {
            text.push(s[i]);
            i += 1;
        }
        frac_digits = i - st;
        if int_digits == 0 && frac_digits == 0 {
            return None;
        }
    } else if int_digits == 0 {
        return None;
    }
    let _ = frac_digits;
    if i < n && (s[i] == 'e' || s[i] == 'E') {
        text.push('e');
        i += 1;
        if i < n && (s[i] == '+' || s[i] == '-') {
            text.push(s[i]);
            i += 1;
        }
        let st = i;
        while i < n && digit(s[i]) {
            text.push(s[i]);
            i += 1;
        }
        if i == st {
            return None;
        }
    }
    if i != n {
        return None;
    }
    text.parse::<f64>().ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn float_printing() {
        assert_eq!(show_float_at(1.0, 6), "1.000000");
        assert_eq!(show_float_at(2.5, 0), "2");
        assert_eq!(show_float_at(3.5, 0), "4");
        assert_eq!(show_float_at(0.5, 0), "0");
        assert_eq!(show_float_at(-0.0, 6), "-0.000000");
        assert_eq!(show_float_at(2.675, 2), "2.67");
        assert_eq!(show_float_at(0.1 + 0.2, 17), "0.30000000000000004");
        assert_eq!(show_float_at(1e21, 2), "1000000000000000000000.00");
        assert_eq!(show_float_at(-1e-9, 3), "-0.000");
    }

    #[test]
    fn int_parsing() {
        let c = |s: &str| s.chars().collect::<Vec<_>>();
        assert_eq!(parse_int_radix(&c("-9223372036854775808"), 10), Some(i64::MIN));
        assert_eq!(parse_int_radix(&c("9223372036854775808"), 10), None);
        assert_eq!(parse_int_radix(&c("+"), 10), None);
        assert_eq!(parse_int_radix(&c("ff"), 16), Some(255));
        assert_eq!(show_int_radix(i64::MIN, 16), "-8000000000000000");
    }

    #[test]
    fn float_parsing() {
        let c = |s: &str| s.chars().collect::<Vec<_>>();
        assert_eq!(parse_float(&c("12.")), Some(12.0));
        assert_eq!(parse_float(&c(".5")), Some(0.5));
        assert_eq!(parse_float(&c(".")), None);
        assert_eq!(parse_float(&c("1e")), None);
        assert_eq!(parse_float(&c("inf")), None);
        assert_eq!(parse_float(&c("1e999")), Some(f64::INFINITY));
    }
}
