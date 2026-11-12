//! A small spreadsheet engine with eager, incremental recalculation.
//!
//! Cells hold numbers, strings or formulas. Formulas reference other cells,
//! and the sheet is kept consistent after every edit: only the cells that
//! transitively read the edited cell are re-evaluated, and cells that take
//! part in a reference cycle evaluate to `#CYCLE!`.
//!
//! # Example
//!
//! ```
//! use spreadsheet::Sheet;
//!
//! let mut sheet = Sheet::new();
//! sheet.set_content("A1", "10").unwrap();
//! sheet.set_content("A2", "32").unwrap();
//! sheet.set_content("A3", "=A1+A2").unwrap();
//! assert_eq!(sheet.display("A3").unwrap(), "42");
//!
//! // Creating a cycle is not an error; the cells just show `#CYCLE!`.
//! sheet.set_content("A1", "=A3").unwrap();
//! assert_eq!(sheet.display("A3").unwrap(), "#CYCLE!");
//!
//! // Breaking the cycle restores normal evaluation.
//! sheet.set_content("A1", "5").unwrap();
//! assert_eq!(sheet.display("A3").unwrap(), "37");
//! ```
//!
//! # Modules
//!
//! * [`cell`]: cell addresses ([`CellRef`]) and ranges.
//! * [`value`]: the [`Value`] and [`ErrorCode`] types and number display.
//! * [`parser`]: the formula parser, producing an [`ast::Expr`] tree.
//! * [`eval`]: evaluation of a syntax tree against stored cell values.
//! * [`graph`]: strongly connected components (Tarjan).
//! * [`error`]: the library error type.
//! * [`sheet`]: the [`Sheet`] itself: dependency graph and recalculation.
//! * [`command`]: the line-oriented command language used by the CLI.

pub mod ast;
pub mod cell;
pub mod command;
pub mod error;
pub mod eval;
pub mod graph;
pub mod parser;
pub mod sheet;
pub mod value;

pub use cell::{CellRef, Range};
pub use command::{run_script, Command};
pub use error::Error;
pub use parser::ParseError;
pub use sheet::{Content, Sheet};
pub use value::{format_number, ErrorCode, Value};
