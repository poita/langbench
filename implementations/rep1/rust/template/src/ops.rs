//! Arithmetic, string and comparison operators.

use crate::ast::{BinOp, CmpOp};
use crate::error::{Error, Result};
use crate::value::{Num, Value};
use std::cmp::Ordering;
use std::rc::Rc;

fn type_err(op: &str, a: &Value, b: &Value) -> Error {
    Error::type_error(format!("unsupported operand kinds for {}: {} and {}", op, a.kind_name(), b.kind_name()))
}

/// Unary minus.
pub fn neg(v: &Value) -> Result<Value> {
    v.defined()?;
    match Num::of(v) {
        Some(Num::I(i)) => Ok(Value::Int(i.wrapping_neg())),
        Some(Num::F(f)) => Ok(Value::Float(-f)),
        None => Err(Error::type_error(format!("cannot negate {}", v.kind_name()))),
    }
}

/// Evaluates a binary arithmetic or `~` operator on evaluated operands.
pub fn binary(op: BinOp, a: &Value, b: &Value) -> Result<Value> {
    a.defined()?;
    b.defined()?;
    if op == BinOp::Concat {
        let mut s = String::new();
        a.write_str(&mut s)?;
        b.write_str(&mut s)?;
        return Ok(Value::str(s));
    }
    if let (Some(x), Some(y)) = (Num::of(a), Num::of(b)) {
        return numeric(op, x, y);
    }
    match (op, a, b) {
        (BinOp::Add, Value::Str(x), Value::Str(y)) => {
            let mut s = String::with_capacity(x.len() + y.len());
            s.push_str(x);
            s.push_str(y);
            Ok(Value::Str(Rc::from(s)))
        }
        (BinOp::Add, Value::List(x), Value::List(y)) => {
            let mut v = Vec::with_capacity(x.len() + y.len());
            v.extend(x.iter().cloned());
            v.extend(y.iter().cloned());
            Ok(Value::list(v))
        }
        (BinOp::Mul, Value::Str(s), n) | (BinOp::Mul, n, Value::Str(s)) => match n {
            Value::Int(_) | Value::Bool(_) => {
                let count = match Num::of(n) {
                    Some(Num::I(i)) => i,
                    _ => 0,
                };
                Ok(Value::str(if count <= 0 { String::new() } else { s.repeat(count as usize) }))
            }
            _ => Err(type_err("*", a, b)),
        },
        _ => Err(type_err(op_name(op), a, b)),
    }
}

fn op_name(op: BinOp) -> &'static str {
    match op {
        BinOp::Add => "+",
        BinOp::Sub => "-",
        BinOp::Mul => "*",
        BinOp::Div => "/",
        BinOp::FloorDiv => "//",
        BinOp::Mod => "%",
        BinOp::Pow => "**",
        BinOp::Concat => "~",
    }
}

fn zero_div() -> Error {
    Error::type_error("division or modulo by zero")
}

