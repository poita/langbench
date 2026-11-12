//! Abstract syntax of Datalog programs.

use std::cmp::Ordering;
use std::fmt;

/// A constant: an integer or a symbol (identifier).
///
/// The derived [`Ord`] is the order used throughout the engine: every integer
/// sorts before every symbol, integers compare numerically and symbols compare
/// bytewise (a proper prefix first).
#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum Const {
    /// An integer constant.
    Int(i64),
    /// A symbolic constant such as `alice`.
    Sym(String),
}

impl fmt::Display for Const {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Const::Int(i) => write!(f, "{i}"),
            Const::Sym(s) => f.write_str(s),
        }
    }
}

/// An argument of an atom or comparison.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum Term {
    /// A constant.
    Const(Const),
    /// A named variable (scoped to one clause).
    Var(String),
    /// The anonymous variable `_`; every occurrence is a distinct variable.
    Anon,
}

impl fmt::Display for Term {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Term::Const(c) => write!(f, "{c}"),
            Term::Var(v) => f.write_str(v),
            Term::Anon => f.write_str("_"),
        }
    }
}

/// A predicate applied to arguments: `name(t1, …, tn)`.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct Atom {
    /// The predicate name.
    pub pred: String,
    /// The arguments (at least one).
    pub args: Vec<Term>,
}

impl Atom {
    /// Number of arguments.
    pub fn arity(&self) -> usize {
        self.args.len()
    }
}

impl fmt::Display for Atom {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}(", self.pred)?;
        for (i, t) in self.args.iter().enumerate() {
            if i > 0 {
                f.write_str(", ")?;
            }
            write!(f, "{t}")?;
        }
        f.write_str(")")
    }
}

/// A comparison operator.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
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
    /// Whether `a op b` holds for the given values.
    pub fn holds<T: Ord>(self, a: &T, b: &T) -> bool {
        let o = a.cmp(b);
        match self {
            CmpOp::Lt => o == Ordering::Less,
            CmpOp::Le => o != Ordering::Greater,
            CmpOp::Gt => o == Ordering::Greater,
            CmpOp::Ge => o != Ordering::Less,
            CmpOp::Eq => o == Ordering::Equal,
            CmpOp::Ne => o != Ordering::Equal,
        }
    }

    /// The operator's source syntax.
    pub fn symbol(self) -> &'static str {
        match self {
            CmpOp::Lt => "<",
            CmpOp::Le => "<=",
            CmpOp::Gt => ">",
            CmpOp::Ge => ">=",
            CmpOp::Eq => "=",
            CmpOp::Ne => "!=",
        }
    }
}

/// One element of a rule body.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum Literal {
    /// A positive atom.
    Pos(Atom),
    /// A negated atom: `not p(…)`.
    Neg(Atom),
    /// A comparison `t1 op t2`.
    Cmp(Term, CmpOp, Term),
}

impl fmt::Display for Literal {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Literal::Pos(a) => write!(f, "{a}"),
            Literal::Neg(a) => write!(f, "not {a}"),
            Literal::Cmp(a, op, b) => write!(f, "{a} {} {b}", op.symbol()),
        }
    }
}

/// A rule `head :- body.`; a fact is a rule with an empty body.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct Rule {
    /// The head atom.
    pub head: Atom,
    /// The body literals (empty for a fact).
    pub body: Vec<Literal>,
}

impl Rule {
    /// `true` if the body is empty.
    pub fn is_fact(&self) -> bool {
        self.body.is_empty()
    }
}

impl fmt::Display for Rule {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.head)?;
        if !self.body.is_empty() {
            f.write_str(" :- ")?;
            for (i, l) in self.body.iter().enumerate() {
                if i > 0 {
                    f.write_str(", ")?;
                }
                write!(f, "{l}")?;
            }
        }
        f.write_str(".")
    }
}

/// A parsed program: its rules (including facts) and its queries, each in
/// source order.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Program {
    /// Facts and rules.
    pub rules: Vec<Rule>,
    /// Queries `?- atom.`
    pub queries: Vec<Atom>,
}
