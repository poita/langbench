//! Builtin functions.

use std::rc::Rc;

use crate::ast::{Builtin, Expr};
use crate::error::Error;
use crate::eval::{add, collect, eval, first, Env, Flow, K, R};
use crate::object::Object;
use crate::value::Value;

fn type_error(what: &str, v: &Value) -> Flow {
    Error::msg(format!("{} ({}) {}", v.type_name(), v.to_json(), what)).into()
}

/// Evaluates builtin `b` with filter arguments `args` on `input`.
pub(crate) fn call(b: Builtin, args: &[Expr], env: &Env, input: &Value, k: K) -> R {
    match b {
        Builtin::Empty => Ok(()),
        Builtin::Error0 => Err(Error::Value(input.clone()).into()),
        Builtin::Error1 => match first(&args[0], env, input)? {
            Some(v) => Err(Error::Value(v).into()),
            None => Ok(()),
        },
        Builtin::Not => k(Value::Bool(!input.is_truthy())),
        Builtin::Length => k(length(input)?),
        Builtin::Keys => k(keys(input)?),
        Builtin::Has => eval(&args[0], env, input, &mut |key| k(has(input, &key)?)),
        Builtin::Type => k(Value::string(input.type_name())),
        Builtin::Add => k(add_all(input)?),
        Builtin::Select => eval(&args[0], env, input, &mut |c| {
            if c.is_truthy() {
                k(input.clone())
            } else {
                Ok(())
            }
        }),
        Builtin::Map => {
            let mut out = Vec::new();
            let mut each = |v: &Value| {
                eval(&args[0], env, v, &mut |o| {
                    out.push(o);
                    Ok(())
                })
            };
            match input {
                Value::Array(a) => {
                    for v in a.iter() {
                        each(v)?;
                    }
                }
                Value::Object(o) => {
                    for v in o.values() {
                        each(v)?;
                    }
                }
                _ => return Err(type_error("cannot be iterated over", input)),
            }
            k(Value::array(out))
        }
        Builtin::Sort => match input {
            Value::Array(a) => {
                let mut v = a.to_vec();
                v.sort_by(|x, y| x.compare(y));
                k(Value::array(v))
            }
            _ => Err(type_error("cannot be sorted, as it is not an array", input)),
        },
        Builtin::SortBy => {
            let keyed = keyed(&args[0], env, input)?;
            k(Value::array(keyed.into_iter().map(|(_, v)| v).collect()))
        }
        Builtin::GroupBy => {
            let keyed = keyed(&args[0], env, input)?;
            let mut groups: Vec<Value> = Vec::new();
            let mut cur: Vec<Value> = Vec::new();
            let mut cur_key: Option<Value> = None;
            for (key, v) in keyed {
                if let Some(ck) = &cur_key {
                    if ck.compare(&key).is_ne() {
                        groups.push(Value::array(std::mem::take(&mut cur)));
                        cur_key = Some(key);
                    }
                } else {
                    cur_key = Some(key);
                }
                cur.push(v);
            }
            if cur_key.is_some() {
                groups.push(Value::array(cur));
            }
            k(Value::array(groups))
        }
        Builtin::Unique => match input {
            Value::Array(a) => {
                let mut v = a.to_vec();
                v.sort_by(|x, y| x.compare(y));
                v.dedup_by(|later, earlier| later.compare(earlier).is_eq());
                k(Value::array(v))
            }
            _ => Err(type_error("cannot be sorted, as it is not an array", input)),
        },
        Builtin::Reverse => match input {
            Value::Array(a) => k(Value::array(a.iter().rev().cloned().collect())),
            Value::Null => k(Value::array(Vec::new())),
            _ => Err(type_error("cannot be reversed, as it is not an array", input)),
        },
        Builtin::Min | Builtin::Max => match input {
            Value::Array(a) => {
                let mut best: Option<&Value> = None;
                for v in a.iter() {
                    best = Some(match best {
                        None => v,
                        // min keeps the first minimal; max the last maximal.
                        Some(cur) if b == Builtin::Min => {
                            if v.compare(cur).is_lt() {
                                v
                            } else {
                                cur
                            }
                        }
                        Some(cur) => {
                            if v.compare(cur).is_ge() {
                                v
                            } else {
                                cur
                            }
                        }
                    });
                }
                k(best.cloned().unwrap_or(Value::Null))
            }
            _ => Err(type_error("cannot be iterated over", input)),
        },
        Builtin::ToString => match input {
            Value::String(_) => k(input.clone()),
            v => k(Value::from(v.to_json())),
        },
        Builtin::ToNumber => k(to_number(input)?),
    }
}

/// Computes `[f]` for each element of the input array and sorts the
/// `(key, element)` pairs stably by key.
fn keyed(f: &Expr, env: &Env, input: &Value) -> Result<Vec<(Value, Value)>, Flow> {
    let Value::Array(a) = input else {
        return Err(type_error("cannot be sorted, as it is not an array", input));
    };
    let mut pairs = Vec::with_capacity(a.len());
    for v in a.iter() {
        pairs.push((Value::array(collect(f, env, v)?), v.clone()));
    }
    pairs.sort_by(|x, y| x.0.compare(&y.0));
    Ok(pairs)
}

