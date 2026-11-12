//! The text of the buffer: a sequence of lines.

use crate::position::Position;

/// A document: one or more lines of ASCII text joined by `\n`.
///
/// The document always holds at least one line; an empty document is a
/// single empty line. Lines never contain `\n`.
///
/// All editing goes through [`Document::replace`], which splices a range of
/// the text. A replacement costs `O(ℓ + m)` within a line (`ℓ` the line
/// length, `m` the text length) plus `O(L)` when the number of lines changes.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Document {
    lines: Vec<String>,
}

impl Default for Document {
    fn default() -> Self {
        Document::new()
    }
}

impl Document {
    /// An empty document (one empty line).
    pub fn new() -> Self {
        Document {
            lines: vec![String::new()],
        }
    }

    /// Builds a document from the given lines. An empty vector gives the
    /// empty document.
    ///
    /// # Panics
    /// If a line contains `\n` or a non-ASCII character.
    pub fn from_lines(lines: Vec<String>) -> Self {
        assert!(lines.iter().all(|l| l.is_ascii() && !l.contains('\n')));
        if lines.is_empty() {
            Document::new()
        } else {
            Document { lines }
        }
    }

    /// Builds a document from text, splitting it at every `\n`.
    ///
    /// # Panics
    /// If the text contains a non-ASCII character.
    pub fn from_text(text: &str) -> Self {
        assert!(text.is_ascii(), "documents hold ASCII text only");
        Document {
            lines: text.split('\n').map(String::from).collect(),
        }
    }

    /// Number of lines (at least 1).
    #[inline]
    pub fn line_count(&self) -> usize {
        self.lines.len()
    }

    /// The text of line `index`. Panics when out of range.
    #[inline]
    pub fn line(&self, index: usize) -> &str {
        &self.lines[index]
    }

    /// Length in bytes of line `index`. Panics when out of range.
    #[inline]
    pub fn line_len(&self, index: usize) -> usize {
        self.lines[index].len()
    }

    /// Iterates over the lines.
    pub fn lines(&self) -> impl ExactSizeIterator<Item = &str> {
        self.lines.iter().map(String::as_str)
    }

    /// The whole text, lines joined by `\n` with no trailing newline.
    pub fn text(&self) -> String {
        self.lines.join("\n")
    }

    /// The position at the very end of the document.
    pub fn end(&self) -> Position {
        let line = self.lines.len() - 1;
        Position::new(line, self.lines[line].len())
    }

    /// Clamps arbitrary numbers to a valid position: first the line to
    /// `[0, L-1]`, then the column to `[0, len(line)]`.
    pub fn clamp(&self, line: usize, col: usize) -> Position {
        let line = line.min(self.lines.len() - 1);
        Position::new(line, col.min(self.lines[line].len()))
    }

    /// The position one character before `p`, or `p` itself at the start of
    /// the document. Crossing a line break lands at the end of the previous line.
    pub fn prev(&self, p: Position) -> Position {
        if p.col > 0 {
            Position::new(p.line, p.col - 1)
        } else if p.line > 0 {
            Position::new(p.line - 1, self.lines[p.line - 1].len())
        } else {
            p
        }
    }

    /// The position one character after `p`, or `p` itself at the end of the
    /// document. Crossing a line break lands at column 0 of the next line.
    pub fn next(&self, p: Position) -> Position {
        if p.col < self.lines[p.line].len() {
            Position::new(p.line, p.col + 1)
        } else if p.line + 1 < self.lines.len() {
            Position::new(p.line + 1, 0)
        } else {
            p
        }
    }

    /// The text between two positions (`start <= end`), with `\n` between lines.
    pub fn text_between(&self, start: Position, end: Position) -> String {
        debug_assert!(start <= end);
        if start.line == end.line {
            return self.lines[start.line][start.col..end.col].to_string();
        }
        let mut out = String::new();
        out.push_str(&self.lines[start.line][start.col..]);
        for l in &self.lines[start.line + 1..end.line] {
            out.push('\n');
            out.push_str(l);
        }
        out.push('\n');
        out.push_str(&self.lines[end.line][..end.col]);
        out
    }

