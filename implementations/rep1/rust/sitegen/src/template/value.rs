//! Template values.

use std::collections::HashMap;
use std::fmt;
use std::rc::{Rc, Weak};

use super::ast::MacroDef;
use super::eval::Scope;

/// An insertion-ordered string-keyed mapping.
///
/// Lookups are linear for small dictionaries and hashed for larger ones.
#[derive(Clone, Default)]
pub struct Dict {
    entries: Vec<(Rc<str>, Value)>,
    index: Option<HashMap<Rc<str>, usize>>,
}

const INDEX_THRESHOLD: usize = 12;

impl Dict {
    /// An empty dictionary.
    pub fn new() -> Dict {
        Dict::default()
    }

    /// Insert or replace a member. A replaced member keeps its position.
    pub fn insert(&mut self, key: impl Into<Rc<str>>, value: Value) {
        let key: Rc<str> = key.into();
        if let Some(i) = self.position(&key) {
            self.entries[i].1 = value;
            return;
        }
        let i = self.entries.len();
        if let Some(index) = &mut self.index {
            index.insert(key.clone(), i);
        }
        self.entries.push((key, value));
        if self.index.is_none() && self.entries.len() > INDEX_THRESHOLD {
            self.index = Some(
                self.entries
                    .iter()
                    .enumerate()
                    .map(|(i, (k, _))| (k.clone(), i))
                    .collect(),
            );
        }
    }

    fn position(&self, key: &str) -> Option<usize> {
        match &self.index {
            Some(index) => index.get(key).copied(),
            None => self.entries.iter().position(|(k, _)| &**k == key),
        }
    }

    /// The member called `key`, if any.
    pub fn get(&self, key: &str) -> Option<&Value> {
        self.position(key).map(|i| &self.entries[i].1)
    }

    /// Number of members.
    pub fn len(&self) -> usize {
        self.entries.len()
    }

    /// True when there are no members.
    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    pub(crate) fn keys(&self) -> impl Iterator<Item = &Rc<str>> {
        self.entries.iter().map(|(k, _)| k)
    }

    /// Iterate over the members in insertion order.
    pub fn iter(&self) -> impl Iterator<Item = (&str, &Value)> {
        self.entries.iter().map(|(k, v)| (&**k, v))
    }
}

impl<K: Into<Rc<str>>> FromIterator<(K, Value)> for Dict {
    fn from_iter<I: IntoIterator<Item = (K, Value)>>(iter: I) -> Dict {
        let mut d = Dict::new();
        for (k, v) in iter {
            d.insert(k, v);
        }
        d
    }
}

/// A macro together with the scope it was defined in.
pub struct MacroValue {
    pub(crate) def: Rc<MacroDef>,
    pub(crate) scope: Weak<Scope>,
}

/// A reference to `super()` inside a block body.
pub struct SuperRef {
    pub(crate) name: Rc<str>,
    pub(crate) index: usize,
}

/// A value of the template language.
///
/// Strings, lists and dictionaries are reference counted, so cloning a value
/// is cheap and values can be shared between pages.
#[derive(Clone)]
pub enum Value {
    /// The undefined value (an unbound name or a missing member).
    Undefined,
    /// `none`.
    None,
    /// A boolean.
    Bool(bool),
    /// An integer.
    Int(i64),
    /// A float.
    Float(f64),
    /// A string.
    Str(Rc<str>),
    /// A list.
    List(Rc<Vec<Value>>),
    /// An insertion-ordered dictionary.
    Dict(Rc<Dict>),
    /// A macro (not constructible from outside the engine).
    Macro(Rc<MacroValue>),
    /// `super` inside a block (not constructible from outside the engine).
    Super(Rc<SuperRef>),
}

impl Value {
    /// A string value.
    pub fn str(s: impl AsRef<str>) -> Value {
        Value::Str(Rc::from(s.as_ref()))
    }

    /// A list value.
    pub fn list(items: Vec<Value>) -> Value {
        Value::List(Rc::new(items))
    }

    /// A dictionary value.
    pub fn dict(d: Dict) -> Value {
        Value::Dict(Rc::new(d))
    }

    pub(crate) fn is_undefined(&self) -> bool {
        matches!(self, Value::Undefined)
    }

    pub(crate) fn kind_name(&self) -> &'static str {
        match self {
            Value::Undefined => "undefined",
            Value::None => "none",
            Value::Bool(_) => "boolean",
            Value::Int(_) => "integer",
            Value::Float(_) => "float",
            Value::Str(_) => "string",
            Value::List(_) => "list",
            Value::Dict(_) => "dict",
            Value::Macro(_) => "macro",
            Value::Super(_) => "super",
        }
    }

    /// The string form used when a value is printed with `{{ }}`.
    /// The undefined value has no string form and yields `None`.
    pub fn to_output_string(&self) -> Option<String> {
        let mut s = String::new();
        if self.write_to(&mut s, false) {
            Some(s)
        } else {
            None
        }
    }

    /// Write the printed form; `repr` selects the quoted form used inside
    /// containers. Returns false for the undefined value.
    pub(crate) fn write_to(&self, out: &mut String, repr: bool) -> bool {
        match self {
            Value::Undefined => return false,
            Value::None => out.push_str("None"),
            Value::Bool(true) => out.push_str("True"),
            Value::Bool(false) => out.push_str("False"),
            Value::Int(i) => out.push_str(&i.to_string()),
            Value::Float(f) => out.push_str(&format_float(*f)),
            Value::Str(s) => {
                if repr {
                    write_repr_string(out, s);
                } else {
                    out.push_str(s);
                }
            }
            Value::List(items) => {
                out.push('[');
                for (i, v) in items.iter().enumerate() {
                    if i > 0 {
                        out.push_str(", ");
                    }
                    if !v.write_to(out, true) {
                        return false;
                    }
                }
                out.push(']');
            }
            Value::Dict(d) => {
                out.push('{');
                for (i, (k, v)) in d.iter().enumerate() {
                    if i > 0 {
                        out.push_str(", ");
                    }
                    write_repr_string(out, k);
                    out.push_str(": ");
                    if !v.write_to(out, true) {
                        return false;
                    }
                }
                out.push('}');
            }
            Value::Macro(_) => out.push_str("<macro>"),
            Value::Super(_) => out.push_str("<super>"),
        }
        true
    }
}

