//! The tree-walking evaluator.
//!
//! Evaluation is written in callback style: [`eval`] pushes each output of an expression
//! into a sink, in order, and stops at the first error. This gives lazy, ordered streams
//! (outputs are delivered before later ones are computed) without allocating intermediate
//! vectors, and makes the nested-loop order required by the specification explicit.

use crate::ast::{Expr, Key};
use crate::builtins;
use crate::error::{Error, Result};
use crate::object::Object;
use crate::ops;
use crate::value::Value;
use std::cell::RefCell;
use std::rc::Rc;

/// The sink that receives each output of an expression.
pub(crate) type Sink<'a> = dyn FnMut(Value) -> Result<()> + 'a;

/// A persistent (shareable, immutable) variable environment.
#[derive(Clone, Default)]
pub(crate) struct Env(Option<Rc<EnvNode>>);

struct EnvNode {
    name: Rc<str>,
    value: Value,
    parent: Env,
}

impl Env {
    pub(crate) fn new() -> Env {
        Env(None)
    }

    fn bind(&self, name: &Rc<str>, value: Value) -> Env {
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

/// Evaluates `e` on `input`, sending every output to `out`.
pub(crate) fn eval(e: &Expr, env: &Env, input: &Value, out: &mut Sink) -> Result<()> {
    match e {
        Expr::Identity => out(input.clone()),
        Expr::Literal(v) => out(v.clone()),
        Expr::Var(name) => match env.lookup(name) {
            Some(v) => out(v.clone()),
            None => Err(Error::runtime(format!("${} is not defined", name))),
        },
        Expr::Index { target, key, opt } => {
            if let Expr::Literal(k) = &**key {
                return eval(target, env, input, &mut |t| match ops::index(&t, k) {
                    Ok(v) => out(v),
                    Err(_) if *opt => Ok(()),
                    Err(err) => Err(err),
                });
            }
            eval(key, env, input, &mut |k| {
                eval(target, env, input, &mut |t| match ops::index(&t, &k) {
                    Ok(v) => out(v),
                    Err(_) if *opt => Ok(()),
                    Err(err) => Err(err),
                })
            })
        }
        Expr::Iterate { target, opt } => eval(target, env, input, &mut |t| match &t {
            Value::Array(a) => {
                for x in a.iter() {
                    out(x.clone())?;
                }
                Ok(())
            }
            Value::Object(o) => {
                for x in o.values() {
                    out(x.clone())?;
                }
                Ok(())
            }
            _ if *opt => Ok(()),
            _ => Err(Error::runtime(format!("Cannot iterate over {}", t.type_name()))),
        }),
        Expr::Slice { target, from, to, opt } => {
            let with_bound = |bound: &Option<Box<Expr>>, f: &mut Sink| -> Result<()> {
                match bound {
                    Some(b) => eval(b, env, input, f),
                    None => f(Value::Null),
                }
            };
            with_bound(from, &mut |a| {
                with_bound(to, &mut |b| {
                    eval(target, env, input, &mut |t| match ops::slice(&t, &a, &b) {
                        Ok(v) => out(v),
                        Err(_) if *opt => Ok(()),
                        Err(err) => Err(err),
                    })
                })
            })
        }
        Expr::Try(inner) => {
            // Errors raised by the downstream sink must propagate, not be swallowed: park
            // them, abort the inner evaluation with a control error, and re-raise afterwards.
            let mut downstream: Option<Error> = None;
            let r = eval(inner, env, input, &mut |v| {
                out(v).map_err(|err| {
                    downstream = Some(err);
                    Error::control()
                })
            });
            match downstream {
                Some(err) => Err(err),
                None => match r {
                    Err(err) if err.kind() == crate::error::ErrorKind::Control => Err(err),
                    _ => Ok(()),
                },
            }
        }
        Expr::Neg(inner) => eval(inner, env, input, &mut |v| match v {
            Value::Number(n) => out(Value::Number(-n)),
            other => Err(Error::runtime(format!("{} cannot be negated", other.type_name()))),
        }),
        Expr::Pipe(l, r) => eval(l, env, input, &mut |v| eval(r, env, &v, out)),
        Expr::Comma(l, r) => {
            eval(l, env, input, out)?;
            eval(r, env, input, out)
        }
        Expr::Binary(op, l, r) => {
            if let Expr::Literal(b) = &**r {
                return eval(l, env, input, &mut |a| out(ops::binary(*op, &a, b)?));
            }
            eval(r, env, input, &mut |b| eval(l, env, input, &mut |a| out(ops::binary(*op, &a, &b)?)))
        }
        Expr::And(l, r) => eval(l, env, input, &mut |a| {
            if !a.is_truthy() {
                out(Value::Bool(false))
            } else {
                eval(r, env, input, &mut |b| out(Value::Bool(b.is_truthy())))
            }
        }),
        Expr::Or(l, r) => eval(l, env, input, &mut |a| {
            if a.is_truthy() {
                out(Value::Bool(true))
            } else {
                eval(r, env, input, &mut |b| out(Value::Bool(b.is_truthy())))
            }
        }),
        Expr::Array(inner) => {
            let mut items = Vec::new();
            if let Some(inner) = inner {
                eval(inner, env, input, &mut |v| {
                    items.push(v);
                    Ok(())
                })?;
            }
            out(Value::array(items))
        }
        Expr::Object(entries) => {
            let acc = RefCell::new(Vec::with_capacity(entries.len()));
            object_entries(entries, env, input, &acc, out)
        }
        Expr::If { cond, then, otherwise } => eval(cond, env, input, &mut |c| {
            if c.is_truthy() {
                eval(then, env, input, out)
            } else {
                match otherwise {
                    Some(e) => eval(e, env, input, out),
                    None => out(input.clone()),
                }
            }
        }),
        Expr::Reduce { source, name, init, update } => eval(init, env, input, &mut |init| {
            let mut acc = init;
            eval(source, env, input, &mut |v| {
                let inner = env.bind(name, v);
                let mut last = None;
                eval(update, &inner, &acc, &mut |r| {
                    last = Some(r);
                    Ok(())
                })?;
                acc = last.unwrap_or(Value::Null);
                Ok(())
            })?;
            out(acc)
        }),
        Expr::As { source, name, body } => {
            eval(source, env, input, &mut |v| eval(body, &env.bind(name, v), input, out))
        }
        Expr::Call(b, args) => builtins::call(*b, args, env, input, out),
    }
}

/// Builds objects entry by entry: first entry is the outermost loop, and within an entry the
/// key stream is outer and the value stream inner. `acc` holds the entries chosen so far.
fn object_entries(
    entries: &[(Key, Expr)],
    env: &Env,
    input: &Value,
    acc: &RefCell<Vec<(Rc<str>, Value)>>,
    out: &mut Sink,
) -> Result<()> {
    let Some(((key, value), rest)) = entries.split_first() else {
        let items = acc.borrow();
        let mut obj = Object::with_capacity(items.len());
        for (k, v) in items.iter() {
            obj.insert(k.clone(), v.clone());
        }
        drop(items);
        return out(Value::object(obj));
    };
    let with_key = |k: Rc<str>, out: &mut Sink| -> Result<()> {
        eval(value, env, input, &mut |v| {
            acc.borrow_mut().push((k.clone(), v));
            let r = object_entries(rest, env, input, acc, out);
            acc.borrow_mut().pop();
            r
        })
    };
    match key {
        Key::Literal(k) => with_key(k.clone(), out),
        Key::Computed(ke) => eval(ke, env, input, &mut |kv| match kv {
            Value::String(s) => with_key(s, out),
            other => Err(Error::runtime(format!("Object keys must be strings, not {}", other.type_name()))),
        }),
    }
}
