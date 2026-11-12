//! Cell addresses and ranges.

use std::fmt;

/// Maximum column number (`ZZ`).
pub const MAX_COL: u32 = 702;
/// Maximum row number.
pub const MAX_ROW: u32 = 9999;

/// The address of a cell: a column (1..=702, `A`..`ZZ`) and a row (1..=9999).
///
/// Ordering is row-major (row first, then column), which is the order in
/// which [`Sheet::dump`](crate::Sheet::dump) lists cells.
#[derive(Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Debug)]
pub struct CellRef {
    row: u32,
    col: u32,
}

impl CellRef {
    /// Creates a reference from a 1-based column and row, if both are in range.
    pub fn new(col: u32, row: u32) -> Option<CellRef> {
        if (1..=MAX_COL).contains(&col) && (1..=MAX_ROW).contains(&row) {
            Some(CellRef { row, col })
        } else {
            None
        }
    }

    /// Parses a name such as `A1` or `ZZ9999`. Returns `None` unless the whole
    /// string is a valid cell name (one or two uppercase letters, then a row
    /// number 1..=9999 without leading zeros).
    pub fn parse(name: &str) -> Option<CellRef> {
        let bytes = name.as_bytes();
        let letters = bytes.iter().take_while(|b| b.is_ascii_uppercase()).count();
        Self::from_parts(&bytes[..letters], &bytes[letters..])
    }

    /// Builds a reference from the letters and digits of a name, validating
    /// both parts.
    pub(crate) fn from_parts(letters: &[u8], digits: &[u8]) -> Option<CellRef> {
        if letters.is_empty() || letters.len() > 2 || digits.is_empty() || digits.len() > 4 {
            return None;
        }
        if digits[0] == b'0' || !digits.iter().all(u8::is_ascii_digit) {
            return None;
        }
        let mut col = 0u32;
        for &l in letters {
            if !l.is_ascii_uppercase() {
                return None;
            }
            col = col * 26 + (l - b'A') as u32 + 1;
        }
        let row = digits.iter().fold(0u32, |r, d| r * 10 + (d - b'0') as u32);
        CellRef::new(col, row)
    }

    /// The 1-based column number.
    pub fn col(self) -> u32 {
        self.col
    }

    /// The 1-based row number.
    pub fn row(self) -> u32 {
        self.row
    }

    /// A dense integer key, unique per cell.
    pub(crate) fn key(self) -> u32 {
        self.row * (MAX_COL + 1) + self.col
    }

    pub(crate) fn from_key(key: u32) -> CellRef {
        CellRef { row: key / (MAX_COL + 1), col: key % (MAX_COL + 1) }
    }
}

impl fmt::Display for CellRef {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let mut letters = Vec::new();
        let mut c = self.col;
        while c > 0 {
            c -= 1;
            letters.push(b'A' + (c % 26) as u8);
            c /= 26;
        }
        letters.reverse();
        write!(f, "{}{}", String::from_utf8_lossy(&letters), self.row)
    }
}

/// A rectangular range of cells, given by two corners in either order.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct Range {
    /// Top-left corner (smallest column and row).
    pub start: CellRef,
    /// Bottom-right corner (largest column and row).
    pub end: CellRef,
}

impl Range {
    /// The rectangle spanned by two corner cells, in either order.
    pub fn new(a: CellRef, b: CellRef) -> Range {
        Range {
            start: CellRef { row: a.row.min(b.row), col: a.col.min(b.col) },
            end: CellRef { row: a.row.max(b.row), col: a.col.max(b.col) },
        }
    }

    /// Iterates over the covered cells in row-major order.
    pub fn cells(&self) -> impl Iterator<Item = CellRef> {
        let (c0, c1) = (self.start.col, self.end.col);
        (self.start.row..=self.end.row)
            .flat_map(move |row| (c0..=c1).map(move |col| CellRef { row, col }))
    }

    /// The number of cells covered.
    pub fn len(&self) -> usize {
        ((self.end.row - self.start.row + 1) * (self.end.col - self.start.col + 1)) as usize
    }

    /// Always false: a range covers at least one cell.
    pub fn is_empty(&self) -> bool {
        false
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_and_display_round_trip() {
        for name in ["A1", "Z9", "AA10", "ZZ9999", "AB123"] {
            assert_eq!(CellRef::parse(name).unwrap().to_string(), name);
        }
    }

    #[test]
    fn rejects_invalid_names() {
        for name in ["AAA1", "A0", "A10000", "A01", "a1", "A", "1", "", "A1B", "A-1"] {
            assert!(CellRef::parse(name).is_none(), "{name}");
        }
    }

    #[test]
    fn ordering_is_row_major() {
        let a2 = CellRef::parse("A2").unwrap();
        let b1 = CellRef::parse("B1").unwrap();
        let aa1 = CellRef::parse("AA1").unwrap();
        assert!(b1 < a2);
        assert!(b1 < aa1);
    }

    #[test]
    fn key_round_trip() {
        let c = CellRef::parse("ZZ9999").unwrap();
        assert_eq!(CellRef::from_key(c.key()), c);
    }

    #[test]
    fn range_normalises_corners() {
        let r = Range::new(CellRef::parse("B2").unwrap(), CellRef::parse("A1").unwrap());
        assert_eq!(r.start.to_string(), "A1");
        assert_eq!(r.end.to_string(), "B2");
        let names: Vec<_> = r.cells().map(|c| c.to_string()).collect();
        assert_eq!(names, ["A1", "B1", "A2", "B2"]);
        assert_eq!(r.len(), 4);
    }
}
