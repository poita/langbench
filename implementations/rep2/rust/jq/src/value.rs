//! The JSON data model.

use std::cmp::Ordering;
use std::fmt;
use std::rc::Rc;

use crate::object::Object;

/// A JSON value.
///
/// Compound values and strings are reference counted, so cloning a `Value`
/// is O(1) regardless of its size and values are never mutated in place.
///
/// `Value` implements [`PartialEq`] and [`Ord`]-like comparison via
/// [`Value::compare`], using jq's total order:
/// `null < false < true < numbers < strings < arrays < objects`.
#[derive(Clone, Debug)]
pub enum Value {
    /// `null`
    Null,
    /// `true` or `false`
    Bool(bool),
    /// An IEEE-754 double.
    Number(f64),
    /// A string.
    String(Rc<str>),
    /// An array.
    Array(Rc<Vec<Value>>),
    /// An insertion-ordered object.
    Object(Rc<Object>),
}

impl Value {
    /// The jq type name: `"null"`, `"boolean"`, `"number"`, `"string"`,
    /// `"array"` or `"object"`.
    pub fn type_name(&self) -> &'static str {
        match self {
            Value::Null => "null",
            Value::Bool(_) => "boolean",
            Value::Number(_) => "number",
            Value::String(_) => "string",
            Value::Array(_) => "array",
            Value::Object(_) => "object",
        }
    }

    /// Truthiness: everything except `null` and `false` is true.
    pub fn is_truthy(&self) -> bool {
        !matches!(self, Value::Null | Value::Bool(false))
    }

    /// Builds a string value.
    pub fn string(s: &str) -> Value {
        Value::String(Rc::from(s))
    }

    /// Builds an array value.
    pub fn array(items: Vec<Value>) -> Value {
        Value::Array(Rc::new(items))
    }

    /// Builds an object value.
    pub fn object(o: Object) -> Value {
        Value::Object(Rc::new(o))
    }

    fn rank(&self) -> u8 {
        match self {
            Value::Null => 0,
            Value::Bool(false) => 1,
            Value::Bool(true) => 2,
            Value::Number(_) => 3,
            Value::String(_) => 4,
            Value::Array(_) => 5,
            Value::Object(_) => 6,
        }
    }

    /// Compares two values with jq's total order.
    pub fn compare(&self, other: &Value) -> Ordering {
        match (self, other) {
            (Value::Number(a), Value::Number(b)) => a.partial_cmp(b).unwrap_or_else(|| {
                // NaN sorts below every other number (and equal to itself
                // for the purposes of a total order).
                match (a.is_nan(), b.is_nan()) {
                    (true, _) => Ordering::Less,
                    _ => Ordering::Greater,
                }
            }),
            (Value::String(a), Value::String(b)) => a.as_bytes().cmp(b.as_bytes()),
            (Value::Array(a), Value::Array(b)) => {
                if Rc::ptr_eq(a, b) {
                    return Ordering::Equal;
                }
                for (x, y) in a.iter().zip(b.iter()) {
                    let c = x.compare(y);
                    if c != Ordering::Equal {
                        return c;
                    }
                }
                a.len().cmp(&b.len())
            }
            (Value::Object(a), Value::Object(b)) => {
                if Rc::ptr_eq(a, b) {
                    return Ordering::Equal;
                }
                for (x, y) in a.sorted_keys().zip(b.sorted_keys()) {
                    let c = x.as_bytes().cmp(y.as_bytes());
                    if c != Ordering::Equal {
                        return c;
                    }
                }
                let c = a.len().cmp(&b.len());
                if c != Ordering::Equal {
                    return c;
                }
                for ((_, x), (_, y)) in a.sorted_iter().zip(b.sorted_iter()) {
                    let c = x.compare(y);
                    if c != Ordering::Equal {
                        return c;
                    }
                }
                Ordering::Equal
            }
            _ => self.rank().cmp(&other.rank()),
        }
    }
}

impl PartialEq for Value {
    fn eq(&self, other: &Value) -> bool {
        self.compare(other) == Ordering::Equal
    }
}

impl fmt::Display for Value {
    /// Formats the value as compact JSON.
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.to_json())
    }
}

impl From<bool> for Value {
    fn from(b: bool) -> Value {
        Value::Bool(b)
    }
}

impl From<f64> for Value {
    fn from(n: f64) -> Value {
        Value::Number(n)
    }
}

impl From<i64> for Value {
    fn from(n: i64) -> Value {
        Value::Number(n as f64)
    }
}

impl From<&str> for Value {
    fn from(s: &str) -> Value {
        Value::string(s)
    }
}

impl From<String> for Value {
    fn from(s: String) -> Value {
        Value::String(Rc::from(s))
    }
}

impl From<Vec<Value>> for Value {
    fn from(v: Vec<Value>) -> Value {
        Value::array(v)
    }
}

impl From<Object> for Value {
    fn from(o: Object) -> Value {
        Value::object(o)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn p(s: &str) -> Value {
        Value::parse_json(s).unwrap()
    }

    #[test]
    fn type_order() {
        let ordered = ["null", "false", "true", "-1", "0", "2.5", "\"\"", "\"a\"", "[]", "[1]", "{}", "{\"a\":1}"];
        for w in ordered.windows(2) {
            assert!(p(w[0]).compare(&p(w[1])).is_lt(), "{} < {}", w[0], w[1]);
        }
    }

    #[test]
    fn equality_ignores_key_order_and_number_kind() {
        assert_eq!(p(r#"{"a":1,"b":2}"#), p(r#"{"b":2,"a":1.0}"#));
        assert_eq!(p("-0"), p("0"));
        assert_ne!(p("[1,2]"), p("[2,1]"));
    }
}
