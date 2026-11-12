//! Syntax trees for KBL. Variants mirror the grammar productions one to one.

#![allow(missing_docs)]

use std::rc::Rc;

pub use crate::lexer::Op;

/// A byte string shared by reference.
pub type Bytes = Rc<Vec<u8>>;

/// A part of a double-quoted literal.
#[derive(Debug, Clone)]
pub enum Part {
    Lit(Vec<u8>),
    Expr(Expr),
}

/// An expression.
#[derive(Debug, Clone)]
pub enum Expr {
    Int(i64),
    Bool(bool),
    Str(Bytes),
    Interp(Vec<Part>),
    Var(String),
    List(Vec<Expr>),
    Unary(Op, Box<Expr>),
    Binary(Op, Box<Expr>, Box<Expr>),
    Call(String, Vec<Expr>),
    Index(Box<Expr>, Box<Expr>),
}

/// An argument of a `use` statement.
#[derive(Debug, Clone)]
pub enum Arg {
    Pos(Expr),
    Kw(String, Expr),
}

/// A rule parameter.
#[derive(Debug, Clone)]
pub struct Param {
    pub name: String,
    pub default: Option<Expr>,
}

/// A rule template.
#[derive(Debug)]
pub struct RuleDef {
    pub name: String,
    pub params: Vec<Param>,
    pub body: Vec<Stmt>,
}

/// A field of a `step` block.
#[derive(Debug, Clone)]
pub enum StepField {
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
    Use { rule: String, args: Vec<Arg> },
    When {
        branches: Vec<(Expr, Vec<Stmt>)>,
        otherwise: Option<Vec<Stmt>>,
    },
    Each {
        index: Option<String>,
        name: String,
        subject: Expr,
        body: Vec<Stmt>,
    },
    Rule(Rc<RuleDef>),
    Step(Vec<StepField>),
}
