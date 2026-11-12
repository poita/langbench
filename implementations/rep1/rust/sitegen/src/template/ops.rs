//! Operators, comparisons and member access on template values.

use std::cmp::Ordering;
use std::rc::Rc;

use super::ast::{BinOp, CmpOp};
use super::error::{Error, Result};
use super::value::Value;

#[derive(Clone, Copy)]
pub(crate) enum Num {
    I(i64),
    F(f64),
}

impl Num {
    pub fn to_f64(self) -> f64 {
        match self {
            Num::I(i) => i as f64,
            Num::F(f) => f,
        }
    }
}

/// Integers, booleans and floats are numbers.
pub(crate) fn as_num(v: &Value) -> Option<Num> {
    match v {
        Value::Int(i) => Some(Num::I(*i)),
        Value::Bool(b) => Some(Num::I(*b as i64)),
        Value::Float(f) => Some(Num::F(*f)),
        _ => None,
    }
}

fn as_int(v: &Value) -> Option<i64> {
    match v {
        Value::Int(i) => Some(*i),
        Value::Bool(b) => Some(*b as i64),
        _ => None,
    }
}

fn check_defined(l: &Value, r: &Value) -> Result<()> {
    if l.is_undefined() || r.is_undefined() {
        Err(Error::undefined("use of an undefined value in an operator"))
    } else {
        Ok(())
    }
}

fn type_err<T>(what: &str, l: &Value, r: &Value) -> Result<T> {
    Err(Error::type_error(format!(
        "unsupported operand kinds for {}: {} and {}",
        what,
        l.kind_name(),
        r.kind_name()
    )))
}

fn floor_div_i64(a: i64, b: i64) -> i64 {
    let q = a.wrapping_div(b);
    if (a % b != 0) && ((a < 0) != (b < 0)) {
        q - 1
    } else {
        q
    }
}

fn mod_i64(a: i64, b: i64) -> i64 {
    let r = a.wrapping_rem(b);
    if r != 0 && ((r < 0) != (b < 0)) {
        r + b
    } else {
        r
    }
}

fn mod_f64(a: f64, b: f64) -> f64 {
    let r = a % b;
    if r == 0.0 {
        // A zero result takes the sign of the divisor, as in Python.
        r.copysign(b)
    } else if (r < 0.0) != (b < 0.0) {
        r + b
    } else {
        r
    }
}

fn floor_div_f64(a: f64, b: f64) -> f64 {
    // `(a - m) / b` is integral up to rounding error.
    ((a - mod_f64(a, b)) / b).round()
}

