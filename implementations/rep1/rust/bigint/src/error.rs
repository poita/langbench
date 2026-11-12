//! Error types.

use std::fmt;

/// An error from parsing a decimal integer or a query line.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ParseError {
    /// The numeric text was not of the form `-?[0-9]+`.
    InvalidNumber,
    /// The query line was not of the form `<a> <op> <b>`.
    InvalidQuery,
    /// The operator is not one of `+ - * / % ^ cmp`.
    UnknownOperator(String),
}

impl fmt::Display for ParseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ParseError::InvalidNumber => write!(f, "invalid decimal integer"),
            ParseError::InvalidQuery => write!(f, "malformed query, expected `<a> <op> <b>`"),
            ParseError::UnknownOperator(op) => write!(f, "unknown operator `{op}`"),
        }
    }
}

impl std::error::Error for ParseError {}

/// An error from an arithmetic operation.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ArithmeticError {
    /// Division or remainder by zero.
    DivisionByZero,
    /// Exponentiation with a negative exponent.
    NegativeExponent,
    /// The exponent is too large to be processed (only reported when the base
    /// is not 0, 1 or −1, where the result would be astronomically large).
    ExponentTooLarge,
}

impl fmt::Display for ArithmeticError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ArithmeticError::DivisionByZero => write!(f, "division by zero"),
            ArithmeticError::NegativeExponent => write!(f, "negative exponent"),
            ArithmeticError::ExponentTooLarge => write!(f, "exponent too large"),
        }
    }
}

impl std::error::Error for ArithmeticError {}
