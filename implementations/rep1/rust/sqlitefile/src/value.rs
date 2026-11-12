//! Values, type affinity, ordering and output formatting (SPEC Parts 2.3, 3, 5).

use std::cmp::Ordering;
use std::fmt;

/// A SQLite value of one of the five storage classes.
#[derive(Debug, Clone, PartialEq)]
pub enum Value {
    /// SQL `NULL`.
    Null,
    /// A signed 64-bit integer.
    Integer(i64),
    /// An IEEE-754 double.
    Real(f64),
    /// UTF-8 text.
    Text(String),
    /// Arbitrary bytes.
    Blob(Vec<u8>),
}

/// Column type affinity, derived from the declared type name.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Affinity {
    /// Declared type contains `INT`.
    Integer,
    /// Declared type contains `CHAR`, `CLOB` or `TEXT`.
    Text,
    /// Declared type contains `BLOB`, or is empty.
    Blob,
    /// Declared type contains `REAL`, `FLOA` or `DOUB`.
    Real,
    /// Anything else.
    Numeric,
}

impl Affinity {
    /// Apply the five affinity rules of SPEC §2.3, in order, to a declared type.
    pub fn from_declared_type(decl: &str) -> Affinity {
        let t = decl.to_ascii_uppercase();
        if t.contains("INT") {
            Affinity::Integer
        } else if t.contains("CHAR") || t.contains("CLOB") || t.contains("TEXT") {
            Affinity::Text
        } else if t.contains("BLOB") || t.is_empty() {
            Affinity::Blob
        } else if t.contains("REAL") || t.contains("FLOA") || t.contains("DOUB") {
            Affinity::Real
        } else {
            Affinity::Numeric
        }
    }

    /// Convert a query literal the way SPEC Part 3 prescribes before it is
    /// compared with a column of this affinity.
    pub fn apply_to_literal(self, lit: Value) -> Value {
        match (self, lit) {
            (Affinity::Text, Value::Integer(i)) => Value::Text(i.to_string()),
            (Affinity::Text, Value::Real(r)) => Value::Text(format_real(r)),
            (Affinity::Integer | Affinity::Real | Affinity::Numeric, Value::Text(s)) => {
                match parse_numeric_constant(&s) {
                    Some(v) => v,
                    None => Value::Text(s),
                }
            }
            (_, other) => other,
        }
    }
}

/// Parse text that is entirely a numeric constant (SPEC Part 3).
///
/// Leading and trailing spaces and tabs are dropped. The result is an
/// [`Value::Integer`] when the text has no `.` or exponent and fits in an
/// `i64`, otherwise a [`Value::Real`]. Returns `None` if the text is not a
/// numeric constant.
pub fn parse_numeric_constant(text: &str) -> Option<Value> {
    let t = text.trim_matches(|c| c == ' ' || c == '\t');
    let b = t.as_bytes();
    let mut i = 0;
    if i < b.len() && (b[i] == b'+' || b[i] == b'-') {
        i += 1;
    }
    let int_start = i;
    while i < b.len() && b[i].is_ascii_digit() {
        i += 1;
    }
    let int_digits = i - int_start;
    let mut is_real = false;
    if i < b.len() && b[i] == b'.' {
        is_real = true;
        i += 1;
        let fs = i;
        while i < b.len() && b[i].is_ascii_digit() {
            i += 1;
        }
        if int_digits == 0 && i == fs {
            return None;
        }
    } else if int_digits == 0 {
        return None;
    }
    if i < b.len() && (b[i] == b'e' || b[i] == b'E') {
        is_real = true;
        i += 1;
        if i < b.len() && (b[i] == b'+' || b[i] == b'-') {
            i += 1;
        }
        let es = i;
        while i < b.len() && b[i].is_ascii_digit() {
            i += 1;
        }
        if i == es {
            return None;
        }
    }
    if i != b.len() {
        return None;
    }
    if !is_real {
        if let Ok(n) = t.parse::<i64>() {
            return Some(Value::Integer(n));
        }
    }
    t.parse::<f64>().ok().map(Value::Real)
}

