//! Runtime values and the total order used for comparison, sorting,
//! grouping, `MIN` and `MAX`.

use std::cmp::Ordering;
use std::fmt;
use std::sync::Arc;

/// A dynamically typed SQL value.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum Value {
    /// SQL `NULL`.
    Null,
    /// A signed 64-bit integer.
    Int(i64),
    /// Text. Cloning is cheap (shared storage).
    Text(Arc<str>),
    /// A REAL produced by `AVG`: the number of hundredths.
    ///
    /// `Real(450)` is `4.50`. Never stored in a table.
    Real(i64),
}

impl Value {
    /// Convenience constructor for text values.
    pub fn text(s: &str) -> Value {
        Value::Text(Arc::from(s))
    }

    /// `true` for [`Value::Null`].
    pub fn is_null(&self) -> bool {
        matches!(self, Value::Null)
    }

    /// Interprets the value in boolean context: `None` is unknown (NULL).
    ///
    /// Integer 0 and REAL 0.00 are false, other numbers true. Text is
    /// converted through its leading integer prefix, as SQLite does.
    pub fn truth(&self) -> Option<bool> {
        match self {
            Value::Null => None,
            Value::Int(i) => Some(*i != 0),
            Value::Real(h) => Some(*h != 0),
            Value::Text(s) => Some(leading_int(s) != 0),
        }
    }

    /// Builds the value `1` or `0`.
    pub fn from_bool(b: bool) -> Value {
        Value::Int(b as i64)
    }

    /// Three-way comparison implementing the total order of the dialect:
    /// NULL < numbers < text; numbers numerically; text by code point.
    pub fn compare(&self, other: &Value) -> Ordering {
        use Value::*;
        match (self, other) {
            (Null, Null) => Ordering::Equal,
            (Null, _) => Ordering::Less,
            (_, Null) => Ordering::Greater,
            (Int(a), Int(b)) => a.cmp(b),
            (Real(a), Real(b)) => a.cmp(b),
            (Int(a), Real(b)) => (*a as i128 * 100).cmp(&(*b as i128)),
            (Real(a), Int(b)) => (*a as i128).cmp(&(*b as i128 * 100)),
            (Text(a), Text(b)) => a.as_bytes().cmp(b.as_bytes()),
            (Text(_), _) => Ordering::Greater,
            (_, Text(_)) => Ordering::Less,
        }
    }
}

fn leading_int(s: &str) -> i64 {
    let s = s.trim_start();
    let (neg, rest) = match s.as_bytes().first() {
        Some(b'-') => (true, &s[1..]),
        Some(b'+') => (false, &s[1..]),
        _ => (false, s),
    };
    let digits: String = rest.chars().take_while(|c| c.is_ascii_digit()).collect();
    let n = digits.parse::<i64>().unwrap_or(0);
    if neg {
        -n
    } else {
        n
    }
}

impl fmt::Display for Value {
    /// Output format: `NULL`, decimal integers, raw text, and REALs with two
    /// decimals.
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Value::Null => f.write_str("NULL"),
            Value::Int(i) => write!(f, "{i}"),
            Value::Text(s) => f.write_str(s),
            Value::Real(h) => {
                let abs = h.unsigned_abs();
                let sign = if *h < 0 { "-" } else { "" };
                write!(f, "{sign}{}.{:02}", abs / 100, abs % 100)
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn total_order() {
        let t = Value::text;
        assert_eq!(Value::Null.compare(&Value::Int(i64::MIN)), Ordering::Less);
        assert_eq!(Value::Int(100).compare(&t("0")), Ordering::Less);
        assert_eq!(t("B").compare(&t("a")), Ordering::Less);
        assert_eq!(t("").compare(&t("a")), Ordering::Less);
        assert_eq!(t("a").compare(&t("ab")), Ordering::Less);
        assert_eq!(Value::Int(2).compare(&Value::Real(200)), Ordering::Equal);
        assert_eq!(Value::Real(150).compare(&Value::Int(2)), Ordering::Less);
    }

    #[test]
    fn display() {
        assert_eq!(Value::Real(-113).to_string(), "-1.13");
        assert_eq!(Value::Real(0).to_string(), "0.00");
        assert_eq!(Value::Real(450).to_string(), "4.50");
        assert_eq!(Value::Int(-5).to_string(), "-5");
        assert_eq!(Value::Null.to_string(), "NULL");
    }

    #[test]
    fn truth() {
        assert_eq!(Value::Null.truth(), None);
        assert_eq!(Value::Int(0).truth(), Some(false));
        assert_eq!(Value::Int(-3).truth(), Some(true));
        assert_eq!(Value::Real(0).truth(), Some(false));
        assert_eq!(Value::Real(1).truth(), Some(true));
    }
}
