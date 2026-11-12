//! The immutable, cheaply clonable JSON value type and its total ordering.

use crate::object::Object;
use std::cmp::Ordering;
use std::fmt;
use std::rc::Rc;

/// A JSON value. Cloning is O(1): strings, arrays and objects are reference counted
/// and never mutated after construction.
#[derive(Debug, Clone, Default)]
pub enum Value {
    /// `null`
    #[default]
    Null,
    /// `true` / `false`
    Bool(bool),
    /// An IEEE-754 double (there is no separate integer type).
    Number(f64),
    /// A string.
    String(Rc<str>),
    /// An array.
    Array(Rc<Vec<Value>>),
    /// An insertion-ordered object.
    Object(Rc<Object>),
}

impl Value {
    /// Builds a string value.
    pub fn string(s: impl Into<Rc<str>>) -> Value {
        Value::String(s.into())
    }

    /// Builds an array value.
    pub fn array(items: Vec<Value>) -> Value {
        Value::Array(Rc::new(items))
    }

    /// Builds an object value.
    pub fn object(o: Object) -> Value {
        Value::Object(Rc::new(o))
    }

    /// jq truthiness: everything except `false` and `null` is true.
    pub fn is_truthy(&self) -> bool {
        !matches!(self, Value::Null | Value::Bool(false))
    }

    /// The jq type name (`"null"`, `"boolean"`, `"number"`, `"string"`, `"array"`, `"object"`).
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

    fn type_rank(&self) -> u8 {
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

    /// The total order used by `sort`, `<`, `unique`, ...:
    /// `null < false < true < numbers < strings < arrays < objects`, then within a type.
    pub fn compare(&self, other: &Value) -> Ordering {
        match (self, other) {
            (Value::Number(a), Value::Number(b)) => a.partial_cmp(b).unwrap_or_else(|| {
                // NaN sorts below every number, as in jq.
                a.is_nan().cmp(&b.is_nan()).reverse()
            }),
            (Value::String(a), Value::String(b)) => a.cmp(b),
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
                let c = a.sorted_iter().map(|(k, _)| k).cmp(b.sorted_iter().map(|(k, _)| k));
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
            _ => self.type_rank().cmp(&other.type_rank()),
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
        f.write_str(&crate::json::to_string(self))
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
        Value::String(s.into())
    }
}

impl From<String> for Value {
    fn from(s: String) -> Value {
        Value::String(s.into())
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
