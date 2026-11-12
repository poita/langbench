//! Value-level operations: indexing, slicing and the binary operators.

use crate::ast::BinOp;
use crate::error::{Error, Result};
use crate::object::Object;
use crate::value::Value;
use std::cmp::Ordering;
use std::rc::Rc;

/// `t[k]`.
pub(crate) fn index(t: &Value, k: &Value) -> Result<Value> {
    match (t, k) {
        (Value::Object(o), Value::String(s)) => Ok(o.get(s).cloned().unwrap_or(Value::Null)),
        (Value::Null, Value::String(_)) | (Value::Null, Value::Number(_)) => Ok(Value::Null),
        (Value::Array(a), Value::Number(n)) => {
            let mut i = n.trunc();
            if i < 0.0 {
                i += a.len() as f64;
            }
            if i >= 0.0 && i < a.len() as f64 {
                Ok(a[i as usize].clone())
            } else {
                Ok(Value::Null)
            }
        }
        _ => Err(Error::runtime(format!("Cannot index {} with {}", t.type_name(), k.type_name()))),
    }
}

fn bound(v: &Value) -> Result<Option<f64>> {
    match v {
        Value::Null => Ok(None),
        Value::Number(n) => Ok(Some(*n)),
        _ => Err(Error::runtime("Start and end indices of an array slice must be numbers")),
    }
}

/// Resolves slice bounds against a length: negative values count from the end, both are
/// clamped to `[0, len]` and `end >= start`.
fn slice_range(len: usize, from: &Value, to: &Value) -> Result<(usize, usize)> {
    let l = len as f64;
    let mut s = bound(from)?.unwrap_or(0.0);
    let mut e = bound(to)?.unwrap_or(l);
    if s < 0.0 {
        s += l;
    }
    if e < 0.0 {
        e += l;
    }
    let s = s.floor().clamp(0.0, l) as usize;
    let e = e.ceil().clamp(0.0, l) as usize;
    Ok((s, e.max(s)))
}

/// `t[from:to]` (`Null` bounds mean "default").
pub(crate) fn slice(t: &Value, from: &Value, to: &Value) -> Result<Value> {
    match t {
        Value::Null => Ok(Value::Null),
        Value::Array(a) => {
            let (s, e) = slice_range(a.len(), from, to)?;
            Ok(Value::array(a[s..e].to_vec()))
        }
        Value::String(st) => {
            if st.is_ascii() {
                let (s, e) = slice_range(st.len(), from, to)?;
                return Ok(Value::string(&st[s..e]));
            }
            let offsets: Vec<usize> = st.char_indices().map(|(i, _)| i).collect();
            let (s, e) = slice_range(offsets.len(), from, to)?;
            let start = offsets.get(s).copied().unwrap_or(st.len());
            let end = offsets.get(e).copied().unwrap_or(st.len());
            Ok(Value::string(&st[start..end]))
        }
        _ => Err(Error::runtime(format!("Cannot index {} with object", t.type_name()))),
    }
}

fn type_error(a: &Value, b: &Value, what: &str) -> Error {
    Error::runtime(format!("{} and {} cannot be {}", a.type_name(), b.type_name(), what))
}

/// Applies a binary operator.
pub(crate) fn binary(op: BinOp, a: &Value, b: &Value) -> Result<Value> {
    match op {
        BinOp::Add => add(a, b),
        BinOp::Sub => sub(a, b),
        BinOp::Mul => mul(a, b),
        BinOp::Div => div(a, b),
        BinOp::Mod => modulo(a, b),
        BinOp::Eq => Ok(Value::Bool(a.compare(b) == Ordering::Equal)),
        BinOp::Ne => Ok(Value::Bool(a.compare(b) != Ordering::Equal)),
        BinOp::Lt => Ok(Value::Bool(a.compare(b) == Ordering::Less)),
        BinOp::Le => Ok(Value::Bool(a.compare(b) != Ordering::Greater)),
        BinOp::Gt => Ok(Value::Bool(a.compare(b) == Ordering::Greater)),
        BinOp::Ge => Ok(Value::Bool(a.compare(b) != Ordering::Less)),
    }
}

/// `a + b`.
pub(crate) fn add(a: &Value, b: &Value) -> Result<Value> {
    match (a, b) {
        (Value::Null, x) | (x, Value::Null) => Ok(x.clone()),
        (Value::Number(x), Value::Number(y)) => Ok(Value::Number(x + y)),
        (Value::String(x), Value::String(y)) => {
            let mut s = String::with_capacity(x.len() + y.len());
            s.push_str(x);
            s.push_str(y);
            Ok(Value::string(s))
        }
        (Value::Array(x), Value::Array(y)) => {
            let mut v = Vec::with_capacity(x.len() + y.len());
            v.extend(x.iter().cloned());
            v.extend(y.iter().cloned());
            Ok(Value::array(v))
        }
        (Value::Object(x), Value::Object(y)) => Ok(Value::object(x.merged(y))),
        _ => Err(type_error(a, b, "added")),
    }
}