pub(crate) fn binary(op: BinOp, l: &Value, r: &Value) -> Result<Value> {
    check_defined(l, r)?;
    match op {
        BinOp::Concat => {
            let mut s = String::new();
            l.write_to(&mut s, false);
            r.write_to(&mut s, false);
            Ok(Value::from(s))
        }
        BinOp::Add => {
            if let (Some(a), Some(b)) = (as_num(l), as_num(r)) {
                return Ok(match (a, b) {
                    (Num::I(a), Num::I(b)) => Value::Int(a.wrapping_add(b)),
                    (a, b) => Value::Float(a.to_f64() + b.to_f64()),
                });
            }
            match (l, r) {
                (Value::Str(a), Value::Str(b)) => {
                    let mut s = String::with_capacity(a.len() + b.len());
                    s.push_str(a);
                    s.push_str(b);
                    Ok(Value::from(s))
                }
                (Value::List(a), Value::List(b)) => {
                    let mut v = Vec::with_capacity(a.len() + b.len());
                    v.extend(a.iter().cloned());
                    v.extend(b.iter().cloned());
                    Ok(Value::list(v))
                }
                _ => type_err("+", l, r),
            }
        }
        BinOp::Sub => match (as_num(l), as_num(r)) {
            (Some(Num::I(a)), Some(Num::I(b))) => Ok(Value::Int(a.wrapping_sub(b))),
            (Some(a), Some(b)) => Ok(Value::Float(a.to_f64() - b.to_f64())),
            _ => type_err("-", l, r),
        },
        BinOp::Mul => {
            if let (Some(a), Some(b)) = (as_num(l), as_num(r)) {
                return Ok(match (a, b) {
                    (Num::I(a), Num::I(b)) => Value::Int(a.wrapping_mul(b)),
                    (a, b) => Value::Float(a.to_f64() * b.to_f64()),
                });
            }
            match (l, r) {
                (Value::Str(s), n) | (n, Value::Str(s)) if as_int(n).is_some() => {
                    let n = as_int(n).unwrap();
                    Ok(Value::from(if n <= 0 {
                        String::new()
                    } else {
                        s.repeat(n as usize)
                    }))
                }
                _ => type_err("*", l, r),
            }
        }
        BinOp::Div => match (as_num(l), as_num(r)) {
            (Some(a), Some(b)) => {
                let b = b.to_f64();
                if b == 0.0 {
                    return Err(Error::type_error("division by zero"));
                }
                Ok(Value::Float(a.to_f64() / b))
            }
            _ => type_err("/", l, r),
        },
        BinOp::FloorDiv => match (as_num(l), as_num(r)) {
            (Some(Num::I(a)), Some(Num::I(b))) => {
                if b == 0 {
                    return Err(Error::type_error("division by zero"));
                }
                Ok(Value::Int(floor_div_i64(a, b)))
            }
            (Some(a), Some(b)) => {
                let b = b.to_f64();
                if b == 0.0 {
                    return Err(Error::type_error("division by zero"));
                }
                Ok(Value::Float(floor_div_f64(a.to_f64(), b)))
            }
            _ => type_err("//", l, r),
        },
        BinOp::Mod => match (as_num(l), as_num(r)) {
            (Some(Num::I(a)), Some(Num::I(b))) => {
                if b == 0 {
                    return Err(Error::type_error("modulo by zero"));
                }
                Ok(Value::Int(mod_i64(a, b)))
            }
            (Some(a), Some(b)) => {
                let b = b.to_f64();
                if b == 0.0 {
                    return Err(Error::type_error("modulo by zero"));
                }
                Ok(Value::Float(mod_f64(a.to_f64(), b)))
            }
            _ => type_err("%", l, r),
        },
        BinOp::Pow => match (as_num(l), as_num(r)) {
            (Some(Num::I(a)), Some(Num::I(b))) => {
                if b >= 0 {
                    Ok(Value::Int(a.wrapping_pow(b.min(u32::MAX as i64) as u32)))
                } else if a == 0 {
                    Err(Error::type_error("zero to a negative power"))
                } else {
                    Ok(Value::Float((a as f64).powf(b as f64)))
                }
            }
            (Some(a), Some(b)) => {
                let (a, b) = (a.to_f64(), b.to_f64());
                if a == 0.0 && b < 0.0 {
                    return Err(Error::type_error("zero to a negative power"));
                }
                Ok(Value::Float(a.powf(b)))
            }
            _ => type_err("**", l, r),
        },
    }
}

pub(crate) fn negate(v: &Value) -> Result<Value> {
    match as_num(v) {
        Some(Num::I(i)) => Ok(Value::Int(i.wrapping_neg())),
        Some(Num::F(f)) => Ok(Value::Float(-f)),
        None if v.is_undefined() => Err(Error::undefined("negating an undefined value")),
        None => Err(Error::type_error("cannot negate a non-number")),
    }
}

pub(crate) fn values_equal(a: &Value, b: &Value) -> bool {
    if let (Some(x), Some(y)) = (as_num(a), as_num(b)) {
        return match (x, y) {
            (Num::I(x), Num::I(y)) => x == y,
            (x, y) => x.to_f64() == y.to_f64(),
        };
    }
    match (a, b) {
        (Value::Str(x), Value::Str(y)) => x == y,
        (Value::None, Value::None) => true,
        (Value::List(x), Value::List(y)) => {
            Rc::ptr_eq(x, y)
                || (x.len() == y.len() && x.iter().zip(y.iter()).all(|(p, q)| values_equal(p, q)))
        }
        (Value::Dict(x), Value::Dict(y)) => {
            Rc::ptr_eq(x, y)
                || (x.len() == y.len()
                    && x.iter()
                        .all(|(k, v)| y.get(k).is_some_and(|w| values_equal(v, w))))
        }
        _ => false,
    }
}

fn order(l: &Value, r: &Value) -> Result<Option<Ordering>> {
    if let (Some(a), Some(b)) = (as_num(l), as_num(r)) {
        return Ok(match (a, b) {
            (Num::I(a), Num::I(b)) => Some(a.cmp(&b)),
            (a, b) => a.to_f64().partial_cmp(&b.to_f64()),
        });
    }
    match (l, r) {
        (Value::Str(a), Value::Str(b)) => Ok(Some(a.as_bytes().cmp(b.as_bytes()))),
        _ => type_err("comparison", l, r),
    }
}

