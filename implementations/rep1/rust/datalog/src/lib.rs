//! # datalog
//!
//! A Datalog engine with stratified negation and integer/symbol constants.
//!
//! A program is parsed ([`Program::parse`]), checked for safety and
//! stratifiability, and evaluated bottom-up with **semi-naive evaluation**
//! ([`evaluate`]), which yields a [`Model`] that can answer queries.
//!
//! ```
//! use datalog::Program;
//!
//! let program = Program::parse(
//!     "edge(1, 2). edge(2, 3).
//!      path(X, Y) :- edge(X, Y).
//!      path(X, Z) :- edge(X, Y), path(Y, Z).
//!      ?- path(1, X).",
//! )
//! .unwrap();
//! let model = datalog::evaluate(&program).unwrap();
//! let rows = model.query(&program.queries[0]);
//! assert_eq!(rows.len(), 2);
//! assert_eq!(rows[0][1].to_string(), "2");
//! ```
//!
//! For text in, text out, use [`run`], which is what the command-line tool
//! does.
//!
//! ## Modules
//!
//! * [`parser`] — source text to [`Program`]
//! * [`ast`] — syntax tree
//! * [`analysis`] — safety check and stratification (Tarjan SCCs)
//! * [`relation`] — tuple sets with incrementally maintained hash indexes
//! * `plan` (internal) — join planning and execution
//! * [`eval`] — the semi-naive evaluator and [`Model`]

pub mod analysis;
pub mod ast;
pub mod constant;
pub mod error;
pub mod eval;
pub mod hash;
pub mod parser;
pub mod relation;

mod lexer;
mod plan;

pub use ast::{Atom, Literal, Program, Rule, Term};
pub use constant::Constant;
pub use error::Error;
pub use eval::{evaluate, Model};

use std::fmt::Write;

/// Parse `source`, compute its model and answer all queries.
///
/// For each query, in program order, the output holds the matching tuples
/// one per line as `p(v1, v2)` in ascending order, followed by `-- N`.
///
/// # Errors
/// Any [`Error`]: malformed input, an unsafe rule or an unstratifiable
/// program. The command-line tool prints `error` for all of them.
pub fn run(source: &str) -> Result<String, Error> {
    let program = Program::parse(source)?;
    let model = evaluate(&program)?;
    let mut out = String::new();
    for q in &program.queries {
        let rows = model.query(q);
        let name = program.name(q.pred);
        for row in &rows {
            out.push_str(name);
            out.push('(');
            for (i, c) in row.iter().enumerate() {
                if i > 0 {
                    out.push_str(", ");
                }
                write!(out, "{c}").unwrap();
            }
            out.push_str(")\n");
        }
        writeln!(out, "-- {}", rows.len()).unwrap();
    }
    Ok(out)
}
