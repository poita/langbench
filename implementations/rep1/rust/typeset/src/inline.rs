//! The inline scanner: styles, escapes, footnotes and discretionary points.

use crate::ast::{Inline, Tag};
use crate::error::{Code, Error};

/// A position in `document.cdx`: 1-based line and column.
pub type Pos = (usize, usize);

/// Text assembled from one or more source lines, remembering where every
/// character came from so that errors can be located.
#[derive(Clone, Debug, Default)]
pub struct SrcText {
    pub chars: Vec<char>,
    pub pos: Vec<Pos>,
}

impl SrcText {
    pub fn new() -> SrcText {
        SrcText::default()
    }

    /// Appends characters; the first has column `first_col` on `line`.
    pub fn push_chars(&mut self, chars: &[char], line: usize, first_col: usize) {
        for (i, &c) in chars.iter().enumerate() {
            self.chars.push(c);
            self.pos.push((line, first_col + i));
        }
    }

    /// Appends the single space that joins two source lines.
    pub fn push_joiner(&mut self) {
        let p = self.pos.last().copied().map(|(l, c)| (l, c + 1)).unwrap_or((0, 0));
        self.chars.push(' ');
        self.pos.push(p);
    }

    pub fn is_empty(&self) -> bool {
        self.chars.is_empty()
    }

    /// A sub-range as its own text.
    pub fn slice(&self, a: usize, b: usize) -> SrcText {
        SrcText { chars: self.chars[a..b].to_vec(), pos: self.pos[a..b].to_vec() }
    }
}

struct Scanner<'a> {
    src: &'a SrcText,
    i: usize,
    allow_notes: bool,
    counter: &'a mut usize,
}

/// Scans inline text.
///
/// `allow_notes` says whether `{n|...}` is permitted here; `counter` holds
/// the number of footnotes seen so far in the document and is advanced for
/// every footnote found.
pub fn parse_inline(src: &SrcText, allow_notes: bool, counter: &mut usize) -> Result<Vec<Inline>, Error> {
    let mut sc = Scanner { src, i: 0, allow_notes, counter };
    sc.run(None, false)
}

impl Scanner<'_> {
    fn err(&self, at: usize, code: Code) -> Error {
        let (l, c) = self.src.pos[at];
        Error::document(l, c, code)
    }

    /// Scans until the closing brace of the span opened at `open` (or the
    /// end of the text when `open` is `None`).
    fn run(&mut self, open: Option<usize>, in_note: bool) -> Result<Vec<Inline>, Error> {
        let chars = &self.src.chars;
        let n = chars.len();
        let mut out = Vec::new();
        loop {
            if self.i >= n {
                return match open {
                    Some(o) => Err(self.err(o, Code::UnclosedInline)),
                    None => Ok(out),
                };
            }
            let at = self.i;
            match chars[at] {
                '{' => {
                    let tag = match (chars.get(at + 1), chars.get(at + 2)) {
                        (Some(&t), Some('|')) => match t {
                            'b' => Some(Some(Tag::Bold)),
                            'i' => Some(Some(Tag::Italic)),
                            'm' => Some(Some(Tag::Mono)),
                            '+' => Some(Some(Tag::Larger)),
                            '-' => Some(Some(Tag::Smaller)),
                            'n' => Some(None),
                            _ => None,
                        },
                        _ => None,
                    };
                    let Some(tag) = tag else { return Err(self.err(at, Code::UnknownInline)) };
                    self.i += 3;
                    match tag {
                        Some(t) => {
                            let inner = self.run(Some(at), in_note)?;
                            out.push(Inline::Style(t, inner));
                        }
                        None => {
                            if !self.allow_notes {
                                return Err(self.err(at, Code::FootnoteNotAllowed));
                            }
                            if in_note {
                                return Err(self.err(at, Code::NestedFootnote));
                            }
                            *self.counter += 1;
                            let number = *self.counter;
                            let inner = self.run(Some(at), true)?;
                            out.push(Inline::Note(number, inner));
                        }
                    }
                }
                '}' => {
                    if open.is_some() {
                        self.i += 1;
                        return Ok(out);
                    }
                    return Err(self.err(at, Code::StrayBrace));
                }
                '\\' => {
                    match chars.get(at + 1) {
                        Some(&e) if matches!(e, '{' | '}' | '|' | '\\' | '@' | '~') => out.push(Inline::Char(e)),
                        Some(' ') => out.push(Inline::Rigid),
                        Some('-') => out.push(Inline::Disc),
                        _ => return Err(self.err(at, Code::BadEscape)),
                    }
                    self.i += 2;
                }
                '~' => {
                    out.push(Inline::Rigid);
                    self.i += 1;
                }
                ' ' => {
                    out.push(Inline::Space);
                    self.i += 1;
                }
                c => {
                    out.push(Inline::Char(c));
                    self.i += 1;
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn src(s: &str) -> SrcText {
        let mut t = SrcText::new();
        let c: Vec<char> = s.chars().collect();
        t.push_chars(&c, 1, 1);
        t
    }

    fn parse(s: &str) -> Result<Vec<Inline>, String> {
        let mut n = 0;
        parse_inline(&src(s), true, &mut n).map_err(|e| format!("{}:{}:{}", e.line, e.col, e.code.as_str()))
    }

    #[test]
    fn nested_styles() {
        let r = parse("{b|{i|x}}").unwrap();
        assert_eq!(r, vec![Inline::Style(Tag::Bold, vec![Inline::Style(Tag::Italic, vec![Inline::Char('x')])])]);
    }

    #[test]
    fn escapes() {
        assert_eq!(parse("\\{\\ \\-~").unwrap(), vec![Inline::Char('{'), Inline::Rigid, Inline::Disc, Inline::Rigid]);
    }

    #[test]
    fn errors() {
        assert_eq!(parse("a {z|b}").unwrap_err(), "1:3:unknown-inline");
        assert_eq!(parse("{b|{i|x}").unwrap_err(), "1:1:unclosed-inline");
        assert_eq!(parse("{b|{i|x").unwrap_err(), "1:4:unclosed-inline");
        assert_eq!(parse("ab}").unwrap_err(), "1:3:stray-brace");
        assert_eq!(parse("ab\\").unwrap_err(), "1:3:bad-escape");
        assert_eq!(parse("{n|a {n|b}}").unwrap_err(), "1:6:nested-footnote");
    }

    #[test]
    fn footnotes_are_numbered() {
        let mut n = 0;
        let r = parse_inline(&src("a{n|x}b{n|y}"), true, &mut n).unwrap();
        assert_eq!(n, 2);
        assert!(matches!(r[1], Inline::Note(1, _)));
        assert!(matches!(r[3], Inline::Note(2, _)));
        let mut n = 0;
        let e = parse_inline(&src("a{n|x}"), false, &mut n).unwrap_err();
        assert_eq!(e.code, Code::FootnoteNotAllowed);
    }
}
