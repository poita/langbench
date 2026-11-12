//! The Codexa parser: line classification, the block stack, directive
//! attributes and error detection, producing a [`Document`].

use crate::ast::*;
use crate::error::{Code, Error};
use crate::inline::{parse_inline, SrcText};
use crate::metrics::Family;
use crate::settings::Align;
use crate::values::{parse_integer, parse_length};

/// Parses the text of a `document.cdx`.
pub fn parse_document(text: &str) -> Result<Document, Error> {
    let mut lines: Vec<Vec<char>> = text.split('\n').map(|l| l.chars().collect()).collect();
    if lines.last().map(|l| l.is_empty()) == Some(true) {
        lines.pop();
    }
    let mut p = Parser::default();
    for (i, line) in lines.iter().enumerate() {
        p.line(line, i + 1)?;
    }
    p.finish(lines.len())
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Dir {
    Doc,
    Toc,
    Heading(usize, bool),
    Quote,
    Block,
    Ul,
    Ol,
    Li,
    Table,
    HRule,
    Pre,
    Fig,
    Rule,
    VSpace,
    NewPage,
    End,
}

impl Dir {
    fn lookup(name: &str) -> Option<Dir> {
        Some(match name {
            "@doc" => Dir::Doc,
            "@toc" => Dir::Toc,
            "@q" => Dir::Quote,
            "@block" => Dir::Block,
            "@ul" => Dir::Ul,
            "@ol" => Dir::Ol,
            "@li" => Dir::Li,
            "@table" => Dir::Table,
            "@hrule" => Dir::HRule,
            "@pre" => Dir::Pre,
            "@fig" => Dir::Fig,
            "@rule" => Dir::Rule,
            "@vspace" => Dir::VSpace,
            "@newpage" => Dir::NewPage,
            "@end" => Dir::End,
            _ => {
                let b = name.as_bytes();
                if b.len() >= 3 && b.len() <= 4 && b.starts_with(b"@h") && (b'1'..=b'4').contains(&b[2]) {
                    let star = match b.get(3) {
                        None => false,
                        Some(b'*') => true,
                        _ => return None,
                    };
                    return Some(Dir::Heading((b[2] - b'0') as usize, star));
                }
                return None;
            }
        })
    }

    /// (allowed attribute names, required attribute names)
    fn attrs(self) -> (&'static [&'static str], &'static [&'static str]) {
        match self {
            Dir::Toc => (&["title"], &[]),
            Dir::Block => (&["align", "indent", "right-indent", "font", "size", "leading"], &[]),
            Dir::Ol => (&["start"], &[]),
            Dir::Table => (&["cols", "align"], &["cols"]),
            Dir::Fig => (&["height", "width"], &["height"]),
            Dir::VSpace => (&["height"], &["height"]),
            _ => (&[], &[]),
        }
    }
}

struct Attr {
    name: String,
    value: String,
    /// 1-based column of the first character of the value.
    col: usize,
}

enum Frame {
    Doc { meta: Meta, seen: [bool; 3] },
    Quote(Vec<Block>),
    Group(GroupAttrs, Vec<Block>),
    List { ordered: bool, start: i64, items: Vec<ListItem> },
    Item { text: Vec<Inline>, blocks: Vec<Block> },
    Table { cols: usize, aligns: Vec<Align>, elems: Vec<TableElem> },
    Pre(Vec<String>),
    Fig { height: i64, width: Option<i64>, caption: SrcText },
}

#[derive(PartialEq, Eq)]
enum PendKind {
    Para,
    ItemText,
}

struct Pending {
    kind: PendKind,
    src: SrcText,
}

#[derive(Default)]
struct Parser {
    stack: Vec<Frame>,
    root: Vec<Block>,
    pending: Option<Pending>,
    meta: Meta,
    toc: Option<TocSpec>,
    doc_seen: bool,
    top_count: usize,
    footnotes: usize,
}

fn is_space(c: char) -> bool {
    c == ' '
}

fn first_non_space(line: &[char]) -> usize {
    line.iter().position(|&c| !is_space(c)).unwrap_or(line.len())
}

fn bare_char(c: char) -> bool {
    c.is_ascii_alphanumeric() || matches!(c, '.' | '+' | '-' | '%')
}