fn length(v: &Value) -> Result<Value, Error> {
    Ok(Value::Number(match v {
        Value::Null => 0.0,
        Value::Number(n) => n.abs(),
        Value::String(s) => {
            if s.is_ascii() {
                s.len() as f64
            } else {
                s.chars().count() as f64
            }
        }
        Value::Array(a) => a.len() as f64,
        Value::Object(o) => o.len() as f64,
        Value::Bool(_) => return Err(Error::msg("boolean has no length")),
    }))
}

fn keys(v: &Value) -> Result<Value, Error> {
    match v {
        Value::Object(o) => Ok(Value::array(o.sorted_keys().map(|k| Value::String(k.clone())).collect())),
        Value::Array(a) => Ok(Value::array((0..a.len()).map(|i| Value::Number(i as f64)).collect())),
        _ => Err(Error::msg(format!("{} has no keys", v.type_name()))),
    }
}

fn has(v: &Value, key: &Value) -> Result<Value, Error> {
    match (v, key) {
        (Value::Object(o), Value::String(s)) => Ok(Value::Bool(o.contains_key(s))),
        (Value::Array(a), Value::Number(n)) => {
            let i = n.trunc();
            Ok(Value::Bool(i >= 0.0 && i < a.len() as f64))
        }
        (Value::Null, _) => Ok(Value::Bool(false)),
        _ => Err(Error::msg(format!("Cannot check whether {} has a {} key", v.type_name(), key.type_name()))),
    }
}

/// Accumulator for `add`, so that summing n elements is linear.
enum Acc {
    Null,
    Single(Value),
    Num(f64),
    Str(String),
    Arr(Vec<Value>),
    Obj(Object),
}

fn add_all(input: &Value) -> Result<Value, Error> {
    let mut acc = Acc::Null;
    let mut push = |x: &Value| -> Result<(), Error> {
        if let Value::Null = x {
            return Ok(());
        }
        acc = match (std::mem::replace(&mut acc, Acc::Null), x) {
            (Acc::Null, x) => Acc::Single(x.clone()),
            (Acc::Single(a), x) => match (a, x) {
                (Value::Number(a), Value::Number(b)) => Acc::Num(a + b),
                (Value::String(a), Value::String(b)) => {
                    let mut s = String::with_capacity(a.len() + b.len());
                    s.push_str(&a);
                    s.push_str(b);
                    Acc::Str(s)
                }
                (Value::Array(a), Value::Array(b)) => {
                    let mut v = Vec::with_capacity(a.len() + b.len());
                    v.extend(a.iter().cloned());
                    v.extend(b.iter().cloned());
                    Acc::Arr(v)
                }
                (Value::Object(a), Value::Object(b)) => {
                    let mut o = (*a).clone();
                    for (k, v) in b.iter() {
                        o.insert(k.clone(), v.clone());
                    }
                    Acc::Obj(o)
                }
                (a, x) => return add(a, x).map(|_| ()),
            },
            (Acc::Num(a), Value::Number(b)) => Acc::Num(a + b),
            (Acc::Str(mut s), Value::String(b)) => {
                s.push_str(b);
                Acc::Str(s)
            }
            (Acc::Arr(mut v), Value::Array(b)) => {
                v.extend(b.iter().cloned());
                Acc::Arr(v)
            }
            (Acc::Obj(mut o), Value::Object(b)) => {
                for (k, v) in b.iter() {
                    o.insert(k.clone(), v.clone());
                }
                Acc::Obj(o)
            }
            (acc, x) => {
                let a = match acc {
                    Acc::Num(n) => Value::Number(n),
                    Acc::Str(s) => Value::String(Rc::from(s)),
                    Acc::Arr(v) => Value::array(v),
                    Acc::Obj(o) => Value::object(o),
                    _ => unreachable!(),
                };
                return add(a, x).map(|_| ());
            }
        };
        Ok(())
    };
    match input {
        Value::Array(a) => {
            for x in a.iter() {
                push(x)?;
            }
        }
        Value::Object(o) => {
            for x in o.values() {
                push(x)?;
            }
        }
        _ => return Err(Error::msg(format!("Cannot iterate over {}", input.type_name()))),
    }
    Ok(match acc {
        Acc::Null => Value::Null,
        Acc::Single(v) => v,
        Acc::Num(n) => Value::Number(n),
        Acc::Str(s) => Value::String(Rc::from(s)),
        Acc::Arr(v) => Value::array(v),
        Acc::Obj(o) => Value::object(o),
    })
}

fn to_number(v: &Value) -> Result<Value, Error> {
    match v {
        Value::Number(_) => Ok(v.clone()),
        Value::String(s) => {
            let numeric = !s.is_empty() && s.bytes().all(|c| matches!(c, b'0'..=b'9' | b'.' | b'-' | b'+' | b'e' | b'E'));
            match s.parse::<f64>() {
                Ok(n) if numeric && n.is_finite() => Ok(Value::Number(n)),
                _ => Err(Error::msg(format!("Cannot parse {:?} as a number", &**s))),
            }
        }
        _ => Err(Error::msg(format!("{} cannot be parsed as a number", v.type_name()))),
    }
}
