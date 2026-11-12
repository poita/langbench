//! # cdcl-sat
//!
//! A small MiniSat-style CDCL SAT solver for formulas in DIMACS CNF format.
//!
//! The crate is organised by responsibility:
//!
//! * [`lit`]: variables and literals;
//! * [`dimacs`]: parsing DIMACS CNF text and formatting answers;
//! * [`solver`]: the solver itself (watched literals, first-UIP learning,
//!   VSIDS, phase saving, Luby restarts, learnt-clause deletion);
//! * `heap` and `luby`: the activity-ordered variable heap and the restart
//!   sequence used by the solver.
//!
//! ## Example
//!
//! ```
//! let answer = cdcl_sat::solve_dimacs("p cnf 2 2\n1 2 0\n-1 0\n").unwrap();
//! assert_eq!(answer, "SAT\n-1 2 0\n");
//! ```

pub mod dimacs;
mod heap;
pub mod lit;
mod luby;
pub mod solver;

pub use dimacs::{format_answer, parse, Cnf, ParseError};
pub use lit::{Lit, Var};
pub use solver::{Solver, Stats};

/// Builds a [`Solver`] holding all variables and clauses of `cnf`.
pub fn solver_from_cnf(cnf: &Cnf) -> Solver {
    let mut s = Solver::new();
    s.reserve_vars(cnf.num_vars);
    let mut buf: Vec<Lit> = Vec::new();
    for clause in &cnf.clauses {
        buf.clear();
        buf.extend(clause.iter().map(|&d| Lit::from_dimacs(d)));
        s.add_clause(&buf);
    }
    s
}

/// Solves `cnf`, returning a satisfying assignment (`model[i]` is the value
/// of DIMACS variable `i + 1`) or `None` if it is unsatisfiable.
pub fn solve_cnf(cnf: &Cnf) -> Option<Vec<bool>> {
    let mut s = solver_from_cnf(cnf);
    if s.solve() {
        Some(s.model())
    } else {
        None
    }
}

/// Parses DIMACS CNF text, solves it and returns the formatted answer
/// (`UNSAT\n` or `SAT\n<literals> 0\n`).
pub fn solve_dimacs(input: &str) -> Result<String, ParseError> {
    let cnf = parse(input)?;
    Ok(format_answer(solve_cnf(&cnf).as_deref()))
}