fn sub(a: &Value, b: &Value) -> Result<Value> {
    match (a, b) {
        (Value::Number(x), Value::Number(y)) => Ok(Value::Number(x - y)),
        (Value::Array(x), Value::Array(y)) => {
            Ok(Value::array(x.iter().filter(|e| !y.iter().any(|r| r == *e)).cloned().collect()))
        }
        _ => Err(type_error(a, b, "subtracted")),
    }
}

fn repeat(s: &str, n: f64) -> Value {
    if n < 0.0 || n.is_nan() {
        Value::Null
    } else {
        Value::string(s.repeat(n.trunc() as usize))
    }
}

fn mul(a: &Value, b: &Value) -> Result<Value> {
    match (a, b) {
        (Value::Number(x), Value::Number(y)) => Ok(Value::Number(x * y)),
        (Value::String(s), Value::Number(n)) | (Value::Number(n), Value::String(s)) => Ok(repeat(s, *n)),
        (Value::Object(x), Value::Object(y)) => Ok(Value::object(x.deep_merged(y))),
        _ => Err(type_error(a, b, "multiplied")),
    }
}

fn div(a: &Value, b: &Value) -> Result<Value> {
    match (a, b) {
        (Value::Number(x), Value::Number(y)) => {
            if *y == 0.0 {
                Err(type_error(a, b, "divided because the divisor is zero"))
            } else {
                Ok(Value::Number(x / y))
            }
        }
        (Value::String(x), Value::String(y)) => Ok(Value::array(split(x, y))),
        _ => Err(type_error(a, b, "divided")),
    }
}

fn split(s: &str, sep: &str) -> Vec<Value> {
    if s.is_empty() {
        Vec::new()
    } else if sep.is_empty() {
        s.chars().map(|c| Value::string(c.to_string())).collect()
    } else {
        s.split(sep).map(Value::from).collect()
    }
}

fn modulo(a: &Value, b: &Value) -> Result<Value> {
    match (a, b) {
        (Value::Number(x), Value::Number(y)) => {
            let (x, y) = (x.trunc() as i64, y.trunc() as i64);
            if y == 0 {
                Err(type_error(a, b, "divided because the divisor is zero"))
            } else {
                Ok(Value::Number(x.wrapping_rem(y) as f64))
            }
        }
        _ => Err(type_error(a, b, "divided")),
    }
}

/// Accumulator for `add`: sums a sequence of values with `+` semantics in time linear in the
/// total size, by appending in place instead of re-copying the running result.
pub(crate) enum Adder {
    Null,
    Num(f64),
    Str(String),
    Arr(Vec<Value>),
    Obj(Object),
    Other(Value),
}

impl Adder {
    pub(crate) fn push(&mut self, x: &Value) -> Result<()> {
        if matches!(x, Value::Null) {
            return Ok(());
        }
        match (&mut *self, x) {
            (Adder::Null, _) => {
                *self = match x {
                    Value::Number(n) => Adder::Num(*n),
                    Value::String(s) => Adder::Str(s.to_string()),
                    Value::Array(a) => Adder::Arr(a.to_vec()),
                    Value::Object(o) => Adder::Obj((**o).clone()),
                    other => Adder::Other(other.clone()),
                }
            }
            (Adder::Num(n), Value::Number(y)) => *n += y,
            (Adder::Str(s), Value::String(y)) => s.push_str(y),
            (Adder::Arr(v), Value::Array(y)) => v.extend(y.iter().cloned()),
            (Adder::Obj(o), Value::Object(y)) => {
                for (k, v) in y.iter() {
                    o.insert(k.clone(), v.clone());
                }
            }
            _ => {
                let cur = std::mem::replace(self, Adder::Null).finish();
                return Err(type_error(&cur, x, "added"));
            }
        }
        Ok(())
    }

    pub(crate) fn finish(self) -> Value {
        match self {
            Adder::Null => Value::Null,
            Adder::Num(n) => Value::Number(n),
            Adder::Str(s) => Value::String(Rc::from(s)),
            Adder::Arr(v) => Value::array(v),
            Adder::Obj(o) => Value::object(o),
            Adder::Other(v) => v,
        }
    }
}
