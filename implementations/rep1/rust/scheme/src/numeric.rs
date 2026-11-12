//! Integer arithmetic on [`Value`]s, with a machine-word fast path and
//! promotion to [`BigInt`] on overflow. All functions expect integer values.

use std::borrow::Cow;
use std::cmp::Ordering;

use crate::bigint::BigInt;
use crate::error::{Error, Result};
use crate::value::Value;

fn to_big(v: &Value) -> Cow<'_, BigInt> {
    match v {
        Value::Int(i) => Cow::Owned(BigInt::from(*i)),
        Value::Big(b) => Cow::Borrowed(&**b),
        _ => unreachable!("arithmetic on a non-integer"),
    }
}

pub(crate) fn add(a: &Value, b: &Value) -> Value {
    if let (Value::Int(x), Value::Int(y)) = (a, b) {
        if let Some(r) = x.checked_add(*y) {
            return Value::Int(r);
        }
    }
    Value::from_bigint(&*to_big(a) + &*to_big(b))
}

pub(crate) fn sub(a: &Value, b: &Value) -> Value {
    if let (Value::Int(x), Value::Int(y)) = (a, b) {
        if let Some(r) = x.checked_sub(*y) {
            return Value::Int(r);
        }
    }
    Value::from_bigint(&*to_big(a) - &*to_big(b))
}

pub(crate) fn mul(a: &Value, b: &Value) -> Value {
    if let (Value::Int(x), Value::Int(y)) = (a, b) {
        if let Some(r) = x.checked_mul(*y) {
            return Value::Int(r);
        }
    }
    Value::from_bigint(&*to_big(a) * &*to_big(b))
}

pub(crate) fn neg(a: &Value) -> Value {
    if let Value::Int(x) = a {
        if let Some(r) = x.checked_neg() {
            return Value::Int(r);
        }
    }
    Value::from_bigint(-&*to_big(a))
}

/// Truncating division: `(quotient, remainder)`, or `DivisionByZero`.
pub(crate) fn div_rem(a: &Value, b: &Value) -> Result<(Value, Value)> {
    if let (Value::Int(x), Value::Int(y)) = (a, b) {
        if *y == 0 {
            return Err(Error::DivisionByZero);
        }
        if let (Some(q), Some(r)) = (x.checked_div(*y), x.checked_rem(*y)) {
            return Ok((Value::Int(q), Value::Int(r)));
        }
    }
    let (q, r) = to_big(a).div_rem(&to_big(b)).ok_or(Error::DivisionByZero)?;
    Ok((Value::from_bigint(q), Value::from_bigint(r)))
}

pub(crate) fn cmp(a: &Value, b: &Value) -> Ordering {
    if let (Value::Int(x), Value::Int(y)) = (a, b) {
        return x.cmp(y);
    }
    to_big(a).cmp(&to_big(b))
}
