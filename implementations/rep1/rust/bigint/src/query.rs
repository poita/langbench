//! The line-oriented query language used by the command-line tool.
//!
//! Each line has the form `<a> <op> <b>` with `op` one of `+ - * / % ^ cmp`.
//! [`run`] evaluates a whole input text and returns the output text.

use std::fmt::Write;
use std::str::FromStr;

use crate::error::ParseError;
use crate::int::BigInt;

/// A binary operator.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Op {
    Add,
    Sub,
    Mul,
    Div,
    Rem,
    Pow,
    Cmp,
}

impl FromStr for Op {
    type Err = ParseError;
    fn from_str(s: &str) -> Result<Op, ParseError> {
        Ok(match s {
            "+" => Op::Add,
            "-" => Op::Sub,
            "*" => Op::Mul,
            "/" => Op::Div,
            "%" => Op::Rem,
            "^" => Op::Pow,
            "cmp" => Op::Cmp,
            other => return Err(ParseError::UnknownOperator(other.to_string())),
        })
    }
}

/// A parsed query: `lhs op rhs`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Query {
    pub lhs: BigInt,
    pub op: Op,
    pub rhs: BigInt,
}

impl FromStr for Query {
    type Err = ParseError;

    fn from_str(line: &str) -> Result<Query, ParseError> {
        let mut parts = line.split(' ');
        let (a, op, b) = match (parts.next(), parts.next(), parts.next(), parts.next()) {
            (Some(a), Some(op), Some(b), None) => (a, op, b),
            _ => return Err(ParseError::InvalidQuery),
        };
        Ok(Query {
            lhs: a.parse()?,
            op: op.parse()?,
            rhs: b.parse()?,
        })
    }
}

impl Query {
    /// Evaluates the query. Arithmetic errors (division by zero, negative
    /// exponent) yield `None`; `cmp` yields −1, 0 or 1.
    pub fn evaluate(&self) -> Option<BigInt> {
        let (a, b) = (&self.lhs, &self.rhs);
        match self.op {
            Op::Add => Some(a + b),
            Op::Sub => Some(a - b),
            Op::Mul => Some(a * b),
            Op::Div => a.div(b).ok(),
            Op::Rem => a.rem(b).ok(),
            Op::Pow => a.pow(b).ok(),
            Op::Cmp => Some(BigInt::from(a.cmp(b) as i64)),
        }
    }
}

/// Evaluates one query line, returning the output line (without newline):
/// the result in canonical decimal form, or `error`.
pub fn evaluate_line(line: &str) -> Result<String, ParseError> {
    let q: Query = line.parse()?;
    Ok(q.evaluate().map_or_else(|| "error".to_string(), |v| v.to_string()))
}

/// Evaluates every line of `input`, producing one `\n`-terminated output line
/// per query. Lines that cannot be parsed produce `error` as well.
pub fn run(input: &str) -> String {
    let mut out = String::new();
    for line in input.lines() {
        let line = evaluate_line(line).unwrap_or_else(|_| "error".to_string());
        let _ = writeln!(out, "{line}");
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn spec_examples() {
        let input = "12 + 30\n5 - 7\n-7 / 2\n-7 % 2";
        assert_eq!(run(input), "42\n-2\n-3\n-1\n");
        assert_eq!(run(""), "");
    }

    #[test]
    fn errors_and_zero() {
        assert_eq!(run("1 / 0\n0 % 0\n2 ^ -1\n5 / -0\n5 ^ -0\n-0 ^ -00\n"), "error\nerror\nerror\nerror\n1\n1\n");
    }

    #[test]
    fn parse_failures() {
        assert!("1 +".parse::<Query>().is_err());
        assert!("1 ? 2".parse::<Query>().is_err());
        assert!("1  + 2".parse::<Query>().is_err());
    }
}
