//! Error type shared by every operation in the crate.

use std::fmt;

/// The reasons a linear-algebra operation can fail.
///
/// Each variant has a stable, machine-readable [`code`](LinalgError::code),
/// which is what the command-line driver writes to `NNN_error.txt`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LinalgError {
    /// Operand shapes are incompatible with each other.
    DimensionMismatch,
    /// A square matrix was required.
    NotSquare,
    /// A symmetric matrix was required (compared as exact doubles).
    NotSymmetric,
    /// Cholesky met a non-positive pivot.
    NotPositiveDefinite,
    /// A pivot (or singular value) was exactly zero.
    Singular,
}

impl LinalgError {
    /// The short snake_case identifier of this error.
    pub fn code(&self) -> &'static str {
        match self {
            LinalgError::DimensionMismatch => "dimension_mismatch",
            LinalgError::NotSquare => "not_square",
            LinalgError::NotSymmetric => "not_symmetric",
            LinalgError::NotPositiveDefinite => "not_positive_definite",
            LinalgError::Singular => "singular",
        }
    }
}

impl fmt::Display for LinalgError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.code())
    }
}

impl std::error::Error for LinalgError {}

/// Convenience alias used throughout the crate.
pub type Result<T> = std::result::Result<T, LinalgError>;