impl fmt::Debug for Value {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self.to_output_string() {
            Some(s) => write!(f, "{}({})", self.kind_name(), s),
            None => write!(f, "undefined"),
        }
    }
}

impl From<&str> for Value {
    fn from(s: &str) -> Value {
        Value::str(s)
    }
}
impl From<String> for Value {
    fn from(s: String) -> Value {
        Value::Str(Rc::from(s))
    }
}
impl From<i64> for Value {
    fn from(i: i64) -> Value {
        Value::Int(i)
    }
}
impl From<usize> for Value {
    fn from(i: usize) -> Value {
        Value::Int(i as i64)
    }
}
impl From<f64> for Value {
    fn from(f: f64) -> Value {
        Value::Float(f)
    }
}
impl From<bool> for Value {
    fn from(b: bool) -> Value {
        Value::Bool(b)
    }
}
impl From<Vec<Value>> for Value {
    fn from(v: Vec<Value>) -> Value {
        Value::list(v)
    }
}
impl From<Dict> for Value {
    fn from(d: Dict) -> Value {
        Value::dict(d)
    }
}

fn write_repr_string(out: &mut String, s: &str) {
    let quote = if s.contains('\'') && !s.contains('"') {
        '"'
    } else {
        '\''
    };
    out.push(quote);
    for c in s.chars() {
        match c {
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if c == quote => {
                out.push('\\');
                out.push(c);
            }
            c => out.push(c),
        }
    }
    out.push(quote);
}

/// Format a float the way Python's `repr` does.
pub(crate) fn format_float(f: f64) -> String {
    if f == 0.0 {
        return if f.is_sign_negative() { "-0.0" } else { "0.0" }.to_string();
    }
    if f.is_nan() {
        return "nan".to_string();
    }
    if f.is_infinite() {
        return if f < 0.0 { "-inf" } else { "inf" }.to_string();
    }
    // `{:e}` yields the shortest round-tripping digits: d[.ddd]e[-]X.
    let sci = format!("{:e}", f.abs());
    let (mantissa, exp) = sci.split_once('e').expect("exponent form");
    let exp: i32 = exp.parse().expect("exponent");
    let digits: String = mantissa.chars().filter(|c| *c != '.').collect();
    let mut out = String::new();
    if f < 0.0 {
        out.push('-');
    }
    if (-4..16).contains(&exp) {
        if exp >= 0 {
            let int_len = exp as usize + 1;
            if digits.len() <= int_len {
                out.push_str(&digits);
                for _ in digits.len()..int_len {
                    out.push('0');
                }
                out.push_str(".0");
            } else {
                out.push_str(&digits[..int_len]);
                out.push('.');
                out.push_str(&digits[int_len..]);
            }
        } else {
            out.push_str("0.");
            for _ in 0..(-exp - 1) {
                out.push('0');
            }
            out.push_str(&digits);
        }
    } else {
        out.push_str(&digits[..1]);
        if digits.len() > 1 {
            out.push('.');
            out.push_str(&digits[1..]);
        }
        out.push('e');
        out.push(if exp < 0 { '-' } else { '+' });
        out.push_str(&format!("{:02}", exp.abs()));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn floats() {
        assert_eq!(format_float(3.0), "3.0");
        assert_eq!(format_float(0.5), "0.5");
        assert_eq!(format_float(1e15), "1000000000000000.0");
        assert_eq!(format_float(0.0001), "0.0001");
        assert_eq!(format_float(0.1 + 0.2), "0.30000000000000004");
        assert_eq!(format_float(1e16), "1e+16");
        assert_eq!(format_float(1e-5), "1e-05");
        assert_eq!(format_float(1.5e300), "1.5e+300");
        assert_eq!(format_float(-0.0), "-0.0");
        assert_eq!(format_float(-2.5), "-2.5");
        assert_eq!(format_float(123456.789), "123456.789");
    }

    #[test]
    fn repr() {
        let v = Value::list(vec![
            Value::Int(1),
            Value::str("a"),
            Value::Bool(true),
            Value::None,
            Value::Float(1.5),
            Value::str("it's"),
            Value::dict(
                [("k", Value::list(vec![Value::Float(2.0)]))]
                    .into_iter()
                    .collect(),
            ),
        ]);
        assert_eq!(
            v.to_output_string().unwrap(),
            "[1, 'a', True, None, 1.5, \"it's\", {'k': [2.0]}]"
        );
    }

    #[test]
    fn dict_order_and_replace() {
        let mut d = Dict::new();
        for i in 0..20 {
            d.insert(format!("k{}", i), Value::Int(i));
        }
        d.insert("k3", Value::Int(99));
        assert_eq!(d.len(), 20);
        assert!(matches!(d.get("k3"), Some(Value::Int(99))));
        assert_eq!(d.iter().nth(3).unwrap().0, "k3");
    }
}
