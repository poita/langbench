//! Line splitting and line-ending normalisation.
//!
//! A line ends at the next LF. When requested, a single CR immediately before
//! the LF is part of the terminator too. A byte string ending in LF does not
//! produce a final empty line.

/// One line of a byte string, described by offsets into it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Line {
    /// Offset of the first byte of the line.
    pub start: usize,
    /// Offset just past the last content byte (the terminator is excluded).
    pub end: usize,
    /// Offset of the first byte of the following line.
    pub next: usize,
}

impl Line {
    /// Length of the line's content in bytes.
    pub fn len(&self) -> usize {
        self.end - self.start
    }

    /// Whether the line has no content.
    pub fn is_empty(&self) -> bool {
        self.end == self.start
    }
}

/// Iterator over the [`Line`]s of a byte string.
#[derive(Debug, Clone)]
pub struct Lines<'a> {
    data: &'a [u8],
    pos: usize,
    strip_cr: bool,
}

impl<'a> Lines<'a> {
    /// Splits `data` on LF only; a CR before the LF stays in the line.
    pub fn lf(data: &'a [u8]) -> Self {
        Lines { data, pos: 0, strip_cr: false }
    }

    /// Splits `data` on LF or CRLF.
    pub fn crlf(data: &'a [u8]) -> Self {
        Lines { data, pos: 0, strip_cr: true }
    }
}

impl Iterator for Lines<'_> {
    type Item = Line;

    fn next(&mut self) -> Option<Line> {
        let start = self.pos;
        if start >= self.data.len() {
            return None;
        }
        match self.data[start..].iter().position(|&b| b == b'\n') {
            Some(off) => {
                let lf = start + off;
                let mut end = lf;
                if self.strip_cr && end > start && self.data[end - 1] == b'\r' {
                    end -= 1;
                }
                self.pos = lf + 1;
                Some(Line { start, end, next: lf + 1 })
            }
            None => {
                self.pos = self.data.len();
                Some(Line { start, end: self.data.len(), next: self.data.len() })
            }
        }
    }
}

/// Replaces every CRLF by a single LF; nothing else changes.
pub fn normalize_newlines(data: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(data.len());
    let mut i = 0;
    while i < data.len() {
        if data[i] == b'\r' && data.get(i + 1) == Some(&b'\n') {
            out.push(b'\n');
            i += 2;
        } else {
            out.push(data[i]);
            i += 1;
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn contents(data: &[u8], crlf: bool) -> Vec<&[u8]> {
        let it = if crlf { Lines::crlf(data) } else { Lines::lf(data) };
        it.map(|l| &data[l.start..l.end]).collect()
    }

    #[test]
    fn trailing_lf_makes_no_empty_line() {
        assert_eq!(contents(b"a\nb\n", false), vec![&b"a"[..], b"b"]);
        assert_eq!(contents(b"a\nb", false), vec![&b"a"[..], b"b"]);
        assert!(contents(b"", false).is_empty());
        assert_eq!(contents(b"\n", false), vec![&b""[..]]);
    }

    #[test]
    fn cr_handling() {
        assert_eq!(contents(b"a\r\nb\r", true), vec![&b"a"[..], b"b\r"]);
        assert_eq!(contents(b"a\r\n", false), vec![&b"a\r"[..]]);
    }

    #[test]
    fn normalises_only_crlf() {
        assert_eq!(normalize_newlines(b"a\r\nb\rc\n\r\n"), b"a\nb\rc\n\n");
    }
}
