//! Builtin function implementations.

use crate::ast::{Builtin, Expr};
use crate::error::{Error, Result};
use crate::eval::{eval, Env, Sink};
use crate::json;
use crate::ops::Adder;
use crate::value::Value;
use std::cmp::Ordering;

/// Calls builtin `b` with unevaluated arguments `args`.
pub(crate) fn call(b: Builtin, args: &[Expr], env: &Env, input: &Value, out: &mut Sink) -> Result<()> {
    match b {
        Builtin::Empty => Ok(()),
        Builtin::Error0 => Err(Error::runtime(message_of(input))),
        Builtin::Error1 => eval(&args[0], env, input, &mut |v| Err(Error::runtime(message_of(&v)))),
        Builtin::Not => out(Value::Bool(!input.is_truthy())),
        Builtin::Length => out(length(input)?),
        Builtin::Keys => out(keys(input)?),
        Builtin::Has => eval(&args[0], env, input, &mut |k| out(has(input, &k)?)),
        Builtin::Type => out(Value::string(input.type_name())),
        Builtin::Add => out(add(input)?),
        Builtin::Select => eval(&args[0], env, input, &mut |c| if c.is_truthy() { out(input.clone()) } else { Ok(()) }),
        Builtin::Map => {
            let mut items = Vec::new();
            for x in iter_values(input)? {
                eval(&args[0], env, x, &mut |v| {
                    items.push(v);
                    Ok(())
                })?;
            }
            out(Value::array(items))
        }
        Builtin::Sort => {
            let mut v = array_of(input, "sorted")?.to_vec();
            v.sort_by(|a, b| a.compare(b));
            out(Value::array(v))
        }
        Builtin::SortBy => {
            let keyed = keyed(&args[0], env, input, "sorted")?;
            out(Value::array(keyed.into_iter().map(|(_, v)| v).collect()))
        }
        Builtin::GroupBy => {
            let keyed = keyed(&args[0], env, input, "grouped")?;
            let mut groups: Vec<Value> = Vec::new();
            let mut cur: Vec<Value> = Vec::new();
            let mut cur_key: Option<Value> = None;
            for (k, v) in keyed {
                if let Some(ck) = &cur_key {
                    if ck.compare(&k) != Ordering::Equal {
                        groups.push(Value::array(std::mem::take(&mut cur)));
                    }
                }
                cur_key = Some(k);
                cur.push(v);
            }
            if cur_key.is_some() {
                groups.push(Value::array(cur));
            }
            out(Value::array(groups))
        }
        Builtin::Unique => {
            let mut v = array_of(input, "sorted")?.to_vec();
            v.sort_by(|a, b| a.compare(b));
            v.dedup_by(|a, b| a.compare(b) == Ordering::Equal);
            out(Value::array(v))
        }
        Builtin::Reverse => match input {
            Value::Null => out(Value::array(Vec::new())),
            Value::Array(a) => out(Value::array(a.iter().rev().cloned().collect())),
            _ => Err(Error::runtime(format!("Cannot reverse {}", input.type_name()))),
        },
        Builtin::Min | Builtin::Max => {
            let a = array_of(input, "compared")?;
            let mut best: Option<&Value> = None;
            for x in a {
                best = match best {
                    None => Some(x),
                    Some(cur) => {
                        let c = x.compare(cur);
                        // min keeps the first minimal element, max the last maximal one.
                        let replace = if b == Builtin::Min { c == Ordering::Less } else { c != Ordering::Less };
                        Some(if replace { x } else { cur })
                    }
                };
            }
            out(best.cloned().unwrap_or(Value::Null))
        }
        Builtin::ToString => match input {
            Value::String(_) => out(input.clone()),
            other => out(Value::string(json::to_string(other))),
        },
        Builtin::ToNumber => match input {
            Value::Number(_) => out(input.clone()),
            Value::String(s) => match json::parse_number(s) {
                Some(n) => out(Value::Number(n)),
                None => Err(Error::runtime(format!("Cannot parse {} as a number", json::to_string(input)))),
            },
            _ => Err(Error::runtime(format!("{} cannot be parsed as a number", input.type_name()))),
        },
    }
}

fn message_of(v: &Value) -> String {
    match v {
        Value::String(s) => s.to_string(),
        other => json::to_string(other),
    }
}

fn array_of<'a>(v: &'a Value, what: &str) -> Result<&'a [Value]> {
    match v {
        Value::Array(a) => Ok(a),
        _ => Err(Error::runtime(format!("{} cannot be {}, as it is not an array", v.type_name(), what))),
    }
}

/// The values of an array, or of an object in insertion order.
fn iter_values(v: &Value) -> Result<Box<dyn Iterator<Item = &Value> + '_>> {
    match v {
        Value::Array(a) => Ok(Box::new(a.iter())),
        Value::Object(o) => Ok(Box::new(o.values())),
        _ => Err(Error::runtime(format!("Cannot iterate over {}", v.type_name()))),
    }
}

/// Pairs each element with its key `[f]` (evaluating `f` once per element) and stably sorts by key.
fn keyed(f: &Expr, env: &Env, input: &Value, what: &str) -> Result<Vec<(Value, Value)>> {
    let a = array_of(input, what)?;
    let mut pairs = Vec::with_capacity(a.len());
    for x in a {
        let mut key = Vec::new();
        eval(f, env, x, &mut |v| {
            key.push(v);
            Ok(())
        })?;
        pairs.push((Value::array(key), x.clone()));
    }
    pairs.sort_by(|a, b| a.0.compare(&b.0));
    Ok(pairs)
}

fn length(v: &Value) -> Result<Value> {
    Ok(Value::Number(match v {
        Value::Null => 0.0,
        Value::Number(n) => n.abs(),
        Value::String(s) => s.chars().count() as f64,
        Value::Array(a) => a.len() as f64,
        Value::Object(o) => o.len() as f64,
        Value::Bool(_) => return Err(Error::runtime("boolean has no length")),
    }))
}

fn keys(v: &Value) -> Result<Value> {
    match v {
        Value::Object(o) => Ok(Value::array(o.sorted_iter().map(|(k, _)| Value::String(k.clone())).collect())),
        Value::Array(a) => Ok(Value::array((0..a.len()).map(|i| Value::Number(i as f64)).collect())),
        _ => Err(Error::runtime(format!("{} has no keys", v.type_name()))),
    }
}

fn has(v: &Value, k: &Value) -> Result<Value> {
    match (v, k) {
        (Value::Object(o), Value::String(s)) => Ok(Value::Bool(o.contains_key(s))),
        (Value::Array(a), Value::Number(n)) => {
            let i = n.trunc();
            Ok(Value::Bool(i >= 0.0 && i < a.len() as f64))
        }
        (Value::Null, _) => Ok(Value::Bool(false)),
        _ => Err(Error::runtime(format!("Cannot check whether {} has a {} key", v.type_name(), k.type_name()))),
    }
}

fn add(v: &Value) -> Result<Value> {
    let mut acc = Adder::Null;
    for x in iter_values(v)? {
        acc.push(x)?;
    }
    Ok(acc.finish())
}
