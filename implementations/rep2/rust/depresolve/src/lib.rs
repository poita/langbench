//! # depresolve
//!
//! A deterministic package dependency resolver. Given a registry of package
//! versions (each with requirements) and a root manifest, it picks one
//! version per needed package using a fixed search: depth-first in
//! requirement order, newest candidate first, chronological backtracking.
//! The first complete solution of that search is returned, so every run (and
//! every conforming implementation) yields the same answer.
//!
//! ## Example
//!
//! ```
//! let input = "\
//! a 1.0.0: c ^1.0.0
//! b 1.0.0: c ~1.2.0
//! c 1.1.0:
//! c 1.2.5:
//! c 1.3.0:
//! root: a *, b *
//! ";
//! let out = depresolve::resolve_str(input).unwrap();
//! assert_eq!(out, "a 1.0.0\nb 1.0.0\nc 1.2.5\n");
//!
//! // Or step by step:
//! let problem = depresolve::parse(input).unwrap();
//! let resolution = depresolve::resolve(&problem).unwrap();
//! assert_eq!(resolution.packages.len(), 3);
//! ```
//!
//! ## Modules
//!
//! * [`version`] — [`Version`] and range parsing ([`Interval`]).
//! * [`registry`] — the registry, built with [`RegistryBuilder`].
//! * [`parser`] — the text format.
//! * [`resolver`] — the search itself.

pub mod error;
pub mod parser;
pub mod registry;
pub mod resolver;
pub mod version;

pub use error::ParseError;
pub use parser::parse;
pub use registry::{PackageId, Problem, Registry, RegistryBuilder, Requirement};
pub use resolver::{resolve, resolve_requirements, Resolution};
pub use version::{Interval, Version};

/// The text printed when no resolution exists.
pub const UNSATISFIABLE: &str = "unsatisfiable\n";

/// Parses `input`, resolves it and renders the output exactly as the CLI
/// prints it: one `name version` line per chosen package sorted by name, or
/// `unsatisfiable`.
pub fn resolve_str(input: &str) -> Result<String, ParseError> {
    let problem = parse(input)?;
    Ok(match resolve(&problem) {
        Some(r) => r.to_lines(),
        None => UNSATISFIABLE.to_owned(),
    })
}
