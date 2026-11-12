//! Low-level number scanning shared by all the micro-grammars.

/// Trims XML whitespace (space, tab, CR, LF, FF) from both ends.
pub fn trim_ws(s: &str) -> &str {
    s.trim_matches(|c: char| c.is_ascii_whitespace())
}

/// Scans a number at the start of `s`: optional sign, digits with optional
/// fraction (at least one digit overall) and an optional exponent that is
/// only consumed when it has at least one digit. Returns the value and the
/// number of bytes consumed.
pub fn parse_number(s: &str) -> Option<(f64, usize)> {
    let b = s.as_bytes();
    let mut i = 0;
    if i < b.len() && (b[i] == b'+' || b[i] == b'-') {
        i += 1;
    }
    let int_start = i;
    while i < b.len() && b[i].is_ascii_digit() {
        i += 1;
    }
    let mut digits = i - int_start;
    if i < b.len() && b[i] == b'.' {
        let frac_start = i + 1;
        let mut j = frac_start;
        while j < b.len() && b[j].is_ascii_digit() {
            j += 1;
        }
        let fd = j - frac_start;
        if digits > 0 || fd > 0 {
            digits += fd;
            i = j;
        }
    }
    if digits == 0 {
        return None;
    }
    if i < b.len() && (b[i] == b'e' || b[i] == b'E') {
        let mut j = i + 1;
        if j < b.len() && (b[j] == b'+' || b[j] == b'-') {
            j += 1;
        }
        let ds = j;
        while j < b.len() && b[j].is_ascii_digit() {
            j += 1;
        }
        if j > ds {
            i = j;
        }
    }
    s[..i].parse::<f64>().ok().map(|v| (v, i))
}

/// Parses a length: a number optionally followed by `px`, with surrounding
/// whitespace allowed. Returns `None` when the value does not start with a
/// number.
pub fn parse_length(s: &str) -> Option<f64> {
    let s = trim_ws(s);
    parse_number(s).map(|(v, _)| v)
}

/// Parses every number in a list separated by whitespace and/or commas.
/// Parsing stops at the first token that is not a number.
pub fn parse_number_list(s: &str) -> Vec<f64> {
    let mut out = Vec::new();
    let mut rest = s;
    loop {
        rest = rest.trim_start_matches(|c: char| c == ',' || c.is_ascii_whitespace());
        match parse_number(rest) {
            Some((v, n)) => {
                out.push(v);
                rest = &rest[n..];
            }
            None => break,
        }
    }
    out
}

/// Parses an opacity value: a number, or a number followed by `%`, clamped to
/// `[0, 1]`. Returns `None` for anything else.
pub fn parse_opacity(s: &str) -> Option<f64> {
    let s = trim_ws(s);
    let (v, n) = parse_number(s)?;
    match trim_ws(&s[n..]) {
        "" => Some(v.clamp(0.0, 1.0)),
        "%" => Some((v / 100.0).clamp(0.0, 1.0)),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn numbers() {
        assert_eq!(parse_number("5."), Some((5.0, 2)));
        assert_eq!(parse_number(".5x"), Some((0.5, 2)));
        assert_eq!(parse_number("-1.5e2,"), Some((-150.0, 6)));
        assert_eq!(parse_number("3e"), Some((3.0, 1)));
        assert_eq!(parse_number("."), None);
        assert_eq!(parse_number("-"), None);
        assert_eq!(parse_number("1.5.5"), Some((1.5, 3)));
    }

    #[test]
    fn lengths_and_lists() {
        assert_eq!(parse_length(" 12px "), Some(12.0));
        assert_eq!(parse_length("abc"), None);
        assert_eq!(parse_number_list("1,2 3-4"), vec![1.0, 2.0, 3.0, -4.0]);
    }

    #[test]
    fn opacity() {
        assert_eq!(parse_opacity("60%"), Some(0.6));
        assert_eq!(parse_opacity("2"), Some(1.0));
        assert_eq!(parse_opacity("0.5x"), None);
        assert_eq!(parse_opacity(""), None);
    }
}
