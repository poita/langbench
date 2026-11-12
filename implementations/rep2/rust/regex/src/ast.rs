//! The syntax tree produced by the parser.

use crate::charset::CharSet;

/// A node of the parsed pattern.
#[derive(Debug, Clone, PartialEq)]
pub enum Node {
    /// Matches the empty string (an empty branch or `()` body).
    Empty,
    /// A literal byte.
    Char(u8),
    /// `.`: any single byte.
    Any,
    /// A character class, `\d`-style escape, etc.
    Set(CharSet),
    /// `^`: only at position 0.
    Bol,
    /// `$`: only at the end of the subject.
    Eol,
    /// A capturing group with its 1-based number.
    Group(usize, Box<Node>),
    /// Items matched one after another.
    Concat(Vec<Node>),
    /// Ordered alternatives.
    Alt(Vec<Node>),
    /// A greedy repetition; `max == None` means unbounded.
    Repeat {
        node: Box<Node>,
        min: u32,
        max: Option<u32>,
    },
}
