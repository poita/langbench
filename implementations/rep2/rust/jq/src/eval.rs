//! The tree-walking, callback-driven evaluator.
//!
//! Every expression is evaluated by [`eval`], which pushes each output into a
//! continuation `k` as soon as it is produced. This keeps evaluation lazy and
//! strictly ordered, makes generators nest without allocation, and lets an
//! error unwind the whole evaluation at the point it occurs.

use std::rc::Rc;

use crate::ast::{BinOp, Expr, ObjKey};
use crate::builtins;
use crate::error::Error;
use crate::object::Object;
use crate::value::Value;

/// Non-local exits from evaluation.
#[derive(Debug)]
pub(crate) enum Flow {
    /// A jq runtime error.
    Err(Error),
    /// A consumer asked for evaluation to stop (used for "first output only").
    Stop,
}

impl From<Error> for Flow {
    fn from(e: Error) -> Flow {
        Flow::Err(e)
    }
}

pub(crate) type R = Result<(), Flow>;
pub(crate) type K<'a> = &'a mut dyn FnMut(Value) -> R;

/// A persistent (shared, immutable) variable environment.
#[derive(Clone, Default)]
pub(crate) struct Env(Option<Rc<EnvNode>>);

struct EnvNode {
    name: Rc<str>,
    value: Value,
    parent: Env,
}

impl Env {
    pub(crate) fn bind(&self, name: &Rc<str>, value: Value) -> Env {
        Env(Some(Rc::new(EnvNode { name: name.clone(), value, parent: self.clone() })))
    }

    fn lookup(&self, name: &str) -> Option<&Value> {
        let mut cur = &self.0;
        while let Some(n) = cur {
            if &*n.name == name {
                return Some(&n.value);
            }
            cur = &n.parent.0;
        }
        None
    }
}

/// Collects all outputs of `e` into a vector.
pub(crate) fn collect(e: &Expr, env: &Env, input: &Value) -> Result<Vec<Value>, Flow> {
    let mut out = Vec::new();
    eval(e, env, input, &mut |v| {
        out.push(v);
        Ok(())
    })?;
    Ok(out)
}

/// Returns the first output of `e`, if any, without evaluating further.
pub(crate) fn first(e: &Expr, env: &Env, input: &Value) -> Result<Option<Value>, Flow> {
    let mut found = None;
    let r = eval(e, env, input, &mut |v| {
        found = Some(v);
        Err(Flow::Stop)
    });
    match r {
        Err(Flow::Stop) if found.is_some() => Ok(found),
        Err(e) => Err(e),
        Ok(()) => Ok(None),
    }
}

