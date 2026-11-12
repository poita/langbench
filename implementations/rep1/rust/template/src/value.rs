//! Runtime values: the [`Value`] type, the insertion-ordered [`Dict`],
//! printing (`str`/`repr`) and the basic protocols (truthiness, equality,
//! subscripting, sequence view).
//!
//! Values are cheap to clone: strings, lists, dicts and macros are
//! reference-counted, so binding, passing and returning a value never copies
//! its contents.

use crate::ast::MacroDef;
use crate::error::{Error, Result};
use crate::scope::{Rendering, Scope};
use std::collections::HashMap;
use std::fmt::Write;
use std::ops::Deref;
use std::rc::Rc;

/// A template value.
#[derive(Clone, Debug)]
pub enum Value {
    /// The undefined value (unknown name, missed lookup, ...). Almost every
    /// use of it is an error.
    Undefined,
    /// `none`.
    None,
    /// `true` / `false`. Behaves as the integer 1/0 except when printed.
    Bool(bool),
    /// A 64-bit signed integer.
    Int(i64),
    /// An IEEE double.
    Float(f64),
    /// A string (a sequence of Unicode code points).
    Str(Rc<str>),
    /// A list.
    List(Rc<Vec<Value>>),
    /// An insertion-ordered dictionary with string keys.
    Dict(Rc<Dict>),
    /// A macro closure.
    Macro(Rc<MacroVal>),
    /// The `super` callable bound inside a block body.
    Super(Rc<SuperRef>),
    /// The built-in `range` function.
    Range,
}

/// A macro together with the scope it was defined in.
pub struct MacroVal {
    pub(crate) def: Rc<MacroDef>,
    pub(crate) scope: Rc<Scope>,
    pub(crate) rendering: Rc<Rendering>,
}

impl std::fmt::Debug for MacroVal {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "<macro {}>", self.def.name)
    }
}

/// The value bound to `super` in a block body: which entry of which block's
/// chain is currently being rendered.
pub struct SuperRef {
    pub(crate) rendering: Rc<Rendering>,
    pub(crate) name: Rc<str>,
    pub(crate) index: usize,
}

impl std::fmt::Debug for SuperRef {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "<super {}>", self.name)
    }
}

const INDEX_THRESHOLD: usize = 8;

/// An insertion-ordered map from string keys to values.
///
/// Small dictionaries are searched linearly; once a dictionary grows past a
/// handful of entries a hash index is built so lookups stay O(1).
#[derive(Clone, Debug, Default)]
pub struct Dict {
    entries: Vec<(Rc<str>, Value)>,
    index: Option<HashMap<Rc<str>, usize>>,
}

impl Dict {
    /// Creates an empty dictionary.
    pub fn new() -> Self {
        Dict::default()
    }

    /// Number of entries.
    pub fn len(&self) -> usize {
        self.entries.len()
    }

    /// Whether the dictionary has no entries.
    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    /// Looks up a key.
    pub fn get(&self, key: &str) -> Option<&Value> {
        match &self.index {
            Some(index) => index.get(key).map(|&i| &self.entries[i].1),
            None => self.entries.iter().find(|(k, _)| &**k == key).map(|(_, v)| v),
        }
    }

    /// Whether the key is present.
    pub fn contains_key(&self, key: &str) -> bool {
        self.get(key).is_some()
    }

    /// Inserts a key, replacing the value (and keeping the position) if the
    /// key already exists.
    pub fn insert(&mut self, key: Rc<str>, value: Value) {
        let existing = match &self.index {
            Some(index) => index.get(&*key).copied(),
            None => self.entries.iter().position(|(k, _)| *k == key),
        };
        if let Some(i) = existing {
            self.entries[i].1 = value;
            return;
        }
        if let Some(index) = &mut self.index {
            index.insert(key.clone(), self.entries.len());
        }
        self.entries.push((key, value));
        if self.index.is_none() && self.entries.len() > INDEX_THRESHOLD {
            self.index = Some(
                self.entries.iter().enumerate().map(|(i, (k, _))| (k.clone(), i)).collect(),
            );
        }
    }

    /// Iterates over `(key, value)` pairs in insertion order.
    pub fn iter(&self) -> impl Iterator<Item = (&Rc<str>, &Value)> {
        self.entries.iter().map(|(k, v)| (k, v))
    }

    /// Iterates over the keys in insertion order.
    pub fn keys(&self) -> impl Iterator<Item = &Rc<str>> {
        self.entries.iter().map(|(k, _)| k)
    }
}