fn doc_err(line: usize, col: usize, code: Code) -> Error {
    Error::document(line, col, code)
}

impl Parser {
    fn line(&mut self, line: &[char], ln: usize) -> Result<(), Error> {
        if let Some(Frame::Pre(lines)) = self.stack.last_mut() {
            let s: String = line.iter().collect();
            if s.trim_matches(' ') == "@end" {
                let Some(Frame::Pre(lines)) = self.stack.pop() else { unreachable!() };
                self.push_block(Block::Pre(lines));
            } else {
                lines.push(s.trim_end_matches(' ').to_string());
            }
            return Ok(());
        }
        let p = first_non_space(line);
        if p == line.len() {
            self.flush()?;
            return Ok(());
        }
        if line[p] == '@' {
            self.flush()?;
            self.directive(line, ln, p)
        } else {
            self.text_line(line, ln, p)
        }
    }

    fn finish(mut self, nlines: usize) -> Result<Document, Error> {
        self.flush()?;
        if !self.stack.is_empty() {
            return Err(doc_err(nlines + 1, 1, Code::MissingEnd));
        }
        Ok(Document { meta: self.meta, toc: self.toc, blocks: self.root })
    }

    fn scan(&mut self, src: &SrcText, notes: bool) -> Result<Vec<Inline>, Error> {
        parse_inline(src, notes, &mut self.footnotes)
    }

    /// Scans and stores the pending paragraph or item text, if any.
    fn flush(&mut self) -> Result<(), Error> {
        let Some(p) = self.pending.take() else { return Ok(()) };
        let inl = self.scan(&p.src, true)?;
        match p.kind {
            PendKind::Para => self.push_block(Block::Paragraph(inl)),
            PendKind::ItemText => {
                if let Some(Frame::Item { text, .. }) = self.stack.last_mut() {
                    *text = inl;
                }
            }
        }
        Ok(())
    }

    fn push_block(&mut self, b: Block) {
        match self.stack.last_mut() {
            Some(Frame::Quote(v)) | Some(Frame::Group(_, v)) | Some(Frame::Item { blocks: v, .. }) => v.push(b),
            None => self.root.push(b),
            Some(_) => unreachable!("placement rules forbid blocks here"),
        }
    }

    /// Notes that a block is starting at the top level.
    fn start_block(&mut self) {
        if self.stack.is_empty() {
            self.top_count += 1;
        }
    }

    fn text_line(&mut self, line: &[char], ln: usize, p: usize) -> Result<(), Error> {
        match self.stack.last_mut() {
            Some(Frame::Doc { meta, seen }) => {
                let (k, v) = split_assignment(line).ok_or_else(|| doc_err(ln, p + 1, Code::BadSyntax))?;
                let key: String = line[k.0..k.1].iter().collect();
                let idx = match key.as_str() {
                    "title" => 0,
                    "author" => 1,
                    "date" => 2,
                    _ => return Err(doc_err(ln, k.0 + 1, Code::UnknownMeta)),
                };
                if seen[idx] {
                    return Err(doc_err(ln, k.0 + 1, Code::DuplicateMeta));
                }
                seen[idx] = true;
                let value: String = line[v.0..v.1].iter().collect();
                match idx {
                    0 => meta.title = value,
                    1 => meta.author = value,
                    _ => meta.date = value,
                }
                Ok(())
            }
            Some(Frame::Table { cols, .. }) => {
                let cols = *cols;
                let cells = split_row(line, ln, cols)?;
                let mut parsed = Vec::new();
                for c in &cells {
                    parsed.push(parse_inline(c, false, &mut self.footnotes)?);
                }
                if let Some(Frame::Table { elems, .. }) = self.stack.last_mut() {
                    elems.push(TableElem::Row(parsed));
                }
                Ok(())
            }
            Some(Frame::List { .. }) => Err(doc_err(ln, p + 1, Code::TextNotAllowed)),
            Some(Frame::Fig { caption, .. }) => {
                if !caption.is_empty() {
                    caption.push_joiner();
                }
                caption.push_chars(&line[p..], ln, p + 1);
                Ok(())
            }
            _ => {
                if let Some(pend) = &mut self.pending {
                    pend.src.push_joiner();
                    pend.src.push_chars(&line[p..], ln, p + 1);
                } else {
                    let mut src = SrcText::new();
                    src.push_chars(&line[p..], ln, p + 1);
                    self.start_block();
                    self.pending = Some(Pending { kind: PendKind::Para, src });
                }
                Ok(())
            }
        }
    }

