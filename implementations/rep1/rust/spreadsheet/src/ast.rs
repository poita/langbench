//! The syntax tree of a parsed formula.

use crate::cell::{CellRef, Range};
use crate::value::ErrorCode;
use std::rc::Rc;

/// A binary operator.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum BinOp {
    /// `+`
    Add,
    /// `-`
    Sub,
    /// `*`
    Mul,
    /// `/`
    Div,
    /// `&` (string concatenation)
    Concat,
    /// `=`
    Eq,
    /// `<>`
    Ne,
    /// `<`
    Lt,
    /// `>`
    Gt,
    /// `<=`
    Le,
    /// `>=`
    Ge,
}

/// An aggregate function.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Aggregate {
    /// `SUM`
    Sum,
    /// `MIN`
    Min,
    /// `MAX`
    Max,
    /// `AVG`
    Avg,
    /// `COUNT`
    Count,
}

/// An argument of an aggregate function.
#[derive(Clone, PartialEq, Debug)]
pub enum Arg {
    /// An ordinary expression.
    Expr(Expr),
    /// A `REF:REF` range.
    Range(Range),
}

/// An expression node.
#[derive(Clone, PartialEq, Debug)]
pub enum Expr {
    /// A numeric literal.
    Number(f64),
    /// A string literal.
    Str(Rc<str>),
    /// A reference to a single cell.
    Ref(CellRef),
    /// A constant error. The parser yields `Error(Ref)` as the whole tree of
    /// a formula that contains an invalid reference.
    Error(ErrorCode),
    /// Unary minus.
    Neg(Box<Expr>),
    /// A binary operation.
    Binary(BinOp, Box<Expr>, Box<Expr>),
    /// `IF(condition, then, else)`.
    If(Box<Expr>, Box<Expr>, Box<Expr>),
    /// An aggregate function call.
    Call(Aggregate, Vec<Arg>),
}

impl Expr {
    /// Appends every cell this expression names (ranges expanded, both `IF`
    /// branches included) to `out`. Cells may appear more than once.
    pub fn collect_dependencies(&self, out: &mut Vec<CellRef>) {
        match self {
            Expr::Number(_) | Expr::Str(_) | Expr::Error(_) => {}
            Expr::Ref(c) => out.push(*c),
            Expr::Neg(e) => e.collect_dependencies(out),
            Expr::Binary(_, a, b) => {
                a.collect_dependencies(out);
                b.collect_dependencies(out);
            }
            Expr::If(c, a, b) => {
                c.collect_dependencies(out);
                a.collect_dependencies(out);
                b.collect_dependencies(out);
            }
            Expr::Call(_, args) => {
                for arg in args {
                    match arg {
                        Arg::Expr(e) => e.collect_dependencies(out),
                        Arg::Range(r) => out.extend(r.cells()),
                    }
                }
            }
        }
    }
}