/// The sequence view of a value (see [`Value::sequence`]): borrowed from a
/// list without copying, or built for dicts and strings.
pub enum Seq {
    /// The elements of a list, shared.
    Shared(Rc<Vec<Value>>),
    /// A freshly built sequence (dict keys, string characters).
    Owned(Vec<Value>),
}

impl Deref for Seq {
    type Target = [Value];
    fn deref(&self) -> &[Value] {
        match self {
            Seq::Shared(v) => v,
            Seq::Owned(v) => v,
        }
    }
}

impl Seq {
    /// Converts into an owned vector (copies if shared).
    pub fn into_vec(self) -> Vec<Value> {
        match self {
            Seq::Shared(v) => (*v).clone(),
            Seq::Owned(v) => v,
        }
    }
}

/// The characters Jinja-style whitespace handling recognises.
pub(crate) fn is_ws(c: char) -> bool {
    matches!(c, ' ' | '\t' | '\n' | '\r' | '\x0c' | '\x0b')
}

impl Value {
    /// Builds a string value.
    pub fn str(s: impl AsRef<str>) -> Value {
        Value::Str(Rc::from(s.as_ref()))
    }

    /// Builds a list value.
    pub fn list(items: Vec<Value>) -> Value {
        Value::List(Rc::new(items))
    }

    /// Builds a dict value.
    pub fn dict(d: Dict) -> Value {
        Value::Dict(Rc::new(d))
    }

