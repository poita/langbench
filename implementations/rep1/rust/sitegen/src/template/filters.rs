//! The built-in filters.

use std::borrow::Cow;

use super::ast::Filter;
use super::error::{Error, Result};
use super::ops::{as_num, seq_view, Num};
use super::value::Value;

fn is_ws(c: char) -> bool {
    matches!(c, ' ' | '\t' | '\n' | '\r' | '\x0c' | '\x0b')
}

/// The printed form of a value; the undefined value is an error.
pub(crate) fn as_string(v: &Value) -> Result<Cow<'_, str>> {
    match v {
        Value::Str(s) => Ok(Cow::Borrowed(s)),
        _ => v
            .to_output_string()
            .map(Cow::Owned)
            .ok_or_else(|| Error::undefined("use of an undefined value")),
    }
}

fn arity(args: &[Value], min: usize, max: usize) -> Result<()> {
    if args.len() < min || args.len() > max {
        Err(Error::type_error("wrong number of filter arguments"))
    } else {
        Ok(())
    }
}

/// Apply `filter` to `input` with already evaluated `args`.
pub(crate) fn apply(filter: Filter, input: Value, args: &[Value]) -> Result<Value> {
    if filter == Filter::Default {
        arity(args, 0, 1)?;
        return Ok(if input.is_undefined() {
            args.first().cloned().unwrap_or_else(|| Value::str(""))
        } else {
            input
        });
    }
    if input.is_undefined() {
        return Err(Error::undefined("filter applied to an undefined value"));
    }
    match filter {
        Filter::Upper => {
            arity(args, 0, 0)?;
            Ok(Value::from(as_string(&input)?.to_ascii_uppercase()))
        }
        Filter::Lower => {
            arity(args, 0, 0)?;
            Ok(Value::from(as_string(&input)?.to_ascii_lowercase()))
        }
        Filter::Trim => {
            arity(args, 0, 0)?;
            Ok(Value::str(as_string(&input)?.trim_matches(is_ws)))
        }
        Filter::Escape => {
            arity(args, 0, 0)?;
            let s = as_string(&input)?;
            let mut out = String::with_capacity(s.len());
            for c in s.chars() {
                match c {
                    '&' => out.push_str("&amp;"),
                    '<' => out.push_str("&lt;"),
                    '>' => out.push_str("&gt;"),
                    '"' => out.push_str("&#34;"),
                    '\'' => out.push_str("&#39;"),
                    c => out.push(c),
                }
            }
            Ok(Value::from(out))
        }
        Filter::Replace => {
            arity(args, 2, 2)?;
            let s = as_string(&input)?;
            let old = as_string(&args[0])?;
            let new = as_string(&args[1])?;
            if old.is_empty() {
                // Python inserts `new` between every character.
                let mut out = String::new();
                out.push_str(&new);
                for c in s.chars() {
                    out.push(c);
                    out.push_str(&new);
                }
                return Ok(Value::from(out));
            }
            Ok(Value::from(s.replace(&*old, &new)))
        }
        Filter::Length => {
            arity(args, 0, 0)?;
            match &input {
                Value::Str(s) => Ok(Value::Int(s.chars().count() as i64)),
                Value::List(l) => Ok(Value::Int(l.len() as i64)),
                Value::Dict(d) => Ok(Value::Int(d.len() as i64)),
                _ => Err(Error::type_error("length of a value without length")),
            }
        }
        Filter::Int => {
            arity(args, 0, 0)?;
            Ok(Value::Int(match &input {
                Value::Int(i) => *i,
                Value::Bool(b) => *b as i64,
                Value::Float(f) => *f as i64,
                Value::Str(s) => int_from_str(s),
                _ => 0,
            }))
        }
        Filter::Join => {
            arity(args, 0, 1)?;
            let seq = seq_view(&input)?;
            let sep = match args.first() {
                Some(v) => as_string(v)?,
                None => Cow::Borrowed(""),
            };
            let mut out = String::new();
            for (i, v) in seq.iter().enumerate() {
                if i > 0 {
                    out.push_str(&sep);
                }
                if !v.write_to(&mut out, false) {
                    return Err(Error::undefined("undefined list element"));
                }
            }
            Ok(Value::from(out))
        }
        Filter::First => {
            arity(args, 0, 0)?;
            Ok(seq_view(&input)?
                .first()
                .cloned()
                .unwrap_or(Value::Undefined))
        }
        Filter::Last => {
            arity(args, 0, 0)?;
            Ok(seq_view(&input)?
                .last()
                .cloned()
                .unwrap_or(Value::Undefined))
        }
        Filter::Reverse => {
            arity(args, 0, 0)?;
            if let Value::Str(s) = &input {
                return Ok(Value::from(s.chars().rev().collect::<String>()));
            }
            let seq = seq_view(&input)?;
            Ok(Value::list(seq.iter().rev().cloned().collect()))
        }
        Filter::Sort => {
            arity(args, 0, 0)?;
            let seq = seq_view(&input)?;
            let mut items: Vec<Value> = seq.iter().cloned().collect();
            if items.iter().all(|v| as_num(v).is_some()) {
                items.sort_by(|a, b| {
                    let (a, b) = (as_num(a).unwrap(), as_num(b).unwrap());
                    match (a, b) {
                        (Num::I(a), Num::I(b)) => a.cmp(&b),
                        (a, b) => a
                            .to_f64()
                            .partial_cmp(&b.to_f64())
                            .unwrap_or(std::cmp::Ordering::Equal),
                    }
                });
            } else if items.iter().all(|v| matches!(v, Value::Str(_))) {
                items.sort_by_cached_key(|v| match v {
                    Value::Str(s) => s.to_ascii_lowercase(),
                    _ => unreachable!(),
                });
            } else {
                return Err(Error::type_error("cannot sort a mixed list"));
            }
            Ok(Value::list(items))
        }
        Filter::Default => unreachable!(),
    }
}

