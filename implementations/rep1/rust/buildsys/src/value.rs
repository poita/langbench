//! KBL values: `str`, `int`, `bool` and `list`, with their total order.
//!
//! Strings and lists are reference counted, so copying a value is O(1).

use std::cmp::Ordering;
use std::rc::Rc;

/// A KBL value.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum Value {
    Str(Rc<Vec<u8>>),
    Int(i64),
    Bool(bool),
    List(Rc<Vec<Value>>),
}

impl Value {
    /// Builds a `str` value.
    pub fn str(bytes: impl Into<Vec<u8>>) -> Value {
        Value::Str(Rc::new(bytes.into()))
    }

    /// Builds a `list` value.
    pub fn list(items: Vec<Value>) -> Value {
        Value::List(Rc::new(items))
    }

    /// The type token used in error messages.
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
}

impl PartialOrd for Value {
    fn partial_cmp(&self, other: &Value) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

/// The total order: `bool` < `int` < `str` < `list`, then by content.
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

#[cfg(test)]
mod tests {
    use super::*;

    fn s(x: &str) -> Value {
        Value::str(x)
    }

    #[test]
    fn ordering_across_types() {
        let order = vec![
            Value::Bool(false),
            Value::Bool(true),
            Value::Int(-5),
            Value::Int(3),
            s(""),
            s("a"),
            s("ab"),
            s("b"),
            Value::list(vec![]),
            Value::list(vec![Value::Int(9)]),
            Value::list(vec![s("a")]),
        ];
        for i in 0..order.len() {
            for j in 0..order.len() {
                assert_eq!(order[i].cmp(&order[j]), i.cmp(&j), "{i} {j}");
            }
        }
    }

    #[test]
    fn deep_equality() {
        let a = Value::list(vec![Value::Int(1), Value::list(vec![s("x")])]);
        let b = Value::list(vec![Value::Int(1), Value::list(vec![s("x")])]);
        assert_eq!(a, b);
        assert_ne!(Value::Int(1), Value::Bool(true));
        assert_ne!(s("1"), Value::Int(1));
    }
}
