//! The syntax tree produced by the [parser](crate::parser).

use crate::charset::ByteSet;

/// A node of a parsed pattern.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Node {
    /// A single literal byte.
    Char(u8),
    /// `.`: any single byte.
    Any,
    /// A character class or class escape such as `[a-z]` or `\d`.
    Set(ByteSet),
    /// `^`: matches only at offset 0.
    Bol,
    /// `$`: matches only at the end of the subject.
    Eol,
    /// A capturing group; the number is 1-based, in order of the opening paren.
    Group(usize, Box<Node>),
    /// A sequence of nodes (possibly empty, which matches the empty string).
    Concat(Vec<Node>),
    /// An ordered choice between alternatives.
    Alt(Vec<Node>),
    /// A greedy quantifier. `max == None` means unbounded.
    Repeat {
        /// The repeated node.
        node: Box<Node>,
        /// Minimum iteration count.
        min: u32,
        /// Maximum iteration count, if bounded.
        max: Option<u32>,
    },
}