pub(crate) fn eval(e: &Expr, env: &Env, input: &Value, k: K) -> R {
    match e {
        Expr::Identity => k(input.clone()),
        Expr::Literal(v) => k(v.clone()),
        Expr::Var(name) => match env.lookup(name) {
            Some(v) => k(v.clone()),
            None => Err(Error::msg(format!("${} is not defined", name)).into()),
        },
        Expr::Index { target, index, optional } => {
            if let Expr::Literal(kv) = &**index {
                return eval(target, env, input, &mut |t| match index_value(&t, kv) {
                    Ok(v) => k(v),
                    Err(_) if *optional => Ok(()),
                    Err(e) => Err(e.into()),
                });
            }
            eval(index, env, input, &mut |kv| {
                eval(target, env, input, &mut |t| match index_value(&t, &kv) {
                    Ok(v) => k(v),
                    Err(_) if *optional => Ok(()),
                    Err(e) => Err(e.into()),
                })
            })
        }
        Expr::Iterate { target, optional } => eval(target, env, input, &mut |t| match &t {
            Value::Array(a) => {
                for v in a.iter() {
                    k(v.clone())?;
                }
                Ok(())
            }
            Value::Object(o) => {
                for v in o.values() {
                    k(v.clone())?;
                }
                Ok(())
            }
            _ if *optional => Ok(()),
            _ => Err(Error::msg(format!("Cannot iterate over {}", t.type_name())).into()),
        }),
        Expr::Slice { target, from, to, optional } => {
            let opt_eval = |e: &Option<Box<Expr>>, kk: K| -> R {
                match e {
                    Some(e) => eval(e, env, input, &mut |v| kk(v)),
                    None => kk(Value::Null),
                }
            };
            opt_eval(from, &mut |a| {
                opt_eval(to, &mut |b| {
                    eval(target, env, input, &mut |t| match slice_value(&t, &a, &b) {
                        Ok(v) => k(v),
                        Err(_) if *optional => Ok(()),
                        Err(e) => Err(e.into()),
                    })
                })
            })
        }
        Expr::Try(inner) => {
            let mut downstream = false;
            let r = eval(inner, env, input, &mut |v| {
                k(v).map_err(|e| {
                    downstream = true;
                    e
                })
            });
            match r {
                Err(Flow::Err(_)) if !downstream => Ok(()),
                r => r,
            }
        }
        Expr::Neg(inner) => eval(inner, env, input, &mut |v| match v {
            Value::Number(n) => k(Value::Number(-n)),
            v => Err(Error::msg(format!("{} cannot be negated", v.type_name())).into()),
        }),
        Expr::Binary(op, l, r) => eval(r, env, input, &mut |b| {
            eval(l, env, input, &mut |a| k(binop(*op, a, &b)?))
        }),
        Expr::And(l, r) => eval(l, env, input, &mut |a| {
            if !a.is_truthy() {
                k(Value::Bool(false))
            } else {
                eval(r, env, input, &mut |b| k(Value::Bool(b.is_truthy())))
            }
        }),
        Expr::Or(l, r) => eval(l, env, input, &mut |a| {
            if a.is_truthy() {
                k(Value::Bool(true))
            } else {
                eval(r, env, input, &mut |b| k(Value::Bool(b.is_truthy())))
            }
        }),
        Expr::Pipe(l, r) => eval(l, env, input, &mut |v| eval(r, env, &v, k)),
        Expr::Comma(l, r) => {
            eval(l, env, input, k)?;
            eval(r, env, input, k)
        }
        Expr::Array(None) => k(Value::array(Vec::new())),
        Expr::Array(Some(inner)) => k(Value::array(collect(inner, env, input)?)),
        Expr::Object(entries) => {
            let mut acc = Vec::with_capacity(entries.len());
            eval_object(entries, env, input, &mut acc, k)
        }
        Expr::If { cond, then, otherwise } => eval(cond, env, input, &mut |c| {
            if c.is_truthy() {
                eval(then, env, input, k)
            } else {
                eval(otherwise, env, input, k)
            }
        }),
        Expr::As { source, name, body } => {
            eval(source, env, input, &mut |v| eval(body, &env.bind(name, v), input, k))
        }
        Expr::Reduce { source, name, init, update } => eval(init, env, input, &mut |init| {
            let mut acc = init;
            eval(source, env, input, &mut |v| {
                let env2 = env.bind(name, v);
                // Fast path for the common `reduce ... (init; . + rhs)`: when
                // `rhs` yields one value, `acc` can be extended in place if
                // nothing else shares it, keeping accumulation linear.
                if let Expr::Binary(BinOp::Add, l, r) = &**update {
                    if matches!(**l, Expr::Identity) {
                        let mut rhs = collect(r, &env2, &acc)?;
                        if rhs.len() == 1 {
                            let b = rhs.pop().unwrap();
                            let a = std::mem::replace(&mut acc, Value::Null);
                            acc = add(a, &b)?;
                            return Ok(());
                        }
                        let mut last = None;
                        for b in &rhs {
                            last = Some(add(acc.clone(), b)?);
                        }
                        acc = last.unwrap_or(Value::Null);
                        return Ok(());
                    }
                }
                let mut last = None;
                eval(update, &env2, &acc, &mut |o| {
                    last = Some(o);
                    Ok(())
                })?;
                acc = last.unwrap_or(Value::Null);
                Ok(())
            })?;
            k(acc)
        }),
        Expr::Call(b, args) => builtins::call(*b, args, env, input, k),
    }
}

