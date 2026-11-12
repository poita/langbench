//! Abstract syntax of a Datalog program.

use crate::constant::Constant;
use std::cmp::Ordering;
use std::collections::HashMap;
use std::fmt;

/// Index of a predicate (a name together with an arity) in
/// [`Program::predicates`].
pub type PredId = usize;

/// A predicate: `r/1` and `r/2` are different predicates.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct Predicate {
    /// The identifier used in the source.
    pub name: String,
    /// Number of arguments (at least 1).
    pub arity: usize,
}

/// An argument of an atom or comparison.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Term {
    /// A constant.
    Const(Constant),
    /// A named variable (scoped to its clause).
    Var(String),
    /// The anonymous variable `_`; every occurrence is a distinct variable.
    Anon,
}

/// A predicate applied to terms.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Atom {
    /// The predicate.
    pub pred: PredId,
    /// One term per argument.
    pub terms: Vec<Term>,
}

/// A comparison operator.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CmpOp {
    /// `<`
    Lt,
    /// `<=`
    Le,
    /// `>`
    Gt,
    /// `>=`
    Ge,
    /// `=`
    Eq,
    /// `!=`
    Ne,
}

impl CmpOp {
    /// Whether `l op r` holds given `l.cmp(r)`.
    pub fn holds(self, ord: Ordering) -> bool {
        match self {
            CmpOp::Lt => ord == Ordering::Less,
            CmpOp::Le => ord != Ordering::Greater,
            CmpOp::Gt => ord == Ordering::Greater,
            CmpOp::Ge => ord != Ordering::Less,
            CmpOp::Eq => ord == Ordering::Equal,
            CmpOp::Ne => ord != Ordering::Equal,
        }
    }
}

impl fmt::Display for CmpOp {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            CmpOp::Lt => "<",
            CmpOp::Le => "<=",
            CmpOp::Gt => ">",
            CmpOp::Ge => ">=",
            CmpOp::Eq => "=",
            CmpOp::Ne => "!=",
        })
    }
}

/// One literal of a rule body.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Literal {
    /// A positive atom.
    Pos(Atom),
    /// A negated atom (`not p(...)`).
    Neg(Atom),
    /// A comparison between two terms.
    Cmp(Term, CmpOp, Term),
}

/// A rule; a fact is a rule with an empty body.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Rule {
    /// The head atom.
    pub head: Atom,
    /// The body literals, in source order.
    pub body: Vec<Literal>,
    /// 1-based source line of the clause.
    pub line: usize,
}

/// A parsed program: rules (including facts), queries, and the table of the
/// predicates they mention.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Program {
    /// All predicates, indexed by [`PredId`].
    pub predicates: Vec<Predicate>,
    /// Facts and rules in source order.
    pub rules: Vec<Rule>,
    /// Queries in source order.
    pub queries: Vec<Atom>,
}

impl Program {
    /// Parse a program from source text. See [`crate::parser::parse`].
    pub fn parse(source: &str) -> Result<Program, crate::Error> {
        crate::parser::parse(source)
    }

    /// Name of the predicate with the given id.
    pub fn name(&self, pred: PredId) -> &str {
        &self.predicates[pred].name
    }
}

/// Interning table used while parsing.
#[derive(Debug, Default)]
pub(crate) struct PredicateTable {
    pub(crate) list: Vec<Predicate>,
    map: HashMap<(String, usize), PredId>,
}

impl PredicateTable {
    pub(crate) fn intern(&mut self, name: &str, arity: usize) -> PredId {
        if let Some(&id) = self.map.get(&(name.to_string(), arity)) {
            return id;
        }
        let id = self.list.len();
        self.list.push(Predicate { name: name.to_string(), arity });
        self.map.insert((name.to_string(), arity), id);
        id
    }
}
