//! The text line protocol: `<op> <a> [<b>]` in, 8 hex digits out.

use std::fmt;

use crate::{add, div, mul, sqrt, sub};

/// An operation named on an input line.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Op {
    Add,
    Sub,
    Mul,
    Div,
    Sqrt,
}

/// Why a line could not be parsed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ParseError {
    /// The operation name is not one of `add sub mul div sqrt`.
    UnknownOp(String),
    /// An operand is not exactly 8 lowercase hexadecimal digits.
    BadOperand(String),
    /// The wrong number of operands for the operation.
    WrongArity,
}

impl fmt::Display for ParseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ParseError::UnknownOp(s) => write!(f, "unknown operation `{s}`"),
            ParseError::BadOperand(s) => write!(f, "bad operand `{s}`"),
            ParseError::WrongArity => write!(f, "wrong number of operands"),
        }
    }
}

impl std::error::Error for ParseError {}

impl Op {
    /// Applies the operation. `b` is ignored for [`Op::Sqrt`].
    pub fn apply(self, a: u32, b: u32) -> u32 {
        match self {
            Op::Add => add(a, b),
            Op::Sub => sub(a, b),
            Op::Mul => mul(a, b),
            Op::Div => div(a, b),
            Op::Sqrt => sqrt(a),
        }
    }
}

fn parse_hex8(s: &str) -> Result<u32, ParseError> {
    let bad = || ParseError::BadOperand(s.to_string());
    if s.len() != 8 {
        return Err(bad());
    }
    let mut v = 0u32;
    for c in s.bytes() {
        let d = match c {
            b'0'..=b'9' => c - b'0',
            b'a'..=b'f' => c - b'a' + 10,
            _ => return Err(bad()),
        };
        v = (v << 4) | d as u32;
    }
    Ok(v)
}

/// Parses one input line (without its terminator) into an operation and its
/// operands; the second operand is 0 for `sqrt`.
pub fn parse_line(line: &str) -> Result<(Op, u32, u32), ParseError> {
    let mut parts = line.split(' ');
    let op = match parts.next().unwrap_or("") {
        "add" => Op::Add,
        "sub" => Op::Sub,
        "mul" => Op::Mul,
        "div" => Op::Div,
        "sqrt" => Op::Sqrt,
        other => return Err(ParseError::UnknownOp(other.to_string())),
    };
    let a = parse_hex8(parts.next().ok_or(ParseError::WrongArity)?)?;
    let b = if op == Op::Sqrt {
        0
    } else {
        parse_hex8(parts.next().ok_or(ParseError::WrongArity)?)?
    };
    if parts.next().is_some() {
        return Err(ParseError::WrongArity);
    }
    Ok((op, a, b))
}

/// Appends `bits` as 8 lowercase hex digits to `out`.
pub fn push_hex8(out: &mut String, bits: u32) {
    const DIGITS: &[u8; 16] = b"0123456789abcdef";
    for shift in (0..8).rev() {
        out.push(DIGITS[((bits >> (shift * 4)) & 0xf) as usize] as char);
    }
}

/// Evaluates one input line and returns the 8-digit hex result.
pub fn eval_line(line: &str) -> Result<String, ParseError> {
    let (op, a, b) = parse_line(line)?;
    let mut s = String::with_capacity(8);
    push_hex8(&mut s, op.apply(a, b));
    Ok(s)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_and_evaluates() {
        assert_eq!(eval_line("add 3f800000 3f800000").unwrap(), "40000000");
        assert_eq!(eval_line("sqrt 40000000").unwrap(), "3fb504f3");
        assert_eq!(eval_line("sub 3f800000 3f800000").unwrap(), "00000000");
    }

    #[test]
    fn rejects_malformed() {
        assert!(matches!(parse_line("pow 00000000 00000000"), Err(ParseError::UnknownOp(_))));
        assert!(matches!(parse_line("add 0000000g 00000000"), Err(ParseError::BadOperand(_))));
        assert!(matches!(parse_line("add 3F800000 00000000"), Err(ParseError::BadOperand(_))));
        assert_eq!(parse_line("add 00000000"), Err(ParseError::WrongArity));
        assert_eq!(parse_line("sqrt 00000000 00000000"), Err(ParseError::WrongArity));
    }
}
