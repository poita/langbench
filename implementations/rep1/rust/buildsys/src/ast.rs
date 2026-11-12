//! Syntax trees for KBL build files.

use crate::value::Value;
use std::rc::Rc;

/// A piece of a double-quoted string literal.
#[derive(Debug, Clone)]
pub enum Part {
    Lit(Vec<u8>),
    Interp(Expr),
}

/// Unary operators.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UnOp {
    Not,
    Neg,
}

/// Binary operators (the pipe is desugared into a call by the parser).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BinOp {
    Or,
    And,
    Eq,
    Ne,
    Lt,
    Le,
    Gt,
    Ge,
    Concat,
    StrCat,
    Add,
    Sub,
    Mul,
    Div,
    Rem,
}

impl BinOp {
    /// The operator's source spelling.
    pub fn symbol(self) -> &'static str {
        match self {
            BinOp::Or => "||",
            BinOp::And => "&&",
            BinOp::Eq => "==",
            BinOp::Ne => "!=",
            BinOp::Lt => "<",
            BinOp::Le => "<=",
            BinOp::Gt => ">",
            BinOp::Ge => ">=",
            BinOp::Concat => "++",
            BinOp::StrCat => "~",
            BinOp::Add => "+",
            BinOp::Sub => "-",
            BinOp::Mul => "*",
            BinOp::Div => "/",
            BinOp::Rem => "%",
        }
    }
}

/// An expression.
#[derive(Debug, Clone)]
pub enum Expr {
    /// A constant (integer, boolean or string without interpolation).
    Lit(Value),
    /// A double-quoted literal with at least one interpolation.
    Interp(Vec<Part>),
    Var(String),
    List(Vec<Expr>),
    Unary(UnOp, Box<Expr>),
    Binary(BinOp, Box<Expr>, Box<Expr>),
    Call(String, Vec<Expr>),
    Index(Box<Expr>, Box<Expr>),
}

/// A `use` argument.
#[derive(Debug, Clone)]
pub enum Arg {
    Positional(Expr),
    Keyword(String, Expr),
}

/// A rule parameter.
#[derive(Debug, Clone)]
pub struct Param {
    pub name: String,
    pub default: Option<Expr>,
}

/// A field of a `step` block.
#[derive(Debug, Clone)]
pub enum Field {
    Out(Expr),
    In(Expr),
    After(Expr),
    Cost(Expr),
    Depfile(Expr),
    Cmd { name: String, args: Vec<Expr> },
}

/// A statement.
#[derive(Debug, Clone)]
pub enum Stmt {
    Let(String, Expr),
    Set(String, Expr),
    Include(Expr),
    Abort(Expr),
    Default(Expr),
    Phony(String, Expr),
    Use { name: String, args: Vec<Arg> },
    When { branches: Vec<(Expr, Vec<Stmt>)>, otherwise: Option<Vec<Stmt>> },
    Each { index: Option<String>, name: String, subject: Expr, body: Vec<Stmt> },
    Rule { name: String, params: Vec<Param>, body: Rc<Vec<Stmt>> },
    Step(Vec<Field>),
}
