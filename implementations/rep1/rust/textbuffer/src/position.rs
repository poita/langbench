//! Positions inside a document.

use std::fmt;

/// A `(line, col)` position in a document, both 0-based.
///
/// Columns are byte indices into the line, which are also character indices
/// because the buffer only holds ASCII text. Positions order lexicographically
/// (line first, then column), which is the order in which they occur in the
/// document text.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct Position {
    /// Line index, `0 <= line < line_count`.
    pub line: usize,
    /// Column, `0 <= col <= line length`.
    pub col: usize,
}

impl Position {
    /// Creates a position.
    #[inline]
    pub const fn new(line: usize, col: usize) -> Self {
        Position { line, col }
    }
}

impl fmt::Display for Position {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{} {}", self.line, self.col)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn orders_by_line_then_column() {
        assert!(Position::new(0, 9) < Position::new(1, 0));
        assert!(Position::new(2, 1) < Position::new(2, 2));
        assert_eq!(Position::new(3, 3), Position::new(3, 3));
    }

    #[test]
    fn displays_as_line_space_col() {
        assert_eq!(Position::new(4, 7).to_string(), "4 7");
    }
}