    /// A short name of the value's kind, for diagnostics.
    pub fn kind_name(&self) -> &'static str {
        match self {
            Value::Undefined => "undefined",
            Value::None => "none",
            Value::Bool(_) => "boolean",
            Value::Int(_) => "integer",
            Value::Float(_) => "float",
            Value::Str(_) => "string",
            Value::List(_) => "list",
            Value::Dict(_) => "dict",
            Value::Macro(_) | Value::Super(_) | Value::Range => "callable",
        }
    }

    /// Whether this is the undefined value.
    pub fn is_undefined(&self) -> bool {
        matches!(self, Value::Undefined)
    }

    /// Fails with an `undefined` error if this is the undefined value.
    pub fn defined(&self) -> Result<&Value> {
        if self.is_undefined() {
            Err(Error::undefined("use of an undefined value"))
        } else {
            Ok(self)
        }
    }

    /// Truthiness; testing the undefined value is an `undefined` error.
    pub fn truthy(&self) -> Result<bool> {
        Ok(match self {
            Value::Undefined => return Err(Error::undefined("truthiness of an undefined value")),
            Value::None => false,
            Value::Bool(b) => *b,
            Value::Int(i) => *i != 0,
            Value::Float(f) => *f != 0.0,
            Value::Str(s) => !s.is_empty(),
            Value::List(l) => !l.is_empty(),
            Value::Dict(d) => !d.is_empty(),
            Value::Macro(_) | Value::Super(_) | Value::Range => true,
        })
    }

    /// The sequence view: a list's elements, a dict's keys, a string's
    /// characters. Anything else is a `type` error (`undefined` for the
    /// undefined value).
    pub fn sequence(&self) -> Result<Seq> {
        match self {
            Value::List(l) => Ok(Seq::Shared(l.clone())),
            Value::Dict(d) => Ok(Seq::Owned(d.keys().map(|k| Value::Str(k.clone())).collect())),
            Value::Str(s) => Ok(Seq::Owned(
                s.chars().map(|c| Value::Str(Rc::from(c.encode_utf8(&mut [0; 4]) as &str))).collect(),
            )),
            Value::Undefined => Err(Error::undefined("iterating an undefined value")),
            other => Err(Error::type_error(format!("{} is not a sequence", other.kind_name()))),
        }
    }

    /// Attribute access `a.NAME`.
    pub fn get_attr(&self, name: &str) -> Result<Value> {
        match self {
            Value::Undefined => Err(Error::undefined("attribute of an undefined value")),
            Value::Dict(d) => Ok(d.get(name).cloned().unwrap_or(Value::Undefined)),
            _ => Ok(Value::Undefined),
        }
    }

    /// Subscript access `a[key]`.
    pub fn get_item(&self, key: &Value) -> Result<Value> {
        self.defined()?;
        key.defined()?;
        Ok(match (self, key) {
            (Value::Dict(d), Value::Str(k)) => d.get(k).cloned().unwrap_or(Value::Undefined),
            (Value::List(l), k) => match as_index(k) {
                Some(i) => resolve_index(i, l.len()).map(|i| l[i].clone()).unwrap_or(Value::Undefined),
                None => Value::Undefined,
            },
            (Value::Str(s), k) => match as_index(k) {
                Some(i) => str_char_at(s, i).map(|c| Value::str(c.encode_utf8(&mut [0; 4]))).unwrap_or(Value::Undefined),
                None => Value::Undefined,
            },
            _ => Value::Undefined,
        })
    }

    /// Writes the printed form (`{{ value }}`) to `out`.
    pub fn write_str(&self, out: &mut String) -> Result<()> {
        match self {
            Value::Str(s) => out.push_str(s),
            Value::Undefined => return Err(Error::undefined("printing an undefined value")),
            _ => self.write_repr(out)?,
        }
        Ok(())
    }

    /// Writes the `repr` form (strings quoted) to `out`.
    pub fn write_repr(&self, out: &mut String) -> Result<()> {
        match self {
            Value::Undefined => return Err(Error::undefined("printing an undefined value")),
            Value::None => out.push_str("None"),
            Value::Bool(true) => out.push_str("True"),
            Value::Bool(false) => out.push_str("False"),
            Value::Int(i) => {
                let _ = write!(out, "{}", i);
            }
            Value::Float(f) => out.push_str(&format_float(*f)),
            Value::Str(s) => write_str_repr(s, out),
            Value::List(l) => {
                out.push('[');
                for (i, v) in l.iter().enumerate() {
                    if i > 0 {
                        out.push_str(", ");
                    }
                    v.write_repr(out)?;
                }
                out.push(']');
            }
            Value::Dict(d) => {
                out.push('{');
                for (i, (k, v)) in d.iter().enumerate() {
                    if i > 0 {
                        out.push_str(", ");
                    }
                    write_str_repr(k, out);
                    out.push_str(": ");
                    v.write_repr(out)?;
                }
                out.push('}');
            }
            Value::Macro(m) => {
                let _ = write!(out, "<macro {}>", m.def.name);
            }
            Value::Super(_) => out.push_str("<super>"),
            Value::Range => out.push_str("<built-in range>"),
        }
        Ok(())
    }

    /// The printed form as a string (`undefined` is an error).
    pub fn to_display(&self) -> Result<Rc<str>> {
        if let Value::Str(s) = self {
            return Ok(s.clone());
        }
        let mut out = String::new();
        self.write_str(&mut out)?;
        Ok(Rc::from(out))
    }

    /// Template equality (`==`): numbers numerically (booleans are 0/1),
    /// strings, lists and dicts structurally, `none == none`; everything
    /// else is unequal. The caller rejects undefined operands first.
    pub fn loose_eq(&self, other: &Value) -> bool {
        match (self, other) {
            (Value::None, Value::None) => true,
            (Value::Str(a), Value::Str(b)) => a == b,
            (Value::List(a), Value::List(b)) => {
                Rc::ptr_eq(a, b) || (a.len() == b.len() && a.iter().zip(b.iter()).all(|(x, y)| x.loose_eq(y)))
            }
            (Value::Dict(a), Value::Dict(b)) => {
                Rc::ptr_eq(a, b)
                    || (a.len() == b.len()
                        && a.iter().all(|(k, v)| b.get(k).is_some_and(|w| v.loose_eq(w))))
            }
            (a, b) => match (Num::of(a), Num::of(b)) {
                (Some(x), Some(y)) => x.num_eq(y),
                _ => false,
            },
        }
    }
}

/// A numeric operand: integer or float (booleans count as integers).
#[derive(Clone, Copy, Debug)]
pub enum Num {
    /// An exact integer.
    I(i64),
    /// A double.
    F(f64),
}

impl Num {
    /// Interprets a value as a number, if it is an integer, float or boolean.
    pub fn of(v: &Value) -> Option<Num> {
        match v {
            Value::Int(i) => Some(Num::I(*i)),
            Value::Bool(b) => Some(Num::I(*b as i64)),
            Value::Float(f) => Some(Num::F(*f)),
            _ => None,
        }
    }

    /// The value as a double.
    pub fn as_f64(self) -> f64 {
        match self {
            Num::I(i) => i as f64,
            Num::F(f) => f,
        }
    }

    /// Numeric equality.
    pub fn num_eq(self, other: Num) -> bool {
        match (self, other) {
            (Num::I(a), Num::I(b)) => a == b,
            (a, b) => a.as_f64() == b.as_f64(),
        }
    }