pub(crate) fn compare(op: CmpOp, l: &Value, r: &Value) -> Result<bool> {
    if matches!(op, CmpOp::In | CmpOp::NotIn) {
        // As in Python, the kind of the right operand is examined first:
        // `undefined in 0.1` and `undefined in "text"` are type errors,
        // while `x in undefined` and `undefined in [..]` are undefined errors.
        match r {
            Value::Undefined => return Err(Error::undefined("`in` applied to an undefined value")),
            Value::Str(_) if l.is_undefined() => {
                return Err(Error::type_error(
                    "`in <string>` requires a string as left operand",
                ));
            }
            Value::Str(_) | Value::List(_) | Value::Dict(_) => {}
            _ => return type_err("in", l, r),
        }
    }
    check_defined(l, r)?;
    match op {
        CmpOp::Eq => Ok(values_equal(l, r)),
        CmpOp::Ne => Ok(!values_equal(l, r)),
        CmpOp::Lt => Ok(order(l, r)? == Some(Ordering::Less)),
        CmpOp::Le => Ok(matches!(
            order(l, r)?,
            Some(Ordering::Less | Ordering::Equal)
        )),
        CmpOp::Gt => Ok(order(l, r)? == Some(Ordering::Greater)),
        CmpOp::Ge => Ok(matches!(
            order(l, r)?,
            Some(Ordering::Greater | Ordering::Equal)
        )),
        CmpOp::In => contains(l, r),
        CmpOp::NotIn => Ok(!contains(l, r)?),
    }
}

fn contains(needle: &Value, haystack: &Value) -> Result<bool> {
    match haystack {
        Value::Str(h) => match needle {
            Value::Str(n) => Ok(h.contains(&**n)),
            _ => type_err("in", needle, haystack),
        },
        Value::Dict(d) => Ok(matches!(needle, Value::Str(k) if d.get(k).is_some())),
        Value::List(items) => Ok(items.iter().any(|x| values_equal(x, needle))),
        _ => type_err("in", needle, haystack),
    }
}

/// Truthiness; the undefined value is an error.
pub(crate) fn truthy(v: &Value) -> Result<bool> {
    Ok(match v {
        Value::Undefined => return Err(Error::undefined("truth value of an undefined value")),
        Value::None => false,
        Value::Bool(b) => *b,
        Value::Int(i) => *i != 0,
        Value::Float(f) => *f != 0.0,
        Value::Str(s) => !s.is_empty(),
        Value::List(l) => !l.is_empty(),
        Value::Dict(d) => !d.is_empty(),
        Value::Macro(_) | Value::Super(_) => true,
    })
}

/// `a.name`.
pub(crate) fn get_attr(a: &Value, name: &str) -> Result<Value> {
    match a {
        Value::Undefined => Err(Error::undefined(format!(
            "attribute `{}` of an undefined value",
            name
        ))),
        Value::Dict(d) => Ok(d.get(name).cloned().unwrap_or(Value::Undefined)),
        _ => Ok(Value::Undefined),
    }
}

/// `a[key]`.
pub(crate) fn get_item(a: &Value, key: &Value) -> Result<Value> {
    if a.is_undefined() || key.is_undefined() {
        return Err(Error::undefined("subscript of or with an undefined value"));
    }
    Ok(match (a, key) {
        (Value::Dict(d), Value::Str(k)) => d.get(k).cloned().unwrap_or(Value::Undefined),
        (Value::List(l), k) => match as_int(k) {
            Some(i) => {
                let idx = if i < 0 { i + l.len() as i64 } else { i };
                if idx >= 0 && (idx as usize) < l.len() {
                    l[idx as usize].clone()
                } else {
                    Value::Undefined
                }
            }
            None => Value::Undefined,
        },
        (Value::Str(s), k) => match as_int(k) {
            Some(i) => {
                let c = if i >= 0 {
                    s.chars().nth(i as usize)
                } else {
                    let n = s.chars().count() as i64;
                    let idx = i + n;
                    if idx >= 0 {
                        s.chars().nth(idx as usize)
                    } else {
                        None
                    }
                };
                match c {
                    Some(c) => Value::from(c.to_string()),
                    None => Value::Undefined,
                }
            }
            None => Value::Undefined,
        },
        _ => Value::Undefined,
    })
}

/// The sequence view of a value, as used by `for`, `join`, `first`, ...
pub(crate) fn seq_view(v: &Value) -> Result<Rc<Vec<Value>>> {
    match v {
        Value::List(l) => Ok(l.clone()),
        Value::Dict(d) => Ok(Rc::new(d.keys().map(|k| Value::Str(k.clone())).collect())),
        Value::Str(s) => Ok(Rc::new(
            s.chars().map(|c| Value::from(c.to_string())).collect(),
        )),
        Value::Undefined => Err(Error::undefined("iterating an undefined value")),
        _ => Err(Error::type_error(format!(
            "a {} is not a sequence",
            v.kind_name()
        ))),
    }
}
