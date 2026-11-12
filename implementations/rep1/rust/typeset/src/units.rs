//! Exact integer arithmetic helpers: floor division, glyph-space scaling and
//! numeral formatting.

/// Floor division by a positive divisor.
pub fn fdiv(a: i64, b: i64) -> i64 {
    debug_assert!(b > 0);
    a.div_euclid(b)
}

/// Scales a glyph-space quantity `u` (thousandths of an em) to millipoints at
/// size `s`: `(u * s) div 1000`.
pub fn scale(u: i64, s: i64) -> i64 {
    fdiv(u * s, 1000)
}

/// Lowercase roman numeral by greedy subtraction (so 4000 is `mmmm`).
pub fn roman(mut n: u64) -> String {
    const PAIRS: [(u64, &str); 13] = [
        (1000, "m"),
        (900, "cm"),
        (500, "d"),
        (400, "cd"),
        (100, "c"),
        (90, "xc"),
        (50, "l"),
        (40, "xl"),
        (10, "x"),
        (9, "ix"),
        (5, "v"),
        (4, "iv"),
        (1, "i"),
    ];
    let mut out = String::new();
    for (value, text) in PAIRS {
        while n >= value {
            out.push_str(text);
            n -= value;
        }
    }
    out
}

/// Bijective base-26 lowercase letters: 1 is `a`, 26 is `z`, 27 is `aa`.
pub fn letters(mut n: u64) -> String {
    let mut out = Vec::new();
    while n > 0 {
        n -= 1;
        out.push(b'a' + (n % 26) as u8);
        n /= 26;
    }
    out.reverse();
    String::from_utf8(out).unwrap()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn floor_division_rounds_down() {
        assert_eq!(fdiv(7, 2), 3);
        assert_eq!(fdiv(-7, 2), -4);
        assert_eq!(fdiv(-3307000, 5100), -649);
        assert_eq!(fdiv(0, 5), 0);
    }

    #[test]
    fn scale_matches_spec_examples() {
        assert_eq!(scale(1563, 10000), 15630);
        assert_eq!(scale(1054, 11000), 11594);
        assert_eq!(scale(-1, 500), -1);
    }

    #[test]
    fn roman_numerals() {
        assert_eq!(roman(1), "i");
        assert_eq!(roman(14), "xiv");
        assert_eq!(roman(2026), "mmxxvi");
        assert_eq!(roman(4000), "mmmm");
        assert_eq!(roman(5001), "mmmmmi");
    }

    #[test]
    fn bijective_letters() {
        assert_eq!(letters(1), "a");
        assert_eq!(letters(26), "z");
        assert_eq!(letters(27), "aa");
        assert_eq!(letters(52), "az");
        assert_eq!(letters(53), "ba");
    }
}