    fn parse_attrs(&self, line: &[char], ln: usize, mut i: usize, allowed: &[&str]) -> Result<Vec<Attr>, Error> {
        let n = line.len();
        let mut out: Vec<Attr> = Vec::new();
        loop {
            while i < n && is_space(line[i]) {
                i += 1;
            }
            if i >= n {
                return Ok(out);
            }
            let ts = i;
            while i < n && (line[i].is_ascii_alphanumeric() || line[i] == '-') {
                i += 1;
            }
            if i == ts || i >= n || line[i] != '=' {
                return Err(doc_err(ln, ts + 1, Code::BadAttribute));
            }
            let name: String = line[ts..i].iter().collect();
            if !allowed.contains(&name.as_str()) || out.iter().any(|a| a.name == name) {
                return Err(doc_err(ln, ts + 1, Code::BadAttribute));
            }
            i += 1;
            let vs = i;
            let value: String;
            if i < n && line[i] == '"' {
                let Some(rel) = line[i + 1..].iter().position(|&c| c == '"') else {
                    return Err(doc_err(ln, vs + 1, Code::BadAttributeValue));
                };
                value = line[i + 1..i + 1 + rel].iter().collect();
                i = i + 1 + rel + 1;
            } else {
                while i < n && bare_char(line[i]) {
                    i += 1;
                }
                if i == vs {
                    return Err(doc_err(ln, vs + 1, Code::BadAttributeValue));
                }
                value = line[vs..i].iter().collect();
            }
            if i < n && !is_space(line[i]) {
                return Err(doc_err(ln, vs + 1, Code::BadAttributeValue));
            }
            out.push(Attr { name, value, col: vs + 1 });
        }
    }

    fn placement(&self, dir: Dir, ln: usize, col: usize) -> Result<(), Error> {
        let bna = || doc_err(ln, col, Code::BlockNotAllowed);
        if dir == Dir::End {
            return if self.stack.is_empty() { Err(doc_err(ln, col, Code::UnexpectedEnd)) } else { Ok(()) };
        }
        let top = self.stack.last();
        match top {
            Some(Frame::Doc { .. }) | Some(Frame::Fig { .. }) => Err(bna()),
            Some(Frame::Table { .. }) => {
                if dir == Dir::HRule {
                    Ok(())
                } else {
                    Err(bna())
                }
            }
            Some(Frame::List { .. }) => {
                if dir == Dir::Li {
                    Ok(())
                } else {
                    Err(bna())
                }
            }
            _ => match dir {
                Dir::Li => {
                    if matches!(top, Some(Frame::Item { .. })) {
                        Ok(())
                    } else {
                        Err(bna())
                    }
                }
                Dir::HRule => Err(bna()),
                Dir::Doc => {
                    if top.is_none() && self.top_count == 0 {
                        Ok(())
                    } else {
                        Err(bna())
                    }
                }
                Dir::Toc => {
                    if self.toc.is_some() {
                        Err(doc_err(ln, col, Code::DuplicateToc))
                    } else if top.is_none() && (self.top_count == 0 || (self.top_count == 1 && self.doc_seen)) {
                        Ok(())
                    } else {
                        Err(bna())
                    }
                }
                _ => Ok(()),
            },
        }
    }

