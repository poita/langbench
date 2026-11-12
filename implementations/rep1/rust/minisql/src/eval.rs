//! Interpreter for bound expressions.

use std::borrow::Cow;

use crate::ast::{AggFunc, BinOp};
use crate::binder::BExpr;
use crate::like::like;
use crate::table::Row;
use crate::value::Value;

/// The row (pair) an expression is evaluated against.
///
/// Column `i` is `left[i]` when `i < nleft`, otherwise `right[i - nleft]`.
#[derive(Clone, Copy)]
pub struct Env<'a> {
    /// Columns of the first table.
    pub left: &'a [Value],
    /// Columns of the second table (empty with one table).
    pub right: &'a [Value],
    /// Number of columns of the first table.
    pub nleft: usize,
}

impl<'a> Env<'a> {
    #[inline]
    pub fn get(&self, i: usize) -> &'a Value {
        if i < self.nleft {
            &self.left[i]
        } else {
            &self.right[i - self.nleft]
        }
    }
}

/// The candidate rows of a query: row indexes refer into `left` and `right`.
pub struct Source<'a> {
    /// Rows of the first table (a single empty row for SELECT without FROM).
    pub left: &'a [Row],
    /// Rows of the second table (empty with fewer than two tables).
    pub right: &'a [Row],
    /// Number of columns of the first table.
    pub nleft: usize,
}

impl<'a> Source<'a> {
    /// Environment for the candidate `(left index, right index)`.
    pub fn env(&self, (l, r): (usize, usize)) -> Env<'a> {
        Env {
            left: &self.left[l],
            right: self.right.get(r).map_or(&[][..], |row| &row[..]),
            nleft: self.nleft,
        }
    }
}

/// The rows of one group, for aggregate evaluation.
#[derive(Clone, Copy)]
pub struct Group<'a> {
    /// Source of the rows.
    pub source: &'a Source<'a>,
    /// Member candidates, in candidate order.
    pub members: &'a [(usize, usize)],
}

/// Evaluates `e` against `env`. `group` must be given if `e` contains
/// aggregate calls.
pub fn eval(e: &BExpr, env: &Env<'_>, group: Option<&Group<'_>>) -> Value {
    match e {
        BExpr::Const(v) => v.clone(),
        BExpr::Col(i) => env.get(*i).clone(),
        BExpr::Neg(x) => match eval(x, env, group) {
            Value::Int(i) => Value::Int(i.wrapping_neg()),
            _ => Value::Null,
        },
        BExpr::Not(x) => match eval(x, env, group).truth() {
            None => Value::Null,
            Some(b) => Value::from_bool(!b),
        },
        BExpr::IsNull(x, negated) => Value::from_bool(eval(x, env, group).is_null() != *negated),
        BExpr::Like(x, p, negated) => {
            let (s, p) = (eval(x, env, group), eval(p, env, group));
            match (as_text(&s), as_text(&p)) {
                (Some(s), Some(p)) => Value::from_bool(like(&s, &p) != *negated),
                _ => Value::Null,
            }
        }
        BExpr::Binary(op, a, b) => eval_binary(*op, a, b, env, group),
        BExpr::Agg(func, arg) => {
            let g = group.expect("aggregate evaluated outside a group");
            eval_agg(*func, arg.as_deref(), g)
        }
    }
}

fn as_text(v: &Value) -> Option<Cow<'_, str>> {
    match v {
        Value::Null => None,
        Value::Text(s) => Some(Cow::Borrowed(s)),
        other => Some(Cow::Owned(other.to_string())),
    }
}