fn numeric(op: BinOp, x: Num, y: Num) -> Result<Value> {
    use Num::I;
    Ok(match op {
        BinOp::Add => match (x, y) {
            (I(a), I(b)) => Value::Int(a.wrapping_add(b)),
            _ => Value::Float(x.as_f64() + y.as_f64()),
        },
        BinOp::Sub => match (x, y) {
            (I(a), I(b)) => Value::Int(a.wrapping_sub(b)),
            _ => Value::Float(x.as_f64() - y.as_f64()),
        },
        BinOp::Mul => match (x, y) {
            (I(a), I(b)) => Value::Int(a.wrapping_mul(b)),
            _ => Value::Float(x.as_f64() * y.as_f64()),
        },
        BinOp::Div => {
            let d = y.as_f64();
            if d == 0.0 {
                return Err(zero_div());
            }
            Value::Float(x.as_f64() / d)
        }
        BinOp::FloorDiv => match (x, y) {
            (I(_), I(0)) => return Err(zero_div()),
            (I(a), I(b)) => {
                let q = a.wrapping_div(b);
                let r = a.wrapping_rem(b);
                Value::Int(if r != 0 && ((r < 0) != (b < 0)) { q - 1 } else { q })
            }
            _ => {
                let (a, b) = (x.as_f64(), y.as_f64());
                if b == 0.0 {
                    return Err(zero_div());
                }
                Value::Float(float_floor_div(a, b))
            }
        },
        BinOp::Mod => match (x, y) {
            (I(_), I(0)) => return Err(zero_div()),
            (I(a), I(b)) => {
                let r = a.wrapping_rem(b);
                Value::Int(if r != 0 && ((r < 0) != (b < 0)) { r + b } else { r })
            }
            _ => {
                let (a, b) = (x.as_f64(), y.as_f64());
                if b == 0.0 {
                    return Err(zero_div());
                }
                Value::Float(float_mod(a, b))
            }
        },
        BinOp::Pow => match (x, y) {
            (I(a), I(b)) if b >= 0 => Value::Int(a.wrapping_pow(b.min(u32::MAX as i64) as u32)),
            (I(0), I(_)) => return Err(zero_div()),
            _ => {
                let (a, b) = (x.as_f64(), y.as_f64());
                if a == 0.0 && b < 0.0 {
                    return Err(zero_div());
                }
                Value::Float(a.powf(b))
            }
        },
        BinOp::Concat => unreachable!("handled by the caller"),
    })
}

fn float_mod(a: f64, b: f64) -> f64 {
    let m = a % b;
    if m != 0.0 {
        if (b < 0.0) != (m < 0.0) {
            m + b
        } else {
            m
        }
    } else {
        0.0f64.copysign(b)
    }
}

fn float_floor_div(a: f64, b: f64) -> f64 {
    let mut m = a % b;
    let mut div = (a - m) / b;
    if m != 0.0 && (b < 0.0) != (m < 0.0) {
        m += b;
        div -= 1.0;
    }
    let _ = m;
    if div != 0.0 {
        let mut f = div.floor();
        if div - f > 0.5 {
            f += 1.0;
        }
        f
    } else {
        0.0f64.copysign(a / b)
    }
}

/// Evaluates one comparison on evaluated operands.
pub fn compare(op: CmpOp, a: &Value, b: &Value) -> Result<bool> {
    a.defined()?;
    b.defined()?;
    match op {
        CmpOp::Eq => Ok(a.loose_eq(b)),
        CmpOp::Ne => Ok(!a.loose_eq(b)),
        CmpOp::In => contains(b, a),
        CmpOp::NotIn => contains(b, a).map(|r| !r),
        CmpOp::Lt | CmpOp::Le | CmpOp::Gt | CmpOp::Ge => {
            let ord = match (a, b) {
                (Value::Str(x), Value::Str(y)) => Some(x.as_bytes().cmp(y.as_bytes())),
                _ => match (Num::of(a), Num::of(b)) {
                    (Some(x), Some(y)) => x.num_cmp(y),
                    _ => {
                        return Err(Error::type_error(format!(
                            "cannot order {} and {}",
                            a.kind_name(),
                            b.kind_name()
                        )))
                    }
                },
            };
            Ok(match ord {
                None => false,
                Some(o) => match op {
                    CmpOp::Lt => o == Ordering::Less,
                    CmpOp::Le => o != Ordering::Greater,
                    CmpOp::Gt => o == Ordering::Greater,
                    _ => o != Ordering::Less,
                },
            })
        }
    }
}

/// `needle in haystack`.
fn contains(haystack: &Value, needle: &Value) -> Result<bool> {
    match haystack {
        Value::Str(h) => match needle {
            Value::Str(n) => Ok(h.contains(&**n)),
            other => Err(Error::type_error(format!("'in <string>' requires a string, not {}", other.kind_name()))),
        },
        Value::Dict(d) => Ok(matches!(needle, Value::Str(k) if d.contains_key(k))),
        Value::List(l) => Ok(l.iter().any(|v| v.loose_eq(needle))),
        other => Err(Error::type_error(format!("cannot test membership in {}", other.kind_name()))),
    }
}
