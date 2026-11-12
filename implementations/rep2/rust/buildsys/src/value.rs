//! KBL values: strings, integers, booleans and lists, with the language's
//! total order and deep equality.

use std::cmp::Ordering;
use std::hash::{Hash, Hasher};
use std::rc::Rc;

use crate::ast::Bytes;

/// A KBL value. Strings and lists are reference counted, so copying a value
/// is O(1).
#[derive(Debug, Clone)]
pub enum Value {
    /// A byte string.
    Str(Bytes),
    /// A signed 64-bit integer.
    Int(i64),
    /// A boolean.
    Bool(bool),
    /// An ordered list of values.
    List(Rc<Vec<Value>>),
}

impl Value {
    /// A string value.
    pub fn str(b: impl Into<Vec<u8>>) -> Value {
        Value::Str(Rc::new(b.into()))
    }

    /// A list value.
    pub fn list(v: Vec<Value>) -> Value {
        Value::List(Rc::new(v))
    }

    /// The type name used in error messages: `str`, `int`, `bool` or `list`.
    pub fn type_name(&self) -> &'static str {
        match self {
            Value::Str(_) => "str",
            Value::Int(_) => "int",
            Value::Bool(_) => "bool",
            Value::List(_) => "list",
        }
    }

    fn rank(&self) -> u8 {
        match self {
            Value::Bool(_) => 0,
            Value::Int(_) => 1,
            Value::Str(_) => 2,
            Value::List(_) => 3,
        }
    }

    /// The bytes of a `str` value (empty for any other type).
    pub fn as_bytes(&self) -> &[u8] {
        match self {
            Value::Str(s) => s,
            _ => &[],
        }
    }

    /// The integer of an `int` value (0 for any other type).
    pub fn as_int(&self) -> i64 {
        match self {
            Value::Int(i) => *i,
            _ => 0,
        }
    }

    /// The elements of a `list` value (empty for any other type).
    pub fn as_list(&self) -> &[Value] {
        match self {
            Value::List(l) => l,
            _ => &[],
        }
    }
}

impl PartialEq for Value {
    fn eq(&self, other: &Value) -> bool {
        self.cmp(other) == Ordering::Equal
    }
}

impl Eq for Value {}

impl PartialOrd for Value {
    fn partial_cmp(&self, other: &Value) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for Value {
    fn cmp(&self, other: &Value) -> Ordering {
        match (self, other) {
            (Value::Bool(a), Value::Bool(b)) => a.cmp(b),
            (Value::Int(a), Value::Int(b)) => a.cmp(b),
            (Value::Str(a), Value::Str(b)) => a.as_slice().cmp(b.as_slice()),
            (Value::List(a), Value::List(b)) => a.as_slice().cmp(b.as_slice()),
            _ => self.rank().cmp(&other.rank()),
        }
    }
}

impl Hash for Value {
    fn hash<H: Hasher>(&self, state: &mut H) {
        self.rank().hash(state);
        match self {
            Value::Bool(b) => b.hash(state),
            Value::Int(i) => i.hash(state),
            Value::Str(s) => s.hash(state),
            Value::List(l) => {
                l.len().hash(state);
                for v in l.iter() {
                    v.hash(state);
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn total_order() {
        let vals = [
            Value::Bool(false),
            Value::Bool(true),
            Value::Int(-1),
            Value::Int(5),
            Value::str("a"),
            Value::str("ab"),
            Value::str("b"),
            Value::list(vec![]),
            Value::list(vec![Value::Int(1)]),
            Value::list(vec![Value::Int(1), Value::Int(0)]),
            Value::list(vec![Value::Int(2)]),
        ];
        for w in vals.windows(2) {
            assert!(w[0] < w[1], "{:?} < {:?}", w[0], w[1]);
        }
    }

    #[test]
    fn deep_equality() {
        assert_eq!(
            Value::list(vec![Value::str("a"), Value::list(vec![Value::Int(1)])]),
            Value::list(vec![Value::str("a"), Value::list(vec![Value::Int(1)])])
        );
        assert_ne!(Value::Int(1), Value::Bool(true));
        assert_ne!(Value::str("1"), Value::Int(1));
    }
}