fn eval_binary(
    op: BinOp,
    a: &BExpr,
    b: &BExpr,
    env: &Env<'_>,
    group: Option<&Group<'_>>,
) -> Value {
    use BinOp::*;
    match op {
        And => {
            let x = eval(a, env, group).truth();
            if x == Some(false) {
                return Value::Int(0);
            }
            match (x, eval(b, env, group).truth()) {
                (_, Some(false)) => Value::Int(0),
                (Some(true), Some(true)) => Value::Int(1),
                _ => Value::Null,
            }
        }
        Or => {
            let x = eval(a, env, group).truth();
            if x == Some(true) {
                return Value::Int(1);
            }
            match (x, eval(b, env, group).truth()) {
                (_, Some(true)) => Value::Int(1),
                (Some(false), Some(false)) => Value::Int(0),
                _ => Value::Null,
            }
        }
        _ => {
            let (x, y) = (eval(a, env, group), eval(b, env, group));
            if x.is_null() || y.is_null() {
                return Value::Null;
            }
            match op {
                Add | Sub | Mul | Div | Rem => match (x, y) {
                    (Value::Int(p), Value::Int(q)) => match op {
                        Add => Value::Int(p.wrapping_add(q)),
                        Sub => Value::Int(p.wrapping_sub(q)),
                        Mul => Value::Int(p.wrapping_mul(q)),
                        Div if q == 0 => Value::Null,
                        Div => Value::Int(p.wrapping_div(q)),
                        _ if q == 0 => Value::Null,
                        _ => Value::Int(p.wrapping_rem(q)),
                    },
                    _ => Value::Null, // arithmetic on TEXT/REAL is not part of the dialect
                },
                _ => {
                    let ord = x.compare(&y);
                    Value::from_bool(match op {
                        Eq => ord.is_eq(),
                        Ne => ord.is_ne(),
                        Lt => ord.is_lt(),
                        Le => ord.is_le(),
                        Gt => ord.is_gt(),
                        _ => ord.is_ge(),
                    })
                }
            }
        }
    }
}

fn eval_agg(func: AggFunc, arg: Option<&BExpr>, g: &Group<'_>) -> Value {
    let Some(arg) = arg else {
        return Value::Int(g.members.len() as i64); // COUNT(*)
    };
    let values = g
        .members
        .iter()
        .map(|&m| eval(arg, &g.source.env(m), None))
        .filter(|v| !v.is_null());
    match func {
        AggFunc::Count => Value::Int(values.count() as i64),
        AggFunc::Sum => {
            let mut sum: Option<i64> = None;
            for v in values {
                if let Value::Int(i) = v {
                    sum = Some(sum.unwrap_or(0).wrapping_add(i));
                }
            }
            sum.map_or(Value::Null, Value::Int)
        }
        AggFunc::Min => values.min_by(|a, b| a.compare(b)).unwrap_or(Value::Null),
        // `max_by` returns the last maximum; equal values are interchangeable.
        AggFunc::Max => values.max_by(|a, b| a.compare(b)).unwrap_or(Value::Null),
        AggFunc::Avg => {
            let (mut sum, mut count) = (0i128, 0i128);
            for v in values {
                if let Value::Int(i) = v {
                    sum += i as i128;
                    count += 1;
                }
            }
            if count == 0 {
                return Value::Null;
            }
            // Hundredths, rounded half away from zero.
            let h = (200 * sum.abs() + count) / (2 * count);
            Value::Real(if sum < 0 { -h } else { h } as i64)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run(e: BExpr) -> Value {
        eval(&e, &Env { left: &[], right: &[], nleft: 0 }, None)
    }

    fn int(i: i64) -> Box<BExpr> {
        Box::new(BExpr::Const(Value::Int(i)))
    }

    fn null() -> Box<BExpr> {
        Box::new(BExpr::Const(Value::Null))
    }

    #[test]
    fn division_semantics() {
        assert_eq!(run(BExpr::Binary(BinOp::Div, int(-7), int(2))), Value::Int(-3));
        assert_eq!(run(BExpr::Binary(BinOp::Rem, int(-7), int(3))), Value::Int(-1));
        assert_eq!(run(BExpr::Binary(BinOp::Rem, int(7), int(-3))), Value::Int(1));
        assert_eq!(run(BExpr::Binary(BinOp::Div, int(1), int(0))), Value::Null);
        assert_eq!(run(BExpr::Binary(BinOp::Add, int(1), null())), Value::Null);
    }

    #[test]
    fn three_valued_logic() {
        let and = |a, b| run(BExpr::Binary(BinOp::And, a, b));
        let or = |a, b| run(BExpr::Binary(BinOp::Or, a, b));
        assert_eq!(and(int(1), null()), Value::Null);
        assert_eq!(and(int(0), null()), Value::Int(0));
        assert_eq!(and(null(), int(0)), Value::Int(0));
        assert_eq!(or(int(0), null()), Value::Null);
        assert_eq!(or(null(), int(5)), Value::Int(1));
        assert_eq!(run(BExpr::Not(null())), Value::Null);
    }

    #[test]
    fn mixed_type_comparison() {
        let t = Box::new(BExpr::Const(Value::text("a")));
        assert_eq!(run(BExpr::Binary(BinOp::Lt, int(1), t.clone())), Value::Int(1));
        assert_eq!(run(BExpr::Binary(BinOp::Eq, int(1), t)), Value::Int(0));
    }
}
