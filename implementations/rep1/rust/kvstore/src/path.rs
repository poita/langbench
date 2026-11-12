//! Field paths such as `address.city`.

use crate::error::{Error, Result};

/// Maximum number of segments in a path.
pub const MAX_PATH_SEGMENTS: usize = 8;
/// Maximum length in bytes of a path's text (segments joined by `.`).
pub const MAX_PATH: usize = 30;

/// A field path: one or more segments, each `[A-Za-z_][A-Za-z0-9_]*`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Path {
    segments: Vec<String>,
    text: String,
}

impl Path {
    /// An empty path, to be extended with [`Path::push_segment`].
    pub fn empty() -> Path {
        Path { segments: Vec::new(), text: String::new() }
    }

    /// Parses `text` (segments separated by `.`, no whitespace).
    ///
    /// ```
    /// let p = tessera::Path::parse("addr.city").unwrap();
    /// assert_eq!(p.segments(), ["addr", "city"]);
    /// ```
    pub fn parse(text: &str) -> Result<Path> {
        let mut p = Path::empty();
        for seg in text.split('.') {
            if !is_word(seg) {
                return Err(Error::Syntax);
            }
            p.push_segment(seg)?;
        }
        Ok(p)
    }

    /// Appends a segment, failing with [`Error::BadPath`] as soon as the
    /// path has more than [`MAX_PATH_SEGMENTS`] segments or its text is
    /// longer than [`MAX_PATH`] bytes.
    pub fn push_segment(&mut self, seg: &str) -> Result<()> {
        if !self.segments.is_empty() {
            self.text.push('.');
        }
        self.text.push_str(seg);
        self.segments.push(seg.to_string());
        if self.segments.len() > MAX_PATH_SEGMENTS || self.text.len() > MAX_PATH {
            return Err(Error::BadPath);
        }
        Ok(())
    }

    /// The segments in order.
    pub fn segments(&self) -> &[String] {
        &self.segments
    }

    /// The path text: segments joined by `.`.
    pub fn text(&self) -> &str {
        &self.text
    }
}

fn is_word(s: &str) -> bool {
    let b = s.as_bytes();
    !b.is_empty()
        && (b[0].is_ascii_alphabetic() || b[0] == b'_')
        && b.iter().all(|c| c.is_ascii_alphanumeric() || *c == b'_')
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn limits() {
        assert!(Path::parse("a.b.c.d.e.f.g.h").is_ok());
        assert_eq!(Path::parse("a.b.c.d.e.f.g.h.i"), Err(Error::BadPath));
        assert!(Path::parse(&"x".repeat(30)).is_ok());
        assert_eq!(Path::parse(&"x".repeat(31)), Err(Error::BadPath));
        assert_eq!(Path::parse("a..b"), Err(Error::Syntax));
        assert_eq!(Path::parse("a.b").unwrap().text(), "a.b");
    }
}