fn eval_object(
    entries: &[(ObjKey, Expr)],
    env: &Env,
    input: &Value,
    acc: &mut Vec<(Rc<str>, Value)>,
    k: K,
) -> R {
    let Some(((key, val), rest)) = entries.split_first() else {
        let mut o = Object::with_capacity(acc.len());
        for (kk, v) in acc.iter() {
            o.insert(kk.clone(), v.clone());
        }
        return k(Value::object(o));
    };
    let mut with_key = |ks: Rc<str>| {
        eval(val, env, input, &mut |v| {
            acc.push((ks.clone(), v));
            let r = eval_object(rest, env, input, acc, k);
            acc.pop();
            r
        })
    };
    match key {
        ObjKey::Literal(s) => with_key(s.clone()),
        ObjKey::Computed(ke) => eval(ke, env, input, &mut |kv| match kv {
            Value::String(s) => with_key(s),
            other => {
                Err(Error::msg(format!("Object keys must be strings, not {}", other.type_name())).into())
            }
        }),
    }
}

// -------------------------------------------------------- path operations

fn index_value(t: &Value, k: &Value) -> Result<Value, Error> {
    match (t, k) {
        (Value::Object(o), Value::String(s)) => Ok(o.get(s).cloned().unwrap_or(Value::Null)),
        (Value::Null, Value::String(_) | Value::Number(_)) => Ok(Value::Null),
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
        _ => Err(Error::msg(format!("Cannot index {} with {}", t.type_name(), k.type_name()))),
    }
}

fn slice_value(t: &Value, from: &Value, to: &Value) -> Result<Value, Error> {
    if let Value::Null = t {
        return Ok(Value::Null);
    }
    let len = match t {
        Value::Array(a) => a.len(),
        Value::String(s) => {
            if s.is_ascii() {
                s.len()
            } else {
                s.chars().count()
            }
        }
        _ => return Err(Error::msg(format!("Cannot index {} with object", t.type_name()))),
    };
    let bound = |v: &Value, default: usize, round_up: bool| -> Result<usize, Error> {
        match v {
            Value::Null => Ok(default),
            Value::Number(n) => {
                let mut x = if round_up { n.ceil() } else { n.floor() };
                if x < 0.0 {
                    x += len as f64;
                }
                Ok(x.clamp(0.0, len as f64) as usize)
            }
            _ => Err(Error::msg("Start and end indices of an array slice must be numbers")),
        }
    };
    let a = bound(from, 0, false)?;
    let b = bound(to, len, true)?.max(a);
    Ok(match t {
        Value::Array(arr) => Value::array(arr[a..b].to_vec()),
        Value::String(s) => {
            if s.is_ascii() {
                Value::string(&s[a..b])
            } else {
                Value::String(Rc::from(s.chars().skip(a).take(b - a).collect::<String>()))
            }
        }
        _ => unreachable!(),
    })
}

// ------------------------------------------------------------- arithmetic

fn type_err(op: &str, a: &Value, b: &Value) -> Error {
    Error::msg(format!("{} and {} cannot be {}", a.type_name(), b.type_name(), op))
}

