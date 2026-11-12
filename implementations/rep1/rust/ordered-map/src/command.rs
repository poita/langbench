//! Parsing of the textual command language.
//!
//! One command per line, tokens separated by single spaces:
//!
//! ```text
//! insert <key> <value>   delete <key>      get <key>
//! size                   min               max
//! floor <key>            ceil <key>        succ <key>      pred <key>
//! rank <key>             select <k>        range <lo> <hi>
//! ```

use std::fmt;
use std::str::FromStr;

/// A parsed command.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Command {
    Insert(i64, String),
    Delete(i64),
    Get(i64),
    Size,
    Min,
    Max,
    Floor(i64),
    Ceil(i64),
    Succ(i64),
    Pred(i64),
    Rank(i64),
    Select(u64),
    Range(i64, i64),
}

/// Why a command line could not be parsed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ParseError {
    /// The line was empty.
    Empty,
    /// The first word is not a known command.
    UnknownCommand(String),
    /// The command has too few or too many arguments.
    WrongArity(&'static str),
    /// An argument could not be parsed as a number.
    BadNumber(String),
}

impl fmt::Display for ParseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ParseError::Empty => write!(f, "empty command"),
            ParseError::UnknownCommand(c) => write!(f, "unknown command `{c}`"),
            ParseError::WrongArity(c) => write!(f, "wrong number of arguments for `{c}`"),
            ParseError::BadNumber(s) => write!(f, "invalid number `{s}`"),
        }
    }
}

impl std::error::Error for ParseError {}

fn int(s: &str) -> Result<i64, ParseError> {
    s.parse().map_err(|_| ParseError::BadNumber(s.to_string()))
}

fn uint(s: &str) -> Result<u64, ParseError> {
    s.parse().map_err(|_| ParseError::BadNumber(s.to_string()))
}

impl FromStr for Command {
    type Err = ParseError;

    fn from_str(line: &str) -> Result<Self, ParseError> {
        let mut parts = line.split(' ');
        let name = parts.next().filter(|s| !s.is_empty()).ok_or(ParseError::Empty)?;
        let args: Vec<&str> = parts.collect();
        let (cmd, arity): (&'static str, usize) = match name {
            "insert" => ("insert", 2),
            "delete" => ("delete", 1),
            "get" => ("get", 1),
            "size" => ("size", 0),
            "min" => ("min", 0),
            "max" => ("max", 0),
            "floor" => ("floor", 1),
            "ceil" => ("ceil", 1),
            "succ" => ("succ", 1),
            "pred" => ("pred", 1),
            "rank" => ("rank", 1),
            "select" => ("select", 1),
            "range" => ("range", 2),
            other => return Err(ParseError::UnknownCommand(other.to_string())),
        };
        if args.len() != arity {
            return Err(ParseError::WrongArity(cmd));
        }
        Ok(match cmd {
            "insert" => Command::Insert(int(args[0])?, args[1].to_string()),
            "delete" => Command::Delete(int(args[0])?),
            "get" => Command::Get(int(args[0])?),
            "size" => Command::Size,
            "min" => Command::Min,
            "max" => Command::Max,
            "floor" => Command::Floor(int(args[0])?),
            "ceil" => Command::Ceil(int(args[0])?),
            "succ" => Command::Succ(int(args[0])?),
            "pred" => Command::Pred(int(args[0])?),
            "rank" => Command::Rank(int(args[0])?),
            "select" => Command::Select(uint(args[0])?),
            _ => Command::Range(int(args[0])?, int(args[1])?),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_every_command() {
        let p = |s: &str| s.parse::<Command>();
        assert_eq!(p("insert -5 a|b"), Ok(Command::Insert(-5, "a|b".into())));
        assert_eq!(p("delete 3"), Ok(Command::Delete(3)));
        assert_eq!(p("get 0"), Ok(Command::Get(0)));
        assert_eq!(p("size"), Ok(Command::Size));
        assert_eq!(p("min"), Ok(Command::Min));
        assert_eq!(p("max"), Ok(Command::Max));
        assert_eq!(p("floor 1"), Ok(Command::Floor(1)));
        assert_eq!(p("ceil 1"), Ok(Command::Ceil(1)));
        assert_eq!(p("succ 9223372036854775807"), Ok(Command::Succ(i64::MAX)));
        assert_eq!(p("pred -9223372036854775808"), Ok(Command::Pred(i64::MIN)));
        assert_eq!(p("rank 7"), Ok(Command::Rank(7)));
        assert_eq!(p("select 1000000000"), Ok(Command::Select(1_000_000_000)));
        assert_eq!(p("range 5 2"), Ok(Command::Range(5, 2)));
    }

    #[test]
    fn rejects_bad_lines() {
        let p = |s: &str| s.parse::<Command>();
        assert_eq!(p(""), Err(ParseError::Empty));
        assert_eq!(p("nope"), Err(ParseError::UnknownCommand("nope".into())));
        assert_eq!(p("get"), Err(ParseError::WrongArity("get")));
        assert_eq!(p("size 1"), Err(ParseError::WrongArity("size")));
        assert_eq!(p("get x"), Err(ParseError::BadNumber("x".into())));
        assert_eq!(p("select -1"), Err(ParseError::BadNumber("-1".into())));
    }
}
