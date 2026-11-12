//! # depresolve
//!
//! A deterministic package dependency resolver.
//!
//! Given a [`Registry`] of package versions (each with an ordered list of
//! requirements) and a list of root requirements, [`resolve`] picks exactly one
//! version for every needed package so that every requirement is satisfied.
//!
//! The answer is defined as the first solution of a fixed search: requirements
//! are processed depth-first in the order listed (a newly chosen version's
//! requirements go in front of the pending ones); a package is fixed to the
//! newest version satisfying the first requirement that reaches it; later
//! requirements are only checked against that choice; on failure the search
//! backtracks chronologically to the most recent choice with an older
//! candidate left. The search is iterative, so dependency chains thousands of
//! packages deep are fine.
//!
//! ```
//! use depresolve::{parse_input, resolve};
//!
//! let input = parse_input(
//!     "a 1.0.0: c ^1.0.0\n\
//!      b 1.0.0: c ~1.2.0\n\
//!      c 1.1.0:\n\
//!      c 1.2.5:\n\
//!      c 1.3.0:\n\
//!      root: a *, b *\n",
//! ).unwrap();
//! let solution = resolve(&input.registry, &input.root).unwrap();
//! assert_eq!(solution.to_string(), "a 1.0.0\nb 1.0.0\nc 1.2.5\n");
//! ```
//!
//! Registries can also be built programmatically with [`Registry::add`].

pub mod error;
pub mod parser;
pub mod range;
pub mod registry;
pub mod resolver;
pub mod version;

pub use error::ParseError;
pub use parser::{parse_input, parse_requirements, Input};
pub use range::Range;
pub use registry::{Registry, Release, Requirement};
pub use resolver::{resolve, Resolution};
pub use version::Version;
