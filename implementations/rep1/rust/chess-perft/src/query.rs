//! The line-oriented query format used by the command-line tool.
//!
//! A query line is a six-field FEN followed by either a depth (perft) or the
//! word `divide` and a depth:
//!
//! ```text
//! <placement> <side> <castling> <ep> <halfmove> <fullmove> <depth>
//! <placement> <side> <castling> <ep> <halfmove> <fullmove> divide <depth>
//! ```

use crate::error::ParseError;
use crate::perft::{divide, perft};
use crate::position::Position;
use std::fmt::Write;

/// What to compute for a position.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum QueryKind {
    /// A single node count.
    Perft,
    /// Per-root-move counts plus a total.
    Divide,
}

/// A parsed query line.
#[derive(Clone, Debug)]
pub struct Query {
    /// The position to search from.
    pub position: Position,
    /// Perft or divide.
    pub kind: QueryKind,
    /// Search depth in plies.
    pub depth: u32,
}

impl Query {
    /// Parses one query line (without its trailing newline).
    pub fn parse(line: &str) -> Result<Query, ParseError> {
        let fields: Vec<&str> = line.split_whitespace().collect();
        let (kind, depth) = match fields.as_slice() {
            [_, _, _, _, _, _, depth] => (QueryKind::Perft, depth),
            [_, _, _, _, _, _, "divide", depth] => (QueryKind::Divide, depth),
            _ => return Err(ParseError::FieldCount(fields.len())),
        };
        let depth = depth.parse::<u32>().map_err(|_| ParseError::Number(depth.to_string()))?;
        let position = Position::from_fen(&fields[..6].join(" "))?;
        Ok(Query { position, kind, depth })
    }

    /// Runs the query and appends its output lines (each ending in `\n`) to `out`.
    pub fn answer(&self, out: &mut String) {
        match self.kind {
            QueryKind::Perft => {
                let _ = writeln!(out, "{}", perft(&self.position, self.depth));
            }
            QueryKind::Divide => {
                let mut rows: Vec<(String, u64)> = divide(&self.position, self.depth)
                    .into_iter()
                    .map(|(mv, n)| (mv.to_string(), n))
                    .collect();
                rows.sort();
                let mut total = 0;
                for (mv, n) in &rows {
                    total += n;
                    let _ = writeln!(out, "{mv} {n}");
                }
                let _ = writeln!(out, "total {total}");
            }
        }
    }
}

/// Answers every query in `input` (one per line) and returns the output text.
///
/// Empty input gives empty output. Fails on the first malformed line.
pub fn run(input: &str) -> Result<String, ParseError> {
    let mut out = String::new();
    for line in input.lines() {
        Query::parse(line)?.answer(&mut out);
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_both_forms() {
        let q = Query::parse("8/8/8/8/8/8/8/K6k w - - 0 1 3").unwrap();
        assert_eq!((q.kind, q.depth), (QueryKind::Perft, 3));
        let q = Query::parse("8/8/8/8/8/8/8/K6k w - - 0 1 divide 2").unwrap();
        assert_eq!((q.kind, q.depth), (QueryKind::Divide, 2));
    }

    #[test]
    fn rejects_malformed() {
        assert!(Query::parse("").is_err());
        assert!(Query::parse("8/8/8/8/8/8/8/K6k w - - 0 1").is_err());
        assert!(Query::parse("8/8/8/8/8/8/8/K6k w - - 0 1 x").is_err());
    }

    #[test]
    fn empty_input_empty_output() {
        assert_eq!(run("").unwrap(), "");
    }
}