pub(crate) fn binop(op: BinOp, a: Value, b: &Value) -> Result<Value, Error> {
    match op {
        BinOp::Add => add(a, b),
        BinOp::Sub => match (&a, b) {
            (Value::Number(x), Value::Number(y)) => Ok(Value::Number(x - y)),
            (Value::Array(x), Value::Array(y)) => {
                Ok(Value::array(x.iter().filter(|e| !y.iter().any(|r| r == *e)).cloned().collect()))
            }
            _ => Err(type_err("subtracted", &a, b)),
        },
        BinOp::Mul => match (&a, b) {
            (Value::Number(x), Value::Number(y)) => Ok(Value::Number(x * y)),
            (Value::String(s), Value::Number(n)) | (Value::Number(n), Value::String(s)) => Ok(repeat(s, *n)),
            (Value::Object(x), Value::Object(y)) => Ok(Value::object(deep_merge(x, y))),
            _ => Err(type_err("multiplied", &a, b)),
        },
        BinOp::Div => match (&a, b) {
            (Value::Number(x), Value::Number(y)) => {
                if *y == 0.0 {
                    Err(type_err("divided because the divisor is zero", &a, b))
                } else {
                    Ok(Value::Number(x / y))
                }
            }
            (Value::String(s), Value::String(sep)) => Ok(split(s, sep)),
            _ => Err(type_err("divided", &a, b)),
        },
        BinOp::Mod => match (&a, b) {
            (Value::Number(x), Value::Number(y)) => {
                let (xi, yi) = (*x as i64, *y as i64);
                if yi == 0 {
                    Err(type_err("divided because the divisor is zero", &a, b))
                } else {
                    Ok(Value::Number(xi.wrapping_rem(yi) as f64))
                }
            }
            _ => Err(type_err("divided", &a, b)),
        },
        BinOp::Eq => Ok(Value::Bool(a == *b)),
        BinOp::Ne => Ok(Value::Bool(a != *b)),
        BinOp::Lt => Ok(Value::Bool(a.compare(b).is_lt())),
        BinOp::Le => Ok(Value::Bool(a.compare(b).is_le())),
        BinOp::Gt => Ok(Value::Bool(a.compare(b).is_gt())),
        BinOp::Ge => Ok(Value::Bool(a.compare(b).is_ge())),
    }
}

pub(crate) fn add(a: Value, b: &Value) -> Result<Value, Error> {
    match (a, b) {
        (Value::Null, b) => Ok(b.clone()),
        (a, Value::Null) => Ok(a),
        (Value::Number(x), Value::Number(y)) => Ok(Value::Number(x + y)),
        (Value::String(x), Value::String(y)) => {
            let mut s = String::with_capacity(x.len() + y.len());
            s.push_str(&x);
            s.push_str(y);
            Ok(Value::String(Rc::from(s)))
        }
        (Value::Array(mut x), Value::Array(y)) => {
            Rc::make_mut(&mut x).extend(y.iter().cloned());
            Ok(Value::Array(x))
        }
        (Value::Object(mut x), Value::Object(y)) => {
            let m = Rc::make_mut(&mut x);
            for (k, v) in y.iter() {
                m.insert(k.clone(), v.clone());
            }
            Ok(Value::Object(x))
        }
        (a, b) => Err(type_err("added", &a, b)),
    }
}

fn deep_merge(a: &Rc<Object>, b: &Object) -> Object {
    let mut out = (**a).clone();
    for (k, bv) in b.iter() {
        let merged = match (out.get(k), bv) {
            (Some(Value::Object(av)), Value::Object(bo)) => Value::object(deep_merge(av, bo)),
            _ => bv.clone(),
        };
        out.insert(k.clone(), merged);
    }
    out
}

fn repeat(s: &str, n: f64) -> Value {
    if n < 0.0 || n.is_nan() {
        Value::Null
    } else {
        Value::String(Rc::from(s.repeat(n as usize)))
    }
}

fn split(s: &str, sep: &str) -> Value {
    if s.is_empty() {
        return Value::array(Vec::new());
    }
    let parts: Vec<Value> = if sep.is_empty() {
        s.chars().map(|c| Value::string(c.encode_utf8(&mut [0; 4]))).collect()
    } else {
        s.split(sep).map(Value::string).collect()
    };
    Value::array(parts)
}