    /// Numeric ordering (`None` only for NaN).
    pub fn num_cmp(self, other: Num) -> Option<std::cmp::Ordering> {
        match (self, other) {
            (Num::I(a), Num::I(b)) => Some(a.cmp(&b)),
            (a, b) => a.as_f64().partial_cmp(&b.as_f64()),
        }
    }
}

fn as_index(k: &Value) -> Option<i64> {
    match k {
        Value::Int(i) => Some(*i),
        Value::Bool(b) => Some(*b as i64),
        _ => None,
    }
}

fn resolve_index(i: i64, len: usize) -> Option<usize> {
    let idx = if i < 0 { i.checked_add(len as i64)? } else { i };
    if idx >= 0 && (idx as u64) < len as u64 {
        Some(idx as usize)
    } else {
        None
    }
}

fn str_char_at(s: &str, i: i64) -> Option<char> {
    if i >= 0 {
        s.chars().nth(i as usize)
    } else {
        let len = s.chars().count();
        resolve_index(i, len).and_then(|j| s.chars().nth(j))
    }
}

fn write_str_repr(s: &str, out: &mut String) {
    let quote = if s.contains('\'') && !s.contains('"') { '"' } else { '\'' };
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

/// Formats a double as the printed form: the shortest round-tripping digits,
/// positional notation for decimal exponents in `-4..16`, otherwise
/// scientific (`1e+16`, `1.5e-07`).
pub fn format_float(x: f64) -> String {
    if x.is_nan() {
        return "nan".into();
    }
    if x.is_infinite() {
        return if x < 0.0 { "-inf".into() } else { "inf".into() };
    }
    if x == 0.0 {
        return if x.is_sign_negative() { "-0.0".into() } else { "0.0".into() };
    }
    // `{:e}` yields the shortest round-tripping digits, e.g. "1.2345e-7".
    let sci = format!("{:e}", x.abs());
    let (mant, exp) = sci.split_once('e').expect("exponent form");
    let exp: i32 = exp.parse().expect("exponent");
    let digits: String = mant.chars().filter(|&c| c != '.').collect();
    let mut out = String::new();
    if x < 0.0 {
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
        let _ = write!(out, "e{}{:02}", if exp < 0 { '-' } else { '+' }, exp.abs());
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn float_formatting() {
        assert_eq!(format_float(3.0), "3.0");
        assert_eq!(format_float(0.5), "0.5");
        assert_eq!(format_float(1e15), "1000000000000000.0");
        assert_eq!(format_float(0.0001), "0.0001");
        assert_eq!(format_float(0.1 + 0.2), "0.30000000000000004");
        assert_eq!(format_float(1e16), "1e+16");
        assert_eq!(format_float(0.00001), "1e-05");
        assert_eq!(format_float(1.5e300), "1.5e+300");
        assert_eq!(format_float(-0.0), "-0.0");
        assert_eq!(format_float(0.0), "0.0");
        assert_eq!(format_float(-2.5), "-2.5");
        assert_eq!(format_float(123456.789), "123456.789");
    }

    #[test]
    fn repr_quotes() {
        let mut s = String::new();
        Value::str("it's").write_repr(&mut s).unwrap();
        assert_eq!(s, "\"it's\"");
        s.clear();
        Value::str("a'b\"c\n").write_repr(&mut s).unwrap();
        assert_eq!(s, "'a\\'b\"c\\n'");
    }

    #[test]
    fn dict_keeps_order_and_replaces() {
        let mut d = Dict::new();
        for i in 0..20 {
            d.insert(Rc::from(format!("k{i}")), Value::Int(i));
        }
        d.insert(Rc::from("k3"), Value::Int(99));
        assert_eq!(d.len(), 20);
        assert!(matches!(d.get("k3"), Some(Value::Int(99))));
        assert_eq!(d.keys().nth(3).map(|k| &**k), Some("k3"));
        assert!(d.get("nope").is_none());
    }

    #[test]
    fn indexing() {
        let l = Value::list(vec![Value::Int(1), Value::Int(2)]);
        assert!(matches!(l.get_item(&Value::Int(-1)).unwrap(), Value::Int(2)));
        assert!(l.get_item(&Value::Int(2)).unwrap().is_undefined());
        assert!(l.get_item(&Value::Float(1.0)).unwrap().is_undefined());
        assert!(Value::Undefined.get_item(&Value::Int(0)).is_err());
    }
}
