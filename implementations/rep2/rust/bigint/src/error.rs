//! Error types.

use std::fmt;

/// A string could not be parsed as a decimal integer (`-?[0-9]+`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ParseError {
    /// The input contained no digits.
    Empty,
    /// The input contained a character that is not an ASCII digit
    /// (after an optional leading `-`).
    InvalidDigit,
}

impl fmt::Display for ParseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ParseError::Empty => f.write_str("no digits in integer"),
            ParseError::InvalidDigit => f.write_str("invalid digit in integer"),
        }
    }
}

impl std::error::Error for ParseError {}

/// An arithmetic operation that has no defined result.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ArithmeticError {
    /// Division or remainder with a zero divisor.
    DivisionByZero,
    /// Exponentiation with a negative exponent.
    NegativeExponent,
    /// The exponent is too large to compute (the result would not fit in
    /// memory).
    ExponentTooLarge,
}

impl fmt::Display for ArithmeticError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ArithmeticError::DivisionByZero => f.write_str("division by zero"),
            ArithmeticError::NegativeExponent => f.write_str("negative exponent"),
            ArithmeticError::ExponentTooLarge => f.write_str("exponent too large"),
        }
    }
}

impl std::error::Error for ArithmeticError {}
