//! The filter syntax tree.

use crate::value::Value;
use std::rc::Rc;

/// Binary arithmetic and comparison operators.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum BinOp {
    Add,
    Sub,
    Mul,
    Div,
    Mod,
    Eq,
    Ne,
    Lt,
    Le,
    Gt,
    Ge,
}

/// Builtin functions, resolved by name and arity at parse time.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Builtin {
    Empty,
    Error0,
    Error1,
    Not,
    Length,
    Keys,
    Has,
    Type,
    Add,
    Select,
    Map,
    Sort,
    SortBy,
    GroupBy,
    Unique,
    Reverse,
    Min,
    Max,
    ToString,
    ToNumber,
}

impl Builtin {
    /// Resolves `name/arity`.
    pub(crate) fn lookup(name: &str, arity: usize) -> Option<Builtin> {
        use Builtin::*;
        Some(match (name, arity) {
            ("empty", 0) => Empty,
            ("error", 0) => Error0,
            ("error", 1) => Error1,
            ("not", 0) => Not,
            ("length", 0) => Length,
            ("keys", 0) => Keys,
            ("has", 1) => Has,
            ("type", 0) => Type,
            ("add", 0) => Add,
            ("select", 1) => Select,
            ("map", 1) => Map,
            ("sort", 0) => Sort,
            ("sort_by", 1) => SortBy,
            ("group_by", 1) => GroupBy,
            ("unique", 0) => Unique,
            ("reverse", 0) => Reverse,
            ("min", 0) => Min,
            ("max", 0) => Max,
            ("tostring", 0) => ToString,
            ("tonumber", 0) => ToNumber,
            _ => return None,
        })
    }
}

/// An object-construction key.
#[derive(Debug, Clone)]
pub(crate) enum Key {
    /// A literal key (`a:` or `"a":`).
    Literal(Rc<str>),
    /// A computed key (`(expr):`).
    Computed(Expr),
}

/// A filter expression.
#[derive(Debug, Clone)]
pub(crate) enum Expr {
    Identity,
    Literal(Value),
    Var(Rc<str>),
    /// `target[key]` / `target.key`
    Index { target: Box<Expr>, key: Box<Expr>, opt: bool },
    /// `target[]`
    Iterate { target: Box<Expr>, opt: bool },
    /// `target[from:to]`
    Slice { target: Box<Expr>, from: Option<Box<Expr>>, to: Option<Box<Expr>>, opt: bool },
    /// `expr?` as `try`
    Try(Box<Expr>),
    Neg(Box<Expr>),
    Pipe(Box<Expr>, Box<Expr>),
    Comma(Box<Expr>, Box<Expr>),
    Binary(BinOp, Box<Expr>, Box<Expr>),
    And(Box<Expr>, Box<Expr>),
    Or(Box<Expr>, Box<Expr>),
    Array(Option<Box<Expr>>),
    Object(Vec<(Key, Expr)>),
    If { cond: Box<Expr>, then: Box<Expr>, otherwise: Option<Box<Expr>> },
    Reduce { source: Box<Expr>, name: Rc<str>, init: Box<Expr>, update: Box<Expr> },
    As { source: Box<Expr>, name: Rc<str>, body: Box<Expr> },
    Call(Builtin, Vec<Expr>),
}