    fn directive(&mut self, line: &[char], ln: usize, p: usize) -> Result<(), Error> {
        let col = p + 1;
        let mut ne = p;
        while ne < line.len() && !is_space(line[ne]) {
            ne += 1;
        }
        let name: String = line[p..ne].iter().collect();
        let dir = Dir::lookup(&name).ok_or_else(|| doc_err(ln, col, Code::UnknownBlock))?;

        // Headings and list items take inline text, not attributes.
        let takes_text = matches!(dir, Dir::Heading(..) | Dir::Li);
        let attrs = if takes_text {
            Vec::new()
        } else {
            let (allowed, required) = dir.attrs();
            let attrs = self.parse_attrs(line, ln, ne, allowed)?;
            if required.iter().any(|r| !attrs.iter().any(|a| a.name == *r)) {
                return Err(doc_err(ln, col, Code::MissingAttribute));
            }
            attrs
        };
        self.placement(dir, ln, col)?;

        let get = |n: &str| attrs.iter().find(|a| a.name == n);
        let bad = |a: &Attr| doc_err(ln, a.col, Code::BadAttributeValue);
        // Step 4: values, in source order.
        let mut group = GroupAttrs::default();
        let mut start = 1i64;
        let mut cols = 0usize;
        let mut aligns: Vec<Align> = Vec::new();
        let mut height = 0i64;
        let mut width: Option<i64> = None;
        for a in &attrs {
            let v = a.value.as_str();
            match (dir, a.name.as_str()) {
                (Dir::Block, "align") => group.align = Some(Align::parse(v).ok_or_else(|| bad(a))?),
                (Dir::Block, "indent") => group.indent = Some(length_attr(v, 0).ok_or_else(|| bad(a))?),
                (Dir::Block, "right-indent") => group.right_indent = Some(length_attr(v, 0).ok_or_else(|| bad(a))?),
                (Dir::Block, "font") => group.font = Some(Family::parse(v).ok_or_else(|| bad(a))?),
                (Dir::Block, "size") => {
                    let n = length_attr(v, 1000).ok_or_else(|| bad(a))?;
                    if n > 200000 {
                        return Err(bad(a));
                    }
                    group.size = Some(n)
                }
                (Dir::Block, "leading") => group.leading = Some(length_attr(v, 1000).ok_or_else(|| bad(a))?),
                (Dir::Ol, "start") => {
                    start = parse_integer(v).filter(|n| (1..=100000).contains(n)).ok_or_else(|| bad(a))?
                }
                (Dir::Table, "cols") => {
                    cols = parse_integer(v).filter(|n| (1..=20).contains(n)).ok_or_else(|| bad(a))? as usize
                }
                (Dir::Table, "align") => {
                    for ch in v.chars() {
                        aligns.push(match ch {
                            'l' => Align::Left,
                            'r' => Align::Right,
                            'c' => Align::Center,
                            _ => return Err(bad(a)),
                        });
                    }
                }
                (Dir::Fig, "height") | (Dir::VSpace, "height") => height = length_attr(v, 0).ok_or_else(|| bad(a))?,
                (Dir::Fig, "width") => width = Some(length_attr(v, 0).ok_or_else(|| bad(a))?),
                _ => {}
            }
        }
        // Step 5.
        if dir == Dir::Table {
            match get("align") {
                Some(a) => {
                    if aligns.len() != cols {
                        return Err(bad(a));
                    }
                }
                None => aligns = vec![Align::Left; cols],
            }
        }

        match dir {
            Dir::End => self.close(ln),
            Dir::Doc => {
                self.start_block();
                self.doc_seen = true;
                self.stack.push(Frame::Doc { meta: Meta::default(), seen: [false; 3] });
                Ok(())
            }
            Dir::Toc => {
                self.start_block();
                self.toc = Some(TocSpec { title: get("title").map(|a| a.value.clone()) });
                Ok(())
            }
            Dir::Heading(level, star) => {
                self.start_block();
                let src = rest_text(line, ln, ne);
                let text = self.scan(&src, false)?;
                self.push_block(Block::Heading { level, unnumbered: star, text });
                Ok(())
            }
            Dir::Quote => {
                self.start_block();
                self.stack.push(Frame::Quote(Vec::new()));
                Ok(())
            }
            Dir::Block => {
                self.start_block();
                self.stack.push(Frame::Group(group, Vec::new()));
                Ok(())
            }
            Dir::Ul | Dir::Ol => {
                self.start_block();
                self.stack.push(Frame::List { ordered: dir == Dir::Ol, start, items: Vec::new() });
                Ok(())
            }
            Dir::Li => {
                if matches!(self.stack.last(), Some(Frame::Item { .. })) {
                    self.close_item();
                }
                self.stack.push(Frame::Item { text: Vec::new(), blocks: Vec::new() });
                let src = rest_text(line, ln, ne);
                self.pending = Some(Pending { kind: PendKind::ItemText, src });
                Ok(())
            }
            Dir::Table => {
                self.start_block();
                self.stack.push(Frame::Table { cols, aligns, elems: Vec::new() });
                Ok(())
            }
            Dir::HRule => {
                if let Some(Frame::Table { elems, .. }) = self.stack.last_mut() {
                    elems.push(TableElem::HRule);
                }
                Ok(())
            }
            Dir::Pre => {
                self.start_block();
                self.stack.push(Frame::Pre(Vec::new()));
                Ok(())
            }
            Dir::Fig => {
                self.start_block();
                self.stack.push(Frame::Fig { height, width, caption: SrcText::new() });
                Ok(())
            }
            Dir::Rule => {
                self.start_block();
                self.push_block(Block::Rule);
                Ok(())
            }
            Dir::VSpace => {
                self.start_block();
                self.push_block(Block::VSpace(height));
                Ok(())
            }
            Dir::NewPage => {
                self.start_block();
                self.push_block(Block::NewPage);
                Ok(())
            }
        }
    }