impl Value {
    fn class_rank(&self) -> u8 {
        match self {
            Value::Null => 0,
            Value::Integer(_) | Value::Real(_) => 1,
            Value::Text(_) => 2,
            Value::Blob(_) => 3,
        }
    }

    /// Three-way comparison implementing SPEC Part 3.
    ///
    /// NULL < numbers < TEXT < BLOB. Two integers compare exactly; an integer
    /// and a real compare as doubles; text and blobs compare bytewise.
    pub fn compare(&self, other: &Value) -> Ordering {
        match (self, other) {
            (Value::Integer(a), Value::Integer(b)) => a.cmp(b),
            (Value::Integer(a), Value::Real(b)) => cmp_f64(*a as f64, *b),
            (Value::Real(a), Value::Integer(b)) => cmp_f64(*a, *b as f64),
            (Value::Real(a), Value::Real(b)) => cmp_f64(*a, *b),
            (Value::Text(a), Value::Text(b)) => a.as_bytes().cmp(b.as_bytes()),
            (Value::Blob(a), Value::Blob(b)) => a.cmp(b),
            (a, b) => a.class_rank().cmp(&b.class_rank()),
        }
    }

    /// `true` for [`Value::Null`].
    pub fn is_null(&self) -> bool {
        matches!(self, Value::Null)
    }
}

fn cmp_f64(a: f64, b: f64) -> Ordering {
    a.partial_cmp(&b).unwrap_or(Ordering::Equal)
}

/// Format a double like C's `%.15g`, with SPEC §Part 5's adjustments: a
/// mantissa without a `.` gets `.0`, and zero prints as `0.0`.
pub fn format_real(v: f64) -> String {
    if v == 0.0 {
        return "0.0".to_string();
    }
    let sci = format!("{:.14e}", v);
    let (mant, exp) = sci.split_once('e').expect("exponent form");
    let exp: i32 = exp.parse().expect("integer exponent");
    let negative = mant.starts_with('-');
    let digits: String = mant.chars().filter(|c| c.is_ascii_digit()).collect();
    let mut out = String::new();
    if negative {
        out.push('-');
    }
    if !(-4..15).contains(&exp) {
        let frac = digits[1..].trim_end_matches('0');
        out.push_str(&digits[..1]);
        out.push('.');
        out.push_str(if frac.is_empty() { "0" } else { frac });
        out.push('e');
        out.push(if exp < 0 { '-' } else { '+' });
        out.push_str(&format!("{:02}", exp.abs()));
    } else if exp >= 0 {
        let split = exp as usize + 1;
        let frac = digits[split..].trim_end_matches('0');
        out.push_str(&digits[..split]);
        out.push('.');
        out.push_str(if frac.is_empty() { "0" } else { frac });
    } else {
        out.push_str("0.");
        for _ in 0..(-exp - 1) {
            out.push('0');
        }
        out.push_str(digits.trim_end_matches('0'));
    }
    out
}

