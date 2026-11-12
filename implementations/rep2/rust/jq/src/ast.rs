//! The filter syntax tree.

use std::rc::Rc;

use crate::value::Value;

/// Binary operators with "right operand is the outer loop" semantics.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BinOp {
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

/// Builtin functions of the supported language subset.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Builtin {
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
    /// Resolves a builtin by name and argument count.
    pub fn lookup(name: &str, arity: usize) -> Option<Builtin> {
        Some(match (name, arity) {
            ("empty", 0) => Builtin::Empty,
            ("error", 0) => Builtin::Error0,
            ("error", 1) => Builtin::Error1,
            ("not", 0) => Builtin::Not,
            ("length", 0) => Builtin::Length,
            ("keys", 0) => Builtin::Keys,
            ("has", 1) => Builtin::Has,
            ("type", 0) => Builtin::Type,
            ("add", 0) => Builtin::Add,
            ("select", 1) => Builtin::Select,
            ("map", 1) => Builtin::Map,
            ("sort", 0) => Builtin::Sort,
            ("sort_by", 1) => Builtin::SortBy,
            ("group_by", 1) => Builtin::GroupBy,
            ("unique", 0) => Builtin::Unique,
            ("reverse", 0) => Builtin::Reverse,
            ("min", 0) => Builtin::Min,
            ("max", 0) => Builtin::Max,
            ("tostring", 0) => Builtin::ToString,
            ("tonumber", 0) => Builtin::ToNumber,
            _ => return None,
        })
    }
}

/// The key of an object-construction entry.
#[derive(Debug)]
pub enum ObjKey {
    /// A literal key (`a`, `"a"`, or the shorthand forms).
    Literal(Rc<str>),
    /// A computed key `(expr)`.
    Computed(Expr),
}

/// A filter expression.
#[derive(Debug)]
pub enum Expr {
    Identity,
    Literal(Value),
    Var(Rc<str>),
    Index { target: Box<Expr>, index: Box<Expr>, optional: bool },
    Iterate { target: Box<Expr>, optional: bool },
    Slice { target: Box<Expr>, from: Option<Box<Expr>>, to: Option<Box<Expr>>, optional: bool },
    Try(Box<Expr>),
    Neg(Box<Expr>),
    Binary(BinOp, Box<Expr>, Box<Expr>),
    And(Box<Expr>, Box<Expr>),
    Or(Box<Expr>, Box<Expr>),
    Pipe(Box<Expr>, Box<Expr>),
    Comma(Box<Expr>, Box<Expr>),
    Array(Option<Box<Expr>>),
    Object(Vec<(ObjKey, Expr)>),
    If { cond: Box<Expr>, then: Box<Expr>, otherwise: Box<Expr> },
    As { source: Box<Expr>, name: Rc<str>, body: Box<Expr> },
    Reduce { source: Box<Expr>, name: Rc<str>, init: Box<Expr>, update: Box<Expr> },
    Call(Builtin, Vec<Expr>),
}
