//! A bottom-up Datalog engine with stratified negation.
//!
//! The pipeline is: [`parse`] the text into a [`Program`], then
//! [`Model::compute`] checks that the program is *safe* and *stratifiable* and
//! evaluates it with semi-naive evaluation, then [`Model::query`] answers
//! queries against the resulting model. [`run`] does all of that for a source
//! string and renders the answers in the command-line format.
//!
//! # Language
//!
//! Facts (`edge(a, b).`), rules (`path(X, Z) :- edge(X, Y), path(Y, Z).`) and
//! queries (`?- path(a, X).`). Bodies may contain negated atoms
//! (`not p(X)`) and comparisons (`X < Y`, `X != 3`, …). Constants are
//! integers or lower-case identifiers; every integer sorts before every
//! identifier. `%` starts a comment.
//!
//! # Example
//!
//! ```
//! use datalog::{parse, Const, Model};
//!
//! let program = parse("
//!     edge(1, 2). edge(2, 3).
//!     path(X, Y) :- edge(X, Y).
//!     path(X, Z) :- path(X, Y), edge(Y, Z).
//! ").unwrap();
//! let model = Model::compute(&program).unwrap();
//! let from_one = model.query(&parse("?- path(1, X).").unwrap().queries[0]);
//! assert_eq!(from_one, vec![
//!     vec![Const::Int(1), Const::Int(2)],
//!     vec![Const::Int(1), Const::Int(3)],
//! ]);
//! ```
//!
//! # Modules
//!
//! * [`ast`], [`lexer`], [`parser`]: syntax.
//! * [`analysis`]: safety check and stratification (Tarjan's SCC).
//! * [`symbols`]: predicate and constant interning (constants become their
//!   rank in the total order, so comparisons are integer comparisons).
//! * [`relation`]: tuple storage with incrementally maintained hash indexes.
//! * [`eval`]: the semi-naive evaluator and the resulting [`Model`]; it uses
//!   the join planner and executor, which are internal.

pub mod analysis;
pub mod ast;
pub mod error;
pub mod eval;
pub mod lexer;
pub mod parser;
pub mod relation;
pub mod symbols;

mod join;
mod plan;

pub use ast::{Atom, CmpOp, Const, Literal, Program, Rule, Term};
pub use error::{Error, ParseError};
pub use eval::Model;
pub use parser::parse;

use std::fmt::Write;

/// Render the answer to one query: the matching tuples, one per line, then
/// `-- N` with the number of tuples.
pub fn format_answer(query: &Atom, tuples: &[Vec<Const>]) -> String {
    let mut out = String::new();
    for t in tuples {
        out.push_str(&query.pred);
        out.push('(');
        for (i, c) in t.iter().enumerate() {
            if i > 0 {
                out.push_str(", ");
            }
            write!(out, "{c}").unwrap();
        }
        out.push_str(")\n");
    }
    writeln!(out, "-- {}", tuples.len()).unwrap();
    out
}

/// Parse and evaluate `source`, returning the output of all its queries in
/// order. Unsafe or unstratifiable programs yield an [`Error`].
///
/// ```
/// let out = datalog::run("p(1). p(2). ?- p(X).").unwrap();
/// assert_eq!(out, "p(1)\np(2)\n-- 2\n");
/// assert!(datalog::run("p(X).").is_err());
/// ```
pub fn run(source: &str) -> Result<String, Error> {
    let program = parse(source)?;
    let model = Model::compute(&program)?;
    let mut out = String::new();
    for q in &program.queries {
        out.push_str(&format_answer(q, &model.query(q)));
    }
    Ok(out)
}