impl fmt::Display for Value {
    /// Prints the value the way the `sqlite3` shell does in list mode with
    /// `-nullvalue NULL` and hex-encoded blobs (SPEC Part 5).
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Value::Null => f.write_str("NULL"),
            Value::Integer(i) => write!(f, "{i}"),
            Value::Real(r) => f.write_str(&format_real(*r)),
            Value::Text(s) => f.write_str(s),
            Value::Blob(b) => {
                for byte in b {
                    write!(f, "{byte:02X}")?;
                }
                Ok(())
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn affinity_rules_in_order() {
        use Affinity::*;
        let a = Affinity::from_declared_type;
        assert_eq!(a("INTEGER"), Integer);
        assert_eq!(a("NVARCHAR ( 160 )"), Text);
        assert_eq!(a("NUMERIC(10,2)"), Numeric);
        assert_eq!(a(""), Blob);
        assert_eq!(a("POINT"), Integer);
        assert_eq!(a("FLOATING POINT"), Integer);
        assert_eq!(a("STRING"), Numeric);
        assert_eq!(a("INT TEXT"), Integer);
        assert_eq!(a("CHAR FLOA"), Text);
        assert_eq!(a("BLOB REAL"), Blob);
        assert_eq!(a("double precision"), Real);
    }

    #[test]
    fn numeric_constants() {
        let p = parse_numeric_constant;
        assert_eq!(p(" 5 "), Some(Value::Integer(5)));
        assert_eq!(p(".5"), Some(Value::Real(0.5)));
        assert_eq!(p("-.5"), Some(Value::Real(-0.5)));
        assert_eq!(p("5."), Some(Value::Real(5.0)));
        assert_eq!(p("+5e0"), Some(Value::Real(5.0)));
        assert_eq!(
            p("9223372036854775807"),
            Some(Value::Integer(i64::MAX))
        );
        assert_eq!(p("9223372036854775808"), Some(Value::Real(9223372036854775808.0)));
        for bad in ["", "-", "0x10", "inf", "5 x", ".", "1e", "e5", "+"] {
            assert_eq!(p(bad), None, "{bad:?}");
        }
    }

    #[test]
    fn literal_affinity() {
        assert_eq!(
            Affinity::Text.apply_to_literal(Value::Real(1.0)),
            Value::Text("1.0".into())
        );
        assert_eq!(
            Affinity::Integer.apply_to_literal(Value::Text("42".into())),
            Value::Integer(42)
        );
        assert_eq!(
            Affinity::Blob.apply_to_literal(Value::Text("42".into())),
            Value::Text("42".into())
        );
        assert_eq!(
            Affinity::Numeric.apply_to_literal(Value::Text("4x".into())),
            Value::Text("4x".into())
        );
    }

    #[test]
    fn ordering() {
        use Ordering::*;
        let t = |s: &str| Value::Text(s.into());
        assert_eq!(Value::Null.compare(&Value::Integer(i64::MIN)), Less);
        assert_eq!(Value::Integer(5).compare(&Value::Real(5.0)), Equal);
        assert_eq!(Value::Integer(i64::MAX).compare(&Value::Integer(i64::MAX - 1)), Greater);
        assert_eq!(Value::Real(1e300).compare(&t("a")), Less);
        assert_eq!(t("a").compare(&Value::Blob(vec![])), Less);
        assert_eq!(t("ab").compare(&t("a")), Greater);
        assert_eq!(t("Z").compare(&t("a")), Less);
        assert_eq!(Value::Null.compare(&Value::Null), Equal);
    }

    #[test]
    fn real_formatting() {
        let cases = [
            (1.0, "1.0"),
            (0.1, "0.1"),
            (-3.25, "-3.25"),
            (1.0 / 3.0, "0.333333333333333"),
            (1e300, "1.0e+300"),
            (2.5e-10, "2.5e-10"),
            (1.5e16, "1.5e+16"),
            (1e14, "100000000000000.0"),
            (1e15, "1.0e+15"),
            (0.0001, "0.0001"),
            (1e-5, "1.0e-05"),
            (0.0, "0.0"),
            (-0.0, "0.0"),
            (123456.789, "123456.789"),
        ];
        for (v, s) in cases {
            assert_eq!(format_real(v), s, "{v:e}");
        }
    }

    #[test]
    fn display() {
        assert_eq!(Value::Null.to_string(), "NULL");
        assert_eq!(Value::Integer(-7).to_string(), "-7");
        assert_eq!(Value::Blob(vec![0, 0x7f, 0xab]).to_string(), "007FAB");
        assert_eq!(Value::Blob(vec![]).to_string(), "");
        assert_eq!(Value::Text("é".into()).to_string(), "é");
    }
}
