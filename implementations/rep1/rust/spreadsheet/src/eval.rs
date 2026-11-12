//! Evaluation of formula syntax trees.
//!
//! Evaluation never recurses from cell to cell: references read the value
//! currently stored for the named cell through a [`CellSource`].

use crate::ast::{Aggregate, Arg, BinOp, Expr};
use crate::cell::CellRef;
use crate::value::{format_number, ErrorCode, Value};
use std::cmp::Ordering;
use std::rc::Rc;

/// Something that can supply the current value of a cell.
pub trait CellSource {
    /// The stored value of `cell`; [`Value::Empty`] if the cell is empty.
    fn value(&self, cell: CellRef) -> Value;
}

/// Evaluates `expr` against the values in `cells`.
///
/// The result may be [`Value::Empty`] (for example for a bare reference to an
/// empty cell); the caller decides how to store that.
pub fn evaluate(expr: &Expr, cells: &dyn CellSource) -> Value {
    match expr {
        Expr::Number(n) => Value::Number(*n),
        Expr::Str(s) => Value::Str(s.clone()),
        Expr::Ref(c) => cells.value(*c),
        Expr::Error(e) => Value::Error(*e),
        Expr::Neg(e) => match number(evaluate(e, cells)) {
            Ok(n) => Value::Number(-n),
            Err(e) => Value::Error(e),
        },
        Expr::Binary(op, a, b) => binary(*op, a, b, cells),
        Expr::If(c, a, b) => match number(evaluate(c, cells)) {
            Err(e) => Value::Error(e),
            Ok(n) if n != 0.0 => evaluate(a, cells),
            Ok(_) => evaluate(b, cells),
        },
        Expr::Call(func, args) => aggregate(*func, args, cells),
    }
}

/// Coerces a value to a number: empty is 0, strings are `#VALUE!`.
fn number(v: Value) -> Result<f64, ErrorCode> {
    match v {
        Value::Number(n) => Ok(n),
        Value::Empty => Ok(0.0),
        Value::Str(_) => Err(ErrorCode::Value),
        Value::Error(e) => Err(e),
    }
}

fn binary(op: BinOp, a: &Expr, b: &Expr, cells: &dyn CellSource) -> Value {
    match op {
        BinOp::Add | BinOp::Sub | BinOp::Mul | BinOp::Div => {
            let x = match number(evaluate(a, cells)) {
                Ok(x) => x,
                Err(e) => return Value::Error(e),
            };
            let y = match number(evaluate(b, cells)) {
                Ok(y) => y,
                Err(e) => return Value::Error(e),
            };
            let r = match op {
                BinOp::Add => x + y,
                BinOp::Sub => x - y,
                BinOp::Mul => x * y,
                _ => {
                    if y == 0.0 {
                        return Value::Error(ErrorCode::DivZero);
                    }
                    x / y
                }
            };
            if r.is_finite() {
                Value::Number(r)
            } else {
                Value::Error(ErrorCode::Value)
            }
        }
        BinOp::Concat => {
            let x = evaluate(a, cells);
            if let Value::Error(_) = x {
                return x;
            }
            let y = evaluate(b, cells);
            if let Value::Error(_) = y {
                return y;
            }
            let mut s = String::new();
            push_text(&mut s, &x);
            push_text(&mut s, &y);
            Value::Str(Rc::from(s))
        }
        _ => {
            let x = evaluate(a, cells);
            if let Value::Error(_) = x {
                return x;
            }
            let y = evaluate(b, cells);
            if let Value::Error(_) = y {
                return y;
            }
            compare(op, x, y)
        }
    }
}

fn push_text(out: &mut String, v: &Value) {
    match v {
        Value::Str(s) => out.push_str(s),
        Value::Number(n) => out.push_str(&format_number(*n)),
        Value::Empty | Value::Error(_) => {}
    }
}

fn compare(op: BinOp, x: Value, y: Value) -> Value {
    let (x, y) = match (x, y) {
        (Value::Empty, Value::Empty) => (Value::Number(0.0), Value::Number(0.0)),
        (Value::Empty, y @ Value::Number(_)) => (Value::Number(0.0), y),
        (Value::Empty, y @ Value::Str(_)) => (Value::string(""), y),
        (x @ Value::Number(_), Value::Empty) => (x, Value::Number(0.0)),
        (x @ Value::Str(_), Value::Empty) => (x, Value::string("")),
        pair => pair,
    };
    let ord = match (&x, &y) {
        (Value::Number(p), Value::Number(q)) => p.partial_cmp(q),
        // `str` ordering is bytewise, which equals code point order for UTF-8.
        (Value::Str(p), Value::Str(q)) => Some(p.as_bytes().cmp(q.as_bytes())),
        _ => {
            return match op {
                BinOp::Eq => Value::Number(0.0),
                BinOp::Ne => Value::Number(1.0),
                _ => Value::Error(ErrorCode::Value),
            }
        }
    };
    let Some(ord) = ord else {
        return Value::Error(ErrorCode::Value);
    };
    let truth = match op {
        BinOp::Eq => ord == Ordering::Equal,
        BinOp::Ne => ord != Ordering::Equal,
        BinOp::Lt => ord == Ordering::Less,
        BinOp::Gt => ord == Ordering::Greater,
        BinOp::Le => ord != Ordering::Greater,
        _ => ord != Ordering::Less,
    };
    Value::Number(if truth { 1.0 } else { 0.0 })
}

/// Running state of an aggregate over the collected numbers.
struct Acc {
    count: usize,
    sum: f64,
    min: f64,
    max: f64,
}

impl Acc {
    fn add(&mut self, n: f64) {
        if self.count == 0 {
            self.min = n;
            self.max = n;
        } else {
            if n < self.min {
                self.min = n;
            }
            if n > self.max {
                self.max = n;
            }
        }
        self.count += 1;
        self.sum += n;
    }
}

fn aggregate(func: Aggregate, args: &[Arg], cells: &dyn CellSource) -> Value {
    let mut acc = Acc { count: 0, sum: 0.0, min: 0.0, max: 0.0 };
    for arg in args {
        match arg {
            Arg::Range(range) => {
                for cell in range.cells() {
                    match cells.value(cell) {
                        Value::Number(n) => acc.add(n),
                        Value::Error(e) => return Value::Error(e),
                        Value::Empty | Value::Str(_) => {}
                    }
                }
            }
            Arg::Expr(e) => match evaluate(e, cells) {
                Value::Number(n) => acc.add(n),
                Value::Error(e) => return Value::Error(e),
                Value::Str(_) => return Value::Error(ErrorCode::Value),
                Value::Empty => {}
            },
        }
    }
    let finite = |n: f64| {
        if n.is_finite() {
            Value::Number(n)
        } else {
            Value::Error(ErrorCode::Value)
        }
    };
    match func {
        Aggregate::Count => Value::Number(acc.count as f64),
        Aggregate::Sum => finite(acc.sum),
        Aggregate::Min => Value::Number(acc.min),
        Aggregate::Max => Value::Number(acc.max),
        Aggregate::Avg => {
            if acc.count == 0 {
                Value::Error(ErrorCode::DivZero)
            } else {
                finite(acc.sum / acc.count as f64)
            }
        }
    }
}
