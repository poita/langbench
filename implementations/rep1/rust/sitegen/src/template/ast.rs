//! The syntax tree of a parsed template.

use std::collections::HashMap;
use std::rc::Rc;

use super::value::Value;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Filter {
    Upper,
    Lower,
    Trim,
    Escape,
    Replace,
    Length,
    Int,
    Join,
    First,
    Last,
    Reverse,
    Sort,
    Default,
}

impl Filter {
    pub fn from_name(name: &str) -> Option<Filter> {
        Some(match name {
            "upper" => Filter::Upper,
            "lower" => Filter::Lower,
            "trim" => Filter::Trim,
            "escape" => Filter::Escape,
            "replace" => Filter::Replace,
            "length" => Filter::Length,
            "int" => Filter::Int,
            "join" => Filter::Join,
            "first" => Filter::First,
            "last" => Filter::Last,
            "reverse" => Filter::Reverse,
            "sort" => Filter::Sort,
            "default" => Filter::Default,
            _ => return None,
        })
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum BinOp {
    Add,
    Sub,
    Mul,
    Div,
    FloorDiv,
    Mod,
    Pow,
    Concat,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum CmpOp {
    Eq,
    Ne,
    Lt,
    Le,
    Gt,
    Ge,
    In,
    NotIn,
}

pub(crate) enum Expr {
    Const(Value),
    Name(Rc<str>),
    List(Vec<Expr>),
    Attr(Box<Expr>, Rc<str>),
    Index(Box<Expr>, Box<Expr>),
    Call {
        callee: Box<Expr>,
        args: Vec<Expr>,
        kwargs: Vec<(Rc<str>, Expr)>,
    },
    /// `None` for an unknown filter name (reported when the template loads).
    Filter(Box<Expr>, Option<Filter>, Vec<Expr>),
    IsDefined(Box<Expr>, bool),
    Neg(Box<Expr>),
    Not(Box<Expr>),
    Binary(BinOp, Box<Expr>, Box<Expr>),
    And(Box<Expr>, Box<Expr>),
    Or(Box<Expr>, Box<Expr>),
    Compare(Box<Expr>, Vec<(CmpOp, Expr)>),
}

pub(crate) struct MacroDef {
    pub name: Rc<str>,
    pub params: Vec<(Rc<str>, Option<Expr>)>,
    pub body: Vec<Node>,
}

pub(crate) struct BlockDef {
    pub name: Rc<str>,
    pub body: Vec<Node>,
}

pub(crate) enum Node {
    Text(String),
    Print(Expr),
    If {
        branches: Vec<(Expr, Vec<Node>)>,
        otherwise: Option<Vec<Node>>,
    },
    For {
        var: Rc<str>,
        iter: Expr,
        body: Vec<Node>,
        otherwise: Option<Vec<Node>>,
    },
    Set(Rc<str>, Expr),
    Macro(Rc<MacroDef>),
    Include(Expr),
    Extends(Expr),
    Block(Rc<BlockDef>),
}

/// A parsed template.
pub struct Template {
    pub(crate) body: Vec<Node>,
    pub(crate) blocks: HashMap<Rc<str>, Rc<BlockDef>>,
}
