//! Syntax tree of the source language.

use crate::symbol::Sym;

/// Binary operators. All of them are monomorphic (see [`BinOp::signature`]).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BinOp {
    Add,
    Sub,
    Mul,
    Div,
    Eq,
    Lt,
    Gt,
    Le,
    Ge,
    And,
    Or,
}

/// The primitive types an operator works on.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Prim {
    Int,
    Bool,
}

impl BinOp {
    /// `(operand type, result type)` of the operator.
    pub fn signature(self) -> (Prim, Prim) {
        use BinOp::*;
        match self {
            Add | Sub | Mul | Div => (Prim::Int, Prim::Int),
            Eq | Lt | Gt | Le | Ge => (Prim::Int, Prim::Bool),
            And | Or => (Prim::Bool, Prim::Bool),
        }
    }
}

/// An expression.
#[derive(Clone, Debug, PartialEq)]
pub enum Expr {
    /// Integer literal (the value is irrelevant to typing and not kept).
    Int,
    /// `true` or `false`.
    Bool(bool),
    /// `()`.
    Unit,
    /// A variable reference.
    Var(Sym),
    /// `fun x y -> body` (one or more parameters).
    Fun(Vec<Sym>, Box<Expr>),
    /// Application `f a`.
    App(Box<Expr>, Box<Expr>),
    /// `l op r`.
    Binary(BinOp, Box<Expr>, Box<Expr>),
    /// `head :: tail`.
    Cons(Box<Expr>, Box<Expr>),
    /// `if c then a else b`.
    If(Box<Expr>, Box<Expr>, Box<Expr>),
    /// `let name = rhs in body` (parameters are already desugared into `rhs`).
    Let { name: Sym, rhs: Box<Expr>, body: Box<Expr> },
    /// `let rec name params = rhs in body`.
    LetRec { name: Sym, params: Vec<Sym>, rhs: Box<Expr>, body: Box<Expr> },
    /// Tuple of two or more elements.
    Tuple(Vec<Expr>),
    /// List literal; empty for `[]`.
    List(Vec<Expr>),
}

/// A top-level declaration.
#[derive(Clone, Debug, PartialEq)]
pub enum Decl {
    /// `let name = rhs;;` (parameters desugared into `rhs`).
    Let { name: Sym, rhs: Expr },
    /// `let rec name params = rhs;;`.
    LetRec { name: Sym, params: Vec<Sym>, rhs: Expr },
    /// A bare expression `e;;`.
    Expr(Expr),
}
