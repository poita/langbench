//! Error type shared by every stage of the pipeline.

use std::fmt;

/// Everything that can go wrong while turning source text into a model.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Error {
    /// The source text is not a well-formed program.
    Parse {
        /// 1-based line number where the problem was detected.
        line: usize,
        /// Human-readable description.
        message: String,
    },
    /// A predicate is used with more arguments than the engine supports.
    ArityTooLarge {
        /// Name of the offending predicate.
        predicate: String,
        /// The arity it was used with.
        arity: usize,
    },
    /// A rule has a variable in its head, a negated atom or a comparison
    /// that does not occur in a positive body atom.
    Unsafe {
        /// 1-based line number of the start of the rule's head.
        line: usize,
    },
    /// A cycle of the predicate dependency graph contains a negative edge.
    Unstratifiable {
        /// A predicate that depends negatively on itself (through a cycle).
        predicate: String,
    },
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::Parse { line, message } => write!(f, "parse error on line {line}: {message}"),
            Error::ArityTooLarge { predicate, arity } => {
                write!(f, "predicate `{predicate}` has too many arguments ({arity})")
            }
            Error::Unsafe { line } => write!(f, "unsafe rule on line {line}"),
            Error::Unstratifiable { predicate } => {
                write!(f, "program is not stratifiable (negative cycle through `{predicate}`)")
            }
        }
    }
}

impl std::error::Error for Error {}