    /// Replaces the text between `start` and `end` (`start <= end`) with
    /// `text`, which may contain `\n`. The text must be ASCII.
    pub fn replace(&mut self, start: Position, end: Position, text: &str) {
        debug_assert!(start <= end);
        debug_assert!(text.is_ascii());
        if start.line == end.line && !text.contains('\n') {
            self.lines[start.line].replace_range(start.col..end.col, text);
            return;
        }
        // Everything after `end` on its line is carried over to the last new line.
        let tail = if start.line == end.line {
            self.lines[start.line].split_off(end.col)
        } else {
            let mut last = std::mem::take(&mut self.lines[end.line]);
            last.drain(..end.col);
            last
        };
        let mut pieces = text.split('\n');
        let first = pieces.next().unwrap_or("");
        let head = &mut self.lines[start.line];
        head.truncate(start.col);
        head.push_str(first);
        let mut new_lines: Vec<String> = pieces.map(String::from).collect();
        match new_lines.last_mut() {
            Some(last) => last.push_str(&tail),
            None => head.push_str(&tail),
        }
        let removed_end = if start.line == end.line {
            start.line + 1
        } else {
            end.line + 1
        };
        self.lines.splice(start.line + 1..removed_end, new_lines);
    }
}

/// The position reached after inserting `text` at `start`: the end of the
/// inserted text.
pub fn end_of_text(start: Position, text: &str) -> Position {
    match text.rfind('\n') {
        None => Position::new(start.line, start.col + text.len()),
        Some(last) => {
            let newlines = text.bytes().filter(|&b| b == b'\n').count();
            Position::new(start.line + newlines, text.len() - last - 1)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn p(l: usize, c: usize) -> Position {
        Position::new(l, c)
    }

    #[test]
    fn empty_document_is_one_empty_line() {
        let d = Document::new();
        assert_eq!(d.line_count(), 1);
        assert_eq!(d.text(), "");
        assert_eq!(Document::from_lines(vec![]), d);
        assert_eq!(Document::from_text(""), d);
    }

    #[test]
    fn clamp_line_then_column() {
        let d = Document::from_text("abc\nde");
        assert_eq!(d.clamp(0, 99), p(0, 3));
        assert_eq!(d.clamp(99, 99), p(1, 2));
        assert_eq!(d.clamp(1, 1), p(1, 1));
    }

    #[test]
    fn prev_and_next_cross_lines() {
        let d = Document::from_text("ab\n\ncd");
        assert_eq!(d.prev(p(0, 0)), p(0, 0));
        assert_eq!(d.prev(p(1, 0)), p(0, 2));
        assert_eq!(d.prev(p(2, 0)), p(1, 0));
        assert_eq!(d.next(p(0, 2)), p(1, 0));
        assert_eq!(d.next(p(1, 0)), p(2, 0));
        assert_eq!(d.next(p(2, 2)), p(2, 2));
    }

    #[test]
    fn text_between_spans_lines() {
        let d = Document::from_text("abc\ndef\nghi");
        assert_eq!(d.text_between(p(0, 1), p(0, 3)), "bc");
        assert_eq!(d.text_between(p(0, 1), p(2, 2)), "bc\ndef\ngh");
        assert_eq!(d.text_between(p(0, 3), p(1, 0)), "\n");
    }

    #[test]
    fn replace_within_a_line() {
        let mut d = Document::from_text("hello");
        d.replace(p(0, 1), p(0, 4), "ipp");
        assert_eq!(d.text(), "hippo");
        d.replace(p(0, 5), p(0, 5), "!");
        assert_eq!(d.text(), "hippo!");
    }

    #[test]
    fn replace_inserting_lines() {
        let mut d = Document::from_text("abcdef");
        d.replace(p(0, 2), p(0, 4), "X\nY\nZ");
        assert_eq!(d.text(), "abX\nY\nZef");
        assert_eq!(d.line_count(), 3);
    }

    #[test]
    fn replace_removing_lines() {
        let mut d = Document::from_text("abc\ndef\nghi");
        d.replace(p(0, 1), p(2, 2), "");
        assert_eq!(d.text(), "ai");
        let mut d = Document::from_text("abc\ndef\nghi");
        d.replace(p(0, 3), p(1, 0), "");
        assert_eq!(d.text(), "abcdef\nghi");
    }

    #[test]
    fn replace_multi_line_range_with_multi_line_text() {
        let mut d = Document::from_text("abc\ndef\nghi");
        d.replace(p(0, 1), p(1, 1), "1\n2");
        assert_eq!(d.text(), "a1\n2ef\nghi");
    }

    #[test]
    fn end_of_text_counts_lines() {
        assert_eq!(end_of_text(p(2, 3), "abc"), p(2, 6));
        assert_eq!(end_of_text(p(2, 3), "a\nbc"), p(3, 2));
        assert_eq!(end_of_text(p(2, 3), "\n"), p(3, 0));
        assert_eq!(end_of_text(p(2, 3), ""), p(2, 3));
    }
}
