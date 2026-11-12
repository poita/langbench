//! # cdcl-sat
//!
//! A small, dependency-free CDCL SAT solver in the style of MiniSat, plus a
//! DIMACS CNF reader and writer.
//!
//! Modules:
//! - [`lit`]: variables, literals and truth values;
//! - [`heap`]: the activity-ordered priority queue used for branching;
//! - [`solver`]: the solver (watched literals, first-UIP learning, VSIDS,
//!   phase saving, Luby restarts, learnt-clause deletion);
//! - [`dimacs`]: parsing DIMACS CNF text and formatting results.
//!
//! ```
//! use cdcl_sat::{format_result, Cnf};
//!
//! let cnf = Cnf::parse("p cnf 3 2\n1 -2 0\n2 3 0\n").unwrap();
//! let result = cnf.solve();
//! assert!(format_result(&result).starts_with("SAT\n"));
//! ```

pub mod dimacs;
pub mod heap;
pub mod lit;
pub mod solver;

pub use dimacs::{format_result, Cnf, ParseError};
pub use lit::{LBool, Lit, Var};
pub use solver::{SolveResult, Solver, Stats};