/// The `int` filter on a string.
fn int_from_str(s: &str) -> i64 {
    let t = s.trim_matches(is_ws);
    let b = t.as_bytes();
    let (neg, digits) = match b.first() {
        Some(b'-') => (true, &t[1..]),
        Some(b'+') => (false, &t[1..]),
        _ => (false, t),
    };
    if !digits.is_empty() && digits.bytes().all(|c| c.is_ascii_digit()) {
        let mut v: i64 = 0;
        for c in digits.bytes() {
            let d = i64::from(c - b'0');
            v = match v.checked_mul(10).and_then(|x| {
                if neg {
                    x.checked_sub(d)
                } else {
                    x.checked_add(d)
                }
            }) {
                Some(v) => v,
                None => return if neg { i64::MIN } else { i64::MAX },
            };
        }
        return v;
    }
    if is_decimal(digits) {
        if let Ok(f) = t.parse::<f64>() {
            return f as i64;
        }
    }
    0
}

/// `([0-9]+\.?[0-9]*|\.[0-9]+)([eE][+-]?[0-9]+)?` over the whole string.
fn is_decimal(s: &str) -> bool {
    let b = s.as_bytes();
    let mut i = 0;
    let int_start = i;
    while i < b.len() && b[i].is_ascii_digit() {
        i += 1;
    }
    let int_digits = i - int_start;
    let mut frac_digits = 0;
    let mut dot = false;
    if i < b.len() && b[i] == b'.' {
        dot = true;
        i += 1;
        let fs = i;
        while i < b.len() && b[i].is_ascii_digit() {
            i += 1;
        }
        frac_digits = i - fs;
    }
    if !(int_digits > 0 || (dot && frac_digits > 0)) {
        return false;
    }
    if i < b.len() && (b[i] == b'e' || b[i] == b'E') {
        i += 1;
        if i < b.len() && (b[i] == b'+' || b[i] == b'-') {
            i += 1;
        }
        let es = i;
        while i < b.len() && b[i].is_ascii_digit() {
            i += 1;
        }
        if i == es {
            return false;
        }
    }
    i == b.len()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn int_parsing() {
        assert_eq!(int_from_str(" 42 "), 42);
        assert_eq!(int_from_str("-7"), -7);
        assert_eq!(int_from_str("+7"), 7);
        assert_eq!(int_from_str("3.9"), 3);
        assert_eq!(int_from_str("-3.9"), -3);
        assert_eq!(int_from_str("1e3"), 1000);
        assert_eq!(int_from_str(".5"), 0);
        assert_eq!(int_from_str("abc"), 0);
        assert_eq!(int_from_str("1.2.3"), 0);
        assert_eq!(int_from_str(""), 0);
    }
}
