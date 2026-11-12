//! The built-in procedures.

use std::cmp::Ordering;

use crate::error::{Error, Result};
use crate::eval::Interpreter;
use crate::numeric;
use crate::printer;
use crate::value::Value;

/// The implementation of a primitive.
pub(crate) enum Imp {
    /// An ordinary function of the evaluated arguments.
    Fn(fn(&mut Interpreter<'_>, &[Value]) -> Result<Value>),
    /// `apply`, which the evaluator handles itself so the call stays a tail call.
    Apply,
}

/// A built-in procedure: its name, accepted argument counts and code.
pub struct Primitive {
    /// The name the primitive is bound to in the global environment.
    pub name: &'static str,
    min: usize,
    max: Option<usize>,
    pub(crate) imp: Imp,
}

impl Primitive {
    pub(crate) fn check_arity(&self, n: usize) -> Result<()> {
        if n < self.min || self.max.is_some_and(|m| n > m) {
            Err(Error::ArityError)
        } else {
            Ok(())
        }
    }
}

const fn prim(
    name: &'static str,
    min: usize,
    max: Option<usize>,
    f: fn(&mut Interpreter<'_>, &[Value]) -> Result<Value>,
) -> Primitive {
    Primitive { name, min, max, imp: Imp::Fn(f) }
}

/// Every primitive in the initial global environment.
pub(crate) static PRIMITIVES: &[Primitive] = &[
    prim("+", 0, None, add),
    prim("*", 0, None, mul),
    prim("-", 1, None, sub),
    prim("quotient", 2, Some(2), quotient),
    prim("remainder", 2, Some(2), remainder),
    prim("=", 2, None, |_, a| compare(a, |o| o == Ordering::Equal)),
    prim("<", 2, None, |_, a| compare(a, |o| o == Ordering::Less)),
    prim(">", 2, None, |_, a| compare(a, |o| o == Ordering::Greater)),
    prim("<=", 2, None, |_, a| compare(a, |o| o != Ordering::Greater)),
    prim(">=", 2, None, |_, a| compare(a, |o| o != Ordering::Less)),
    prim("cons", 2, Some(2), |_, a| Ok(Value::cons(a[0].clone(), a[1].clone()))),
    prim("car", 1, Some(1), |_, a| match &a[0] {
        Value::Pair(p) => Ok(p.car.clone()),
        _ => Err(Error::TypeError),
    }),
    prim("cdr", 1, Some(1), |_, a| match &a[0] {
        Value::Pair(p) => Ok(p.cdr.clone()),
        _ => Err(Error::TypeError),
    }),
    prim("list", 0, None, |_, a| Ok(Value::list(a.iter().cloned()))),
    prim("null?", 1, Some(1), |_, a| Ok(Value::Bool(matches!(a[0], Value::Nil)))),
    prim("pair?", 1, Some(1), |_, a| Ok(Value::Bool(matches!(a[0], Value::Pair(_))))),
    prim("not", 1, Some(1), |_, a| Ok(Value::Bool(!a[0].is_truthy()))),
    prim("number?", 1, Some(1), |_, a| Ok(Value::Bool(a[0].is_integer()))),
    prim("boolean?", 1, Some(1), |_, a| Ok(Value::Bool(matches!(a[0], Value::Bool(_))))),
    prim("string?", 1, Some(1), |_, a| Ok(Value::Bool(matches!(a[0], Value::Str(_))))),
    prim("symbol?", 1, Some(1), |_, a| Ok(Value::Bool(matches!(a[0], Value::Sym(_))))),
    prim("procedure?", 1, Some(1), |_, a| {
        Ok(Value::Bool(matches!(a[0], Value::Closure(_) | Value::Prim(_))))
    }),
    prim("eq?", 2, Some(2), |_, a| Ok(Value::Bool(a[0].is_eq(&a[1])))),
    prim("equal?", 2, Some(2), |_, a| Ok(Value::Bool(a[0].is_equal(&a[1])))),
    Primitive { name: "apply", min: 2, max: None, imp: Imp::Apply },
    prim("error", 0, None, |_, _| Err(Error::UserError)),
    prim("string-append", 0, None, string_append),
    prim("string-length", 1, Some(1), |_, a| match &a[0] {
        Value::Str(s) => Ok(Value::Int(s.chars().count() as i64)),
        _ => Err(Error::TypeError),
    }),
    prim("number->string", 1, Some(1), |_, a| {
        if a[0].is_integer() {
            Ok(Value::string(&printer::write_string(&a[0])))
        } else {
            Err(Error::TypeError)
        }
    }),
    prim("symbol->string", 1, Some(1), |_, a| match &a[0] {
        Value::Sym(s) => Ok(Value::string(&s.name())),
        _ => Err(Error::TypeError),
    }),
    prim("display", 1, Some(1), |interp, a| {
        interp.write_str(&printer::display_string(&a[0]));
        Ok(Value::Void)
    }),
    prim("newline", 0, Some(0), |interp, _| {
        interp.write_str("\n");
        Ok(Value::Void)
    }),
];

/// Type-checks that every argument is an integer.
fn check_ints(args: &[Value]) -> Result<()> {
    if args.iter().all(Value::is_integer) {
        Ok(())
    } else {
        Err(Error::TypeError)
    }
}

fn add(_: &mut Interpreter<'_>, args: &[Value]) -> Result<Value> {
    check_ints(args)?;
    Ok(args.iter().fold(Value::Int(0), |acc, x| numeric::add(&acc, x)))
}

fn mul(_: &mut Interpreter<'_>, args: &[Value]) -> Result<Value> {
    check_ints(args)?;
    Ok(args.iter().fold(Value::Int(1), |acc, x| numeric::mul(&acc, x)))
}

fn sub(_: &mut Interpreter<'_>, args: &[Value]) -> Result<Value> {
    check_ints(args)?;
    if args.len() == 1 {
        return Ok(numeric::neg(&args[0]));
    }
    Ok(args[1..].iter().fold(args[0].clone(), |acc, x| numeric::sub(&acc, x)))
}

fn quotient(_: &mut Interpreter<'_>, args: &[Value]) -> Result<Value> {
    check_ints(args)?;
    numeric::div_rem(&args[0], &args[1]).map(|(q, _)| q)
}

fn remainder(_: &mut Interpreter<'_>, args: &[Value]) -> Result<Value> {
    check_ints(args)?;
    numeric::div_rem(&args[0], &args[1]).map(|(_, r)| r)
}

fn compare(args: &[Value], holds: fn(Ordering) -> bool) -> Result<Value> {
    check_ints(args)?;
    Ok(Value::Bool(args.windows(2).all(|w| holds(numeric::cmp(&w[0], &w[1])))))
}

fn string_append(_: &mut Interpreter<'_>, args: &[Value]) -> Result<Value> {
    let mut out = String::new();
    for a in args {
        match a {
            Value::Str(s) => out.push_str(s),
            _ => return Err(Error::TypeError),
        }
    }
    Ok(Value::string(&out))
}