    /// Moves the open item (the top of the stack) into its list.
    fn close_item(&mut self) {
        let Some(Frame::Item { text, blocks }) = self.stack.pop() else { unreachable!() };
        if let Some(Frame::List { items, .. }) = self.stack.last_mut() {
            items.push(ListItem { text, blocks });
        }
    }

    /// Handles `@end`.
    fn close(&mut self, _ln: usize) -> Result<(), Error> {
        if matches!(self.stack.last(), Some(Frame::Item { .. })) {
            self.close_item();
        }
        match self.stack.pop().unwrap() {
            Frame::Doc { meta, .. } => self.meta = meta,
            Frame::Quote(b) => self.push_block(Block::Quote(b)),
            Frame::Group(a, b) => self.push_block(Block::Group(a, b)),
            Frame::List { ordered, start, items } => self.push_block(Block::List { ordered, start, items }),
            Frame::Table { cols, aligns, elems } => self.push_block(Block::Table { cols, aligns, elems }),
            Frame::Fig { height, width, caption } => {
                let caption = self.scan(&caption, false)?;
                self.push_block(Block::Figure { height, width, caption });
            }
            Frame::Item { .. } | Frame::Pre(_) => unreachable!(),
        }
        Ok(())
    }
}

fn length_attr(v: &str, min: i64) -> Option<i64> {
    parse_length(v).filter(|&n| n >= min)
}

/// The inline text after a directive name: leading spaces skipped.
fn rest_text(line: &[char], ln: usize, name_end: usize) -> SrcText {
    let mut i = name_end;
    while i < line.len() && is_space(line[i]) {
        i += 1;
    }
    let mut s = SrcText::new();
    s.push_chars(&line[i..], ln, i + 1);
    s
}

/// Splits `[ \t]* KEY [ \t]* = VALUE` into key range and trimmed value range.
fn split_assignment(line: &[char]) -> Option<((usize, usize), (usize, usize))> {
    let ws = |c: char| c == ' ' || c == '\t';
    let n = line.len();
    let mut p = 0;
    while p < n && ws(line[p]) {
        p += 1;
    }
    let mut k = p;
    while k < n && (line[k].is_ascii_lowercase() || line[k].is_ascii_digit() || line[k] == '-') {
        k += 1;
    }
    let mut q = k;
    while q < n && ws(line[q]) {
        q += 1;
    }
    if k == p || q >= n || line[q] != '=' {
        return None;
    }
    let mut v0 = q + 1;
    while v0 < n && ws(line[v0]) {
        v0 += 1;
    }
    let mut v1 = n;
    while v1 > v0 && ws(line[v1 - 1]) {
        v1 -= 1;
    }
    Some(((p, k), (v0, v1)))
}

