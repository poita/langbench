//! The syntax tree produced by the parser and walked by the interpreter.

use crate::filters::Filter;
use crate::value::Value;
use std::rc::Rc;

/// Binary arithmetic operators.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BinOp {
    /// `+`
    Add,
    /// `-`
    Sub,
    /// `*`
    Mul,
    /// `/`
    Div,
    /// `//`
    FloorDiv,
    /// `%`
    Mod,
    /// `**`
    Pow,
    /// `~`
    Concat,
}

/// Comparison operators.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CmpOp {
    /// `==`
    Eq,
    /// `!=`
    Ne,
    /// `<`
    Lt,
    /// `<=`
    Le,
    /// `>`
    Gt,
    /// `>=`
    Ge,
    /// `in`
    In,
    /// `not in`
    NotIn,
}

/// An expression.
#[derive(Debug)]
pub enum Expr {
    /// A literal value.
    Lit(Value),
    /// A variable reference.
    Name(Rc<str>),
    /// A list literal.
    List(Vec<Expr>),
    /// Unary minus.
    Neg(Box<Expr>),
    /// `not`.
    Not(Box<Expr>),
    /// A binary arithmetic or `~` operation.
    Bin(BinOp, Box<Expr>, Box<Expr>),
    /// `and` (returns the deciding operand).
    And(Box<Expr>, Box<Expr>),
    /// `or` (returns the deciding operand).
    Or(Box<Expr>, Box<Expr>),
    /// A comparison chain `a < b < c`.
    Compare(Box<Expr>, Vec<(CmpOp, Expr)>),
    /// `value|filter(args)`.
    Filter(Box<Expr>, Filter, Vec<Expr>),
    /// `value is defined` / `value is not defined` (the flag negates).
    IsDefined(Box<Expr>, bool),
    /// `a.NAME`
    Attr(Box<Expr>, Rc<str>),
    /// `a[expr]`
    Index(Box<Expr>, Box<Expr>),
    /// `f(positional, keyword=...)`
    Call(Box<Expr>, Vec<Expr>, Vec<(Rc<str>, Expr)>),
}

/// A macro definition.
#[derive(Debug)]
pub struct MacroDef {
    /// The macro's name.
    pub name: Rc<str>,
    /// Parameters with optional default expressions.
    pub params: Vec<(Rc<str>, Option<Expr>)>,
    /// The body.
    pub body: Vec<Node>,
}

/// A statement or piece of text.
#[derive(Debug)]
pub enum Node {
    /// Literal text.
    Text(String),
    /// `{{ expr }}`
    Print(Expr),
    /// `if` / `elif` / `else`: conditional branches and an optional `else`.
    If(Vec<(Expr, Vec<Node>)>, Option<Vec<Node>>),
    /// `for`
    For {
        /// Loop variable.
        var: Rc<str>,
        /// The iterated expression.
        iter: Expr,
        /// Loop body.
        body: Vec<Node>,
        /// Body of the `else` clause, run when the sequence is empty.
        else_body: Vec<Node>,
    },
    /// `set name = expr`
    Set(Rc<str>, Expr),
    /// `macro`
    Macro(Rc<MacroDef>),
    /// `include expr`
    Include(Expr),
    /// `extends expr`
    Extends(Expr),
    /// `block name`
    Block {
        /// Block name.
        name: Rc<str>,
        /// Block body.
        body: Rc<Vec<Node>>,
    },
}

/// A parsed, filter-checked template.
#[derive(Debug)]
pub struct Template {
    /// The top-level nodes.
    pub body: Vec<Node>,
    /// The static block table: every block of the template, in order of
    /// appearance (including blocks nested in other blocks).
    pub blocks: Vec<(Rc<str>, Rc<Vec<Node>>)>,
}
