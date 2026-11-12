//! The line-oriented query language used by the command-line tool.
//!
//! Each query has the form `<a> <op> <b>`, where `op` is one of
//! `+ - * / % ^ cmp`.

use crate::error::{ArithmeticError, ParseError};
use crate::int::BigInt;
use std::cmp::Ordering;
use std::fmt;
use std::io::{self, BufRead, Write};

/// A binary operator.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Op {
    Add,
    Sub,
    Mul,
    Div,
    Rem,
    Pow,
    Cmp,
}

impl Op {
    fn parse(s: &str) -> Option<Op> {
        Some(match s {
            "+" => Op::Add,
            "-" => Op::Sub,
            "*" => Op::Mul,
            "/" => Op::Div,
            "%" => Op::Rem,
            "^" => Op::Pow,
            "cmp" => Op::Cmp,
            _ => return None,
        })
    }
}

/// A line could not be understood as a query.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum QueryError {
    /// The line is not three space-separated tokens.
    Malformed,
    /// The operator token is not recognised.
    UnknownOperator,
    /// An operand is not a valid integer.
    BadOperand(ParseError),
}

impl fmt::Display for QueryError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            QueryError::Malformed => f.write_str("expected `<a> <op> <b>`"),
            QueryError::UnknownOperator => f.write_str("unknown operator"),
            QueryError::BadOperand(e) => write!(f, "bad operand: {e}"),
        }
    }
}

impl std::error::Error for QueryError {}

/// Parses and evaluates one query line, returning the text to print.
///
/// Queries with no defined result (division by zero, negative exponent)
/// evaluate to the string `error`.
///
/// ```
/// use bigint::query::evaluate_line;
/// assert_eq!(evaluate_line("-7 / 2").unwrap(), "-3");
/// assert_eq!(evaluate_line("1 / 0").unwrap(), "error");
/// assert_eq!(evaluate_line("007 cmp 7").unwrap(), "0");
/// ```
pub fn evaluate_line(line: &str) -> Result<String, QueryError> {
    let mut parts = line.split(' ');
    let (a, op, b) = match (parts.next(), parts.next(), parts.next(), parts.next()) {
        (Some(a), Some(op), Some(b), None) => (a, op, b),
        _ => return Err(QueryError::Malformed),
    };
    let op = Op::parse(op).ok_or(QueryError::UnknownOperator)?;
    let a: BigInt = a.parse().map_err(QueryError::BadOperand)?;
    let b: BigInt = b.parse().map_err(QueryError::BadOperand)?;
    Ok(match evaluate(&a, op, &b) {
        Ok(s) => s,
        Err(_) => "error".to_string(),
    })
}

/// Applies `op` to the operands and renders the result (`-1`/`0`/`1` for
/// [`Op::Cmp`]).
pub fn evaluate(a: &BigInt, op: Op, b: &BigInt) -> Result<String, ArithmeticError> {
    Ok(match op {
        Op::Add => (a + b).to_string(),
        Op::Sub => (a - b).to_string(),
        Op::Mul => (a * b).to_string(),
        Op::Div => a.checked_div(b)?.to_string(),
        Op::Rem => a.checked_rem(b)?.to_string(),
        Op::Pow => a.checked_pow(b)?.to_string(),
        Op::Cmp => match a.cmp(b) {
            Ordering::Less => "-1",
            Ordering::Equal => "0",
            Ordering::Greater => "1",
        }
        .to_string(),
    })
}

/// Reads queries from `input` and writes one result line per query to
/// `output`. A trailing `\r` on a line is ignored.
pub fn run<R: BufRead, W: Write>(input: R, mut output: W) -> io::Result<()> {
    for line in input.lines() {
        let line = line?;
        let line = line.strip_suffix('\r').unwrap_or(&line);
        let result = evaluate_line(line)
            .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, format!("{e}: {line:?}")))?;
        output.write_all(result.as_bytes())?;
        output.write_all(b"\n")?;
    }
    output.flush()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn examples() {
        let input = "12 + 30\n5 - 7\n-7 / 2\n-7 % 2\n2 ^ -1\n0 ^ 0\n-3 cmp -2";
        let mut out = Vec::new();
        run(input.as_bytes(), &mut out).unwrap();
        assert_eq!(String::from_utf8(out).unwrap(), "42\n-2\n-3\n-1\nerror\n1\n-1\n");
    }

    #[test]
    fn malformed() {
        assert_eq!(evaluate_line("1 +"), Err(QueryError::Malformed));
        assert_eq!(evaluate_line("1 ? 2"), Err(QueryError::UnknownOperator));
        assert!(matches!(evaluate_line("x + 2"), Err(QueryError::BadOperand(_))));
    }

    #[test]
    fn empty_input() {
        let mut out = Vec::new();
        run(&b""[..], &mut out).unwrap();
        assert!(out.is_empty());
    }
}