/// Splits a table row into cell texts, checking the cell count.
fn split_row(line: &[char], ln: usize, cols: usize) -> Result<Vec<SrcText>, Error> {
    let mut cells: Vec<(usize, usize)> = Vec::new();
    let mut start = 0;
    let mut i = 0;
    while i < line.len() {
        match line[i] {
            '\\' => i += 2,
            '|' => {
                cells.push((start, i));
                i += 1;
                start = i;
            }
            _ => i += 1,
        }
    }
    cells.push((start, line.len()));
    if cells.len() != cols {
        return Err(doc_err(ln, 1, Code::CellCount));
    }
    Ok(cells
        .into_iter()
        .map(|(a, b)| {
            let mut s = SrcText::new();
            s.push_chars(&line[a..b], ln, a + 1);
            s
        })
        .collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn err(text: &str) -> String {
        match parse_document(text) {
            Ok(_) => "ok".into(),
            Err(e) => format!("{}:{}:{}", e.line, e.col, e.code.as_str()),
        }
    }

    #[test]
    fn paragraph_and_heading() {
        let d = parse_document("@h1 Title\ntext one\ncontinued\n\nnext\n").unwrap();
        assert_eq!(d.blocks.len(), 3);
        assert!(matches!(d.blocks[0], Block::Heading { level: 1, unnumbered: false, .. }));
    }

    #[test]
    fn doc_meta() {
        let d = parse_document("@doc\ntitle = T\n author=A b \n@end\n@toc\n").unwrap();
        assert_eq!(d.meta.title, "T");
        assert_eq!(d.meta.author, "A b");
        assert!(d.toc.is_some());
        assert_eq!(err("@doc\nfoo = 1\n@end\n"), "2:1:unknown-meta");
        assert_eq!(err("@doc\ntitle = 1\ntitle = 2\n@end\n"), "3:1:duplicate-meta");
        assert_eq!(err("@doc\nnonsense\n@end\n"), "2:1:bad-syntax");
    }

    #[test]
    fn directive_errors() {
        assert_eq!(err("@bogus\n"), "1:1:unknown-block");
        assert_eq!(err("@h1x a\n"), "1:1:unknown-block");
        assert_eq!(err("@end\n"), "1:1:unexpected-end");
        assert_eq!(err("@end foo=1\n"), "1:6:bad-attribute");
        assert_eq!(err("@q\n"), "2:1:missing-end");
        assert_eq!(err("@table align=xyz\n"), "1:1:missing-attribute");
        assert_eq!(err("@table cols=0 foo=1\n"), "1:15:bad-attribute");
        assert_eq!(err("@table cols=2\n@vspace height=abc\n@end\n"), "2:1:block-not-allowed");
        assert_eq!(err("@fig height=10pt width=\"10pt\"x\n@end\n"), "1:24:bad-attribute-value");
        assert_eq!(err("@toc\n@toc\n"), "2:1:duplicate-toc");
        assert_eq!(err("a\n@toc\n"), "2:1:block-not-allowed");
        assert_eq!(err("@li x\n"), "1:1:block-not-allowed");
        assert_eq!(err("@ul\nstray\n@end\n"), "2:1:text-not-allowed");
        assert_eq!(err("@table cols=2\na | b | c\n@end\n"), "2:1:cell-count");
    }

    #[test]
    fn inline_errors_come_before_the_line_that_ends_the_text() {
        assert_eq!(err("a {z|b}\n@bogus\n"), "1:3:unknown-inline");
        assert_eq!(err("a {b|b\n"), "1:3:unclosed-inline");
    }

    #[test]
    fn lists_and_items() {
        let d = parse_document("@ul\n@li a\ncont\n@q\nin\n@end\n@li b\n@end\n").unwrap();
        let Block::List { items, .. } = &d.blocks[0] else { panic!() };
        assert_eq!(items.len(), 2);
        assert_eq!(items[0].blocks.len(), 1);
        assert_eq!(err("@ul\n@li a\n@q\n@li b\n@end\n@end\n@end\n"), "4:1:block-not-allowed");
    }

    #[test]
    fn pre_is_verbatim() {
        let d = parse_document("@pre\n  a  \n\n @end\n").unwrap();
        let Block::Pre(l) = &d.blocks[0] else { panic!() };
        assert_eq!(l, &vec!["  a".to_string(), "".to_string()]);
    }
}
