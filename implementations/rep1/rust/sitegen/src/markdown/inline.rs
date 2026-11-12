//! Phase 2 of the Markdown conversion: inline content.
//!
//! The content of a paragraph or heading is parsed left to right into a tree
//! of inline nodes, using a delimiter stack for emphasis and a bracket stack
//! for links and images. Nodes live in an arena and are linked with
//! `parent` / `first` / `last` / `prev` / `next` indices, so that moving,
//! removing and wrapping nodes costs O(1) per node touched.

use super::block::unescape_backslashes;

pub(crate) const NONE: usize = usize::MAX;
pub(crate) const ROOT: usize = 0;

#[derive(Debug)]
pub(crate) enum INodeKind {
    Root,
    Text(String),
    SoftBreak,
    LineBreak,
    Code(String),
    Emph,
    Strong,
    Link { dest: String, title: Option<String> },
    Image { dest: String, title: Option<String> },
}

#[derive(Debug)]
pub(crate) struct INode {
    pub kind: INodeKind,
    pub parent: usize,
    pub first: usize,
    pub last: usize,
    pub prev: usize,
    pub next: usize,
}

struct Delim {
    ch: u8,
    orig_len: usize,
    can_open: bool,
    can_close: bool,
    node: usize,
    position: usize,
    prev: usize,
    next: usize,
}

struct Bracket {
    image: bool,
    node: usize,
    position: usize,
}

/// Parse `content` (the raw text of a paragraph or heading) into inline nodes.
pub(crate) fn parse(content: &str) -> Vec<INode> {
    let mut p = InlineParser {
        s: content,
        b: content.as_bytes(),
        pos: 0,
        nodes: vec![INode {
            kind: INodeKind::Root,
            parent: NONE,
            first: NONE,
            last: NONE,
            prev: NONE,
            next: NONE,
        }],
        delims: Vec::new(),
        d_tail: NONE,
        brackets: Vec::new(),
        link_closed: true,
        bt_last: Vec::new(),
        bt_scanned: false,
    };
    p.run();
    p.process_emphasis(0);
    p.nodes
}

struct InlineParser<'a> {
    s: &'a str,
    b: &'a [u8],
    pos: usize,
    nodes: Vec<INode>,
    delims: Vec<Delim>,
    d_tail: usize,
    brackets: Vec<Bracket>,
    link_closed: bool,
    bt_last: Vec<usize>,
    bt_scanned: bool,
}

fn is_ws(c: u8) -> bool {
    matches!(c, b' ' | b'\t' | b'\n' | b'\x0b' | b'\x0c' | b'\r')
}

fn is_special(c: u8) -> bool {
    matches!(
        c,
        b'\n' | b'`' | b'\\' | b'&' | b'<' | b'*' | b'_' | b'[' | b']' | b'!'
    )
}

impl<'a> InlineParser<'a> {
    fn peek(&self, i: usize) -> u8 {
        if i < self.b.len() {
            self.b[i]
        } else {
            0
        }
    }

    fn new_node(&mut self, kind: INodeKind) -> usize {
        self.nodes.push(INode {
            kind,
            parent: NONE,
            first: NONE,
            last: NONE,
            prev: NONE,
            next: NONE,
        });
        self.nodes.len() - 1
    }

    /// Append a new node at the end of the root's child list.
    fn append(&mut self, kind: INodeKind) -> usize {
        let id = self.new_node(kind);
        self.append_existing(id);
        id
    }

    fn append_existing(&mut self, id: usize) {
        let last = self.nodes[ROOT].last;
        self.nodes[id].parent = ROOT;
        self.nodes[id].prev = last;
        self.nodes[id].next = NONE;
        if last == NONE {
            self.nodes[ROOT].first = id;
        } else {
            self.nodes[last].next = id;
        }
        self.nodes[ROOT].last = id;
    }

    fn append_text(&mut self, s: &str) -> usize {
        self.append(INodeKind::Text(s.to_string()))
    }

    fn unlink(&mut self, id: usize) {
        let (parent, prev, next) = (
            self.nodes[id].parent,
            self.nodes[id].prev,
            self.nodes[id].next,
        );
        if prev == NONE {
            self.nodes[parent].first = next;
        } else {
            self.nodes[prev].next = next;
        }
        if next == NONE {
            self.nodes[parent].last = prev;
        } else {
            self.nodes[next].prev = prev;
        }
        self.nodes[id].parent = NONE;
        self.nodes[id].prev = NONE;
        self.nodes[id].next = NONE;
    }

    fn run(&mut self) {
        while self.pos < self.b.len() {
            let c = self.b[self.pos];
            match c {
                b'\n' => self.handle_newline(),
                b'`' => self.handle_backticks(),
                b'\\' => self.handle_backslash(),
                b'&' => self.handle_entity(),
                b'<' => self.handle_lt(),
                b'*' | b'_' => self.handle_delim_run(c),
                b'[' => {
                    let node = self.append_text("[");
                    self.pos += 1;
                    self.brackets.push(Bracket {
                        image: false,
                        node,
                        position: self.pos,
                    });
                    self.link_closed = false;
                }
                b'!' => {
                    if self.peek(self.pos + 1) == b'[' {
                        let node = self.append_text("![");
                        self.pos += 2;
                        self.brackets.push(Bracket {
                            image: true,
                            node,
                            position: self.pos,
                        });
                    } else {
                        self.append_text("!");
                        self.pos += 1;
                    }
                }
                b']' => self.handle_close_bracket(),
                _ => self.handle_text(),
            }
        }
    }

    fn handle_text(&mut self) {
        let start = self.pos;
        let mut end = start + 1;
        while end < self.b.len() && !is_special(self.b[end]) {
            end += 1;
        }
        let mut text_end = end;
        if end < self.b.len() && self.b[end] == b'\n' {
            while text_end > start && is_ws(self.b[text_end - 1]) {
                text_end -= 1;
            }
        }
        if text_end > start {
            let t = &self.s[start..text_end];
            self.append_text(t);
        }
        self.pos = end;
    }

    fn handle_newline(&mut self) {
        let p = self.pos;
        let hard = p >= 2 && self.b[p - 1] == b' ' && self.b[p - 2] == b' ';
        self.append(if hard {
            INodeKind::LineBreak
        } else {
            INodeKind::SoftBreak
        });
        self.pos += 1;
        while self.pos < self.b.len() && (self.b[self.pos] == b' ' || self.b[self.pos] == b'\t') {
            self.pos += 1;
        }
    }

    fn handle_backslash(&mut self) {
        let next = self.peek(self.pos + 1);
        if self.pos + 1 < self.b.len() && next.is_ascii_punctuation() {
            let t = &self.s[self.pos + 1..self.pos + 2];
            self.append_text(t);
            self.pos += 2;
        } else if self.pos + 1 < self.b.len() && next == b'\n' {
            self.append(INodeKind::LineBreak);
            self.pos += 2;
        } else {
            self.append_text("\\");
            self.pos += 1;
        }
    }

    fn handle_entity(&mut self) {
        if let Some((ch, len)) = match_entity(self.b, self.pos + 1) {
            let mut buf = [0u8; 4];
            let t = ch.encode_utf8(&mut buf);
            self.append_text(t);
            self.pos += 1 + len;
        } else {
            self.append_text("&");
            self.pos += 1;
        }
    }

    // ---- code spans -----------------------------------------------------

    fn handle_backticks(&mut self) {
        let start = self.pos;
        let mut p = start;
        while p < self.b.len() && self.b[p] == b'`' {
            p += 1;
        }
        let n = p - start;
        match self.find_closing_backticks(p, n) {
            Some(close_start) => {
                let raw = &self.s[p..close_start];
                let mut content: String = raw.replace('\n', " ");
                let bytes = content.as_bytes();
                if bytes.len() >= 2
                    && bytes[0] == b' '
                    && bytes[bytes.len() - 1] == b' '
                    && bytes.iter().any(|&c| c != b' ')
                {
                    content = content[1..content.len() - 1].to_string();
                }
                self.append(INodeKind::Code(content));
                self.pos = close_start + n;
            }
            None => {
                let t = &self.s[start..p];
                self.append_text(t);
                self.pos = p;
            }
        }
    }

    /// Find the start of the next backtick run of exactly `n` backticks at or
    /// after `p`, using cmark's memo of the last position seen per run length.
    fn find_closing_backticks(&mut self, p: usize, n: usize) -> Option<usize> {
        if self.bt_last.len() <= n {
            self.bt_last.resize(n + 1, 0);
        }
        if self.bt_scanned && self.bt_last[n] <= p {
            return None;
        }
        let mut i = p;
        while i < self.b.len() {
            if self.b[i] == b'`' {
                let s = i;
                while i < self.b.len() && self.b[i] == b'`' {
                    i += 1;
                }
                let k = i - s;
                if self.bt_last.len() <= k {
                    self.bt_last.resize(k + 1, 0);
                }
                self.bt_last[k] = s;
                if k == n {
                    return Some(s);
                }
            } else {
                i += 1;
            }
        }
        self.bt_scanned = true;
        None
    }

    // ---- autolinks ------------------------------------------------------

    fn handle_lt(&mut self) {
        let start = self.pos + 1;
        if let Some(end) = scan_uri_autolink(self.b, start) {
            let raw = &self.s[start..end];
            self.emit_autolink(raw, false);
            self.pos = end + 1;
        } else if let Some(end) = scan_email_autolink(self.b, start) {
            let raw = &self.s[start..end];
            self.emit_autolink(raw, true);
            self.pos = end + 1;
        } else {
            self.append_text("<");
            self.pos += 1;
        }
    }

    fn emit_autolink(&mut self, raw: &str, email: bool) {
        let text = decode_entities(raw);
        let dest = if email {
            format!("mailto:{}", text)
        } else {
            text.clone()
        };
        let link = self.append(INodeKind::Link { dest, title: None });
        let child = self.new_node(INodeKind::Text(text));
        self.nodes[child].parent = link;
        self.nodes[link].first = child;
        self.nodes[link].last = child;
    }

    // ---- emphasis -------------------------------------------------------

    fn handle_delim_run(&mut self, c: u8) {
        let start = self.pos;
        let mut end = start;
        while end < self.b.len() && self.b[end] == c {
            end += 1;
        }
        let n = end - start;
        let before = if start == 0 { b'\n' } else { self.b[start - 1] };
        let after = if end >= self.b.len() {
            b'\n'
        } else {
            self.b[end]
        };
        let before_ws = is_ws(before);
        let after_ws = is_ws(after);
        let before_punct = before.is_ascii_punctuation();
        let after_punct = after.is_ascii_punctuation();
        let left = !after_ws && (!after_punct || before_ws || before_punct);
        let right = !before_ws && (!before_punct || after_ws || after_punct);
        let (can_open, can_close) = if c == b'*' {
            (left, right)
        } else {
            (
                left && (!right || before_punct),
                right && (!left || after_punct),
            )
        };
        let t = &self.s[start..end];
        let node = self.append_text(t);
        self.pos = end;
        if can_open || can_close {
            let id = self.delims.len();
            self.delims.push(Delim {
                ch: c,
                orig_len: n,
                can_open,
                can_close,
                node,
                position: end,
                prev: self.d_tail,
                next: NONE,
            });
            if self.d_tail != NONE {
                let tail = self.d_tail;
                self.delims[tail].next = id;
            }
            self.d_tail = id;
        }
    }

    fn unlink_delim(&mut self, id: usize) {
        let (prev, next) = (self.delims[id].prev, self.delims[id].next);
        if prev != NONE {
            self.delims[prev].next = next;
        }
        if next != NONE {
            self.delims[next].prev = prev;
        } else {
            self.d_tail = prev;
        }
    }

    fn text_len(&self, node: usize) -> usize {
        match &self.nodes[node].kind {
            INodeKind::Text(t) => t.len(),
            _ => 0,
        }
    }

    fn process_emphasis(&mut self, stack_bottom: usize) {
        let mut openers_bottom = [stack_bottom; 12];
        // First entry with position >= stack_bottom.
        let mut closer = NONE;
        let mut e = self.d_tail;
        while e != NONE && self.delims[e].position >= stack_bottom {
            closer = e;
            e = self.delims[e].prev;
        }
        while closer != NONE {
            if !self.delims[closer].can_close {
                closer = self.delims[closer].next;
                continue;
            }
            let (cch, clen, c_open) = {
                let d = &self.delims[closer];
                (d.ch, d.orig_len, d.can_open)
            };
            let kind = (if cch == b'*' { 0 } else { 6 }) + (if c_open { 3 } else { 0 }) + clen % 3;
            let mut opener = self.delims[closer].prev;
            let mut found = NONE;
            while opener != NONE && self.delims[opener].position >= openers_bottom[kind] {
                let o = &self.delims[opener];
                if o.can_open && o.ch == cch {
                    let odd = (c_open || o.can_close)
                        && clen % 3 != 0
                        && (o.orig_len + clen).is_multiple_of(3);
                    if !odd {
                        found = opener;
                        break;
                    }
                }
                opener = o.prev;
            }
            if found != NONE {
                let opener = found;
                let onode = self.delims[opener].node;
                let cnode = self.delims[closer].node;
                let use_n = if self.text_len(onode) >= 2 && self.text_len(cnode) >= 2 {
                    2
                } else {
                    1
                };
                if let INodeKind::Text(t) = &mut self.nodes[onode].kind {
                    let l = t.len();
                    t.truncate(l - use_n);
                }
                if let INodeKind::Text(t) = &mut self.nodes[cnode].kind {
                    t.drain(..use_n);
                }
                // Remove the delimiters strictly between opener and closer.
                self.delims[opener].next = closer;
                self.delims[closer].prev = opener;
                // Wrap the nodes between the two text nodes.
                self.wrap(
                    onode,
                    cnode,
                    if use_n == 2 {
                        INodeKind::Strong
                    } else {
                        INodeKind::Emph
                    },
                );
                if self.text_len(onode) == 0 {
                    self.unlink(onode);
                    self.unlink_delim(opener);
                }
                if self.text_len(cnode) == 0 {
                    self.unlink(cnode);
                    let next = self.delims[closer].next;
                    self.unlink_delim(closer);
                    closer = next;
                }
            } else {
                openers_bottom[kind] = self.delims[closer].position;
                let next = self.delims[closer].next;
                if !self.delims[closer].can_open {
                    self.unlink_delim(closer);
                }
                closer = next;
            }
        }
        // Remove all entries with position >= stack_bottom.
        let mut e = self.d_tail;
        while e != NONE && self.delims[e].position >= stack_bottom {
            e = self.delims[e].prev;
        }
        self.d_tail = e;
        if e != NONE {
            self.delims[e].next = NONE;
        }
    }

    /// Insert a new container node between `open` and `close` (siblings),
    /// moving everything between them into it.
    fn wrap(&mut self, open: usize, close: usize, kind: INodeKind) {
        let e = self.new_node(kind);
        let first = self.nodes[open].next;
        let parent = self.nodes[open].parent;
        if first != close {
            let last = self.nodes[close].prev;
            let mut n = first;
            loop {
                self.nodes[n].parent = e;
                if n == last {
                    break;
                }
                n = self.nodes[n].next;
            }
            self.nodes[e].first = first;
            self.nodes[e].last = last;
            self.nodes[first].prev = NONE;
            self.nodes[last].next = NONE;
        }
        self.nodes[e].parent = parent;
        self.nodes[e].prev = open;
        self.nodes[e].next = close;
        self.nodes[open].next = e;
        self.nodes[close].prev = e;
    }

    // ---- links and images -----------------------------------------------

    fn handle_close_bracket(&mut self) {
        let close_pos = self.pos;
        self.pos += 1;
        let Some(top) = self.brackets.last() else {
            self.append_text("]");
            return;
        };
        let (image, opener_node, opener_pos) = (top.image, top.node, top.position);
        if !image && self.link_closed {
            self.brackets.pop();
            self.append_text("]");
            return;
        }
        match self.parse_inline_link(close_pos + 1) {
            Some((dest, title, end)) => {
                let kind = if image {
                    INodeKind::Image { dest, title }
                } else {
                    INodeKind::Link { dest, title }
                };
                let link = self.new_node(kind);
                // Move the nodes after the opener into the link.
                let first = self.nodes[opener_node].next;
                if first != NONE {
                    let last = self.nodes[ROOT].last;
                    let mut n = first;
                    loop {
                        self.nodes[n].parent = link;
                        if n == last {
                            break;
                        }
                        n = self.nodes[n].next;
                    }
                    self.nodes[link].first = first;
                    self.nodes[link].last = last;
                    self.nodes[first].prev = NONE;
                    // Detach the range from the root list.
                    self.nodes[opener_node].next = NONE;
                    self.nodes[ROOT].last = opener_node;
                }
                self.unlink(opener_node);
                self.append_existing(link);
                self.process_emphasis(opener_pos);
                self.brackets.pop();
                if !image {
                    self.link_closed = true;
                }
                self.pos = end;
            }
            None => {
                self.brackets.pop();
                self.append_text("]");
            }
        }
    }

    fn skip_ws(&self, mut i: usize) -> usize {
        while i < self.b.len() && is_ws(self.b[i]) {
            i += 1;
        }
        i
    }

    /// Parse `(destination "title")` starting right after a `]` at `pos`.
    /// Returns the cleaned destination, the cleaned title and the position
    /// after the closing parenthesis.
    fn parse_inline_link(&self, pos: usize) -> Option<(String, Option<String>, usize)> {
        if self.peek(pos) != b'(' || pos >= self.b.len() {
            return None;
        }
        let start_url = self.skip_ws(pos + 1);
        let (url_start, url_end, after_url) = self.scan_destination(start_url)?;
        let start_title = self.skip_ws(after_url);
        let mut end_title = start_title;
        let mut title: Option<(usize, usize)> = None;
        if start_title != after_url {
            if let Some(e) = self.scan_title(start_title) {
                title = Some((start_title + 1, e));
                end_title = e + 1;
            }
        }
        let end_all = self.skip_ws(end_title);
        if self.peek(end_all) != b')' || end_all >= self.b.len() {
            return None;
        }
        let raw_dest = self.s[url_start..url_end]
            .trim_matches(|c: char| matches!(c, ' ' | '\t' | '\n' | '\x0b' | '\x0c' | '\r'));
        let dest = unescape_backslashes(&decode_entities(raw_dest));
        let title = title.map(|(s, e)| unescape_backslashes(&decode_entities(&self.s[s..e])));
        Some((dest, title, end_all + 1))
    }

    /// Returns (start, end) of the destination text and the position after it.
    fn scan_destination(&self, start: usize) -> Option<(usize, usize, usize)> {
        let b = self.b;
        let len = b.len();
        let mut i = start;
        if i < len && b[i] == b'<' {
            i += 1;
            while i < len {
                match b[i] {
                    b'>' => {
                        i += 1;
                        break;
                    }
                    b'\\' => i += 2,
                    b'\n' | b'<' => return None,
                    _ => i += 1,
                }
            }
            if i >= len {
                return None;
            }
            Some((start + 1, i - 1, i))
        } else {
            let mut depth = 0usize;
            while i < len {
                let c = b[i];
                if c == b'\\' && i + 1 < len && b[i + 1].is_ascii_punctuation() {
                    i += 2;
                } else if c == b'(' {
                    depth += 1;
                    i += 1;
                    if depth > 32 {
                        return None;
                    }
                } else if c == b')' {
                    if depth == 0 {
                        break;
                    }
                    depth -= 1;
                    i += 1;
                } else if is_ws(c) {
                    break;
                } else {
                    i += 1;
                }
            }
            if i >= len || depth != 0 {
                return None;
            }
            Some((start, i, i))
        }
    }

    /// Scan a link title starting at an opening delimiter. Returns the index
    /// of the closing delimiter of the longest valid title.
    fn scan_title(&self, start: usize) -> Option<usize> {
        let b = self.b;
        let (close, paren) = match b.get(start)? {
            b'"' => (b'"', false),
            b'\'' => (b'\'', false),
            b'(' => (b')', true),
            _ => return None,
        };
        let mut last = None;
        let mut i = start + 1;
        while i < b.len() {
            let c = b[i];
            let escaped = b[i - 1] == b'\\' && i - 1 > start;
            if c == close {
                last = Some(i);
                if !escaped {
                    return last;
                }
            } else if paren && c == b'(' && !escaped {
                return last;
            }
            i += 1;
        }
        last
    }
}

// ---- shared scanners ---------------------------------------------------------

/// Match an entity reference whose text starts right after the `&` at `i`.
/// Returns the decoded character and the number of bytes consumed after `&`.
pub(crate) fn match_entity(b: &[u8], i: usize) -> Option<(char, usize)> {
    let rest = b.get(i..)?;
    if rest.first() == Some(&b'#') {
        let (hex, digits_start) = if matches!(rest.get(1), Some(b'x') | Some(b'X')) {
            (true, 2)
        } else {
            (false, 1)
        };
        let mut j = digits_start;
        let mut value: u32 = 0;
        while j < rest.len() {
            let d = if hex {
                (rest[j] as char).to_digit(16)
            } else {
                (rest[j] as char).to_digit(10)
            };
            match d {
                Some(d) => {
                    value = value
                        .saturating_mul(if hex { 16 } else { 10 })
                        .saturating_add(d);
                    j += 1;
                }
                None => break,
            }
        }
        let ndigits = j - digits_start;
        let max = if hex { 6 } else { 7 };
        if ndigits == 0 || ndigits > max || rest.get(j) != Some(&b';') {
            return None;
        }
        let ch = if value == 0 || (0xD800..=0xDFFF).contains(&value) || value > 0x10FFFF {
            '\u{FFFD}'
        } else {
            char::from_u32(value).unwrap_or('\u{FFFD}')
        };
        Some((ch, j + 1))
    } else {
        for (name, ch) in [("amp;", '&'), ("lt;", '<'), ("gt;", '>'), ("quot;", '"')] {
            if rest.starts_with(name.as_bytes()) {
                return Some((ch, name.len()));
            }
        }
        None
    }
}

/// Replace entity references in `s` with the characters they denote.
pub(crate) fn decode_entities(s: &str) -> String {
    if !s.contains('&') {
        return s.to_string();
    }
    let b = s.as_bytes();
    let mut out = String::with_capacity(s.len());
    let mut i = 0;
    let mut run = 0;
    while i < b.len() {
        if b[i] == b'&' {
            if let Some((ch, len)) = match_entity(b, i + 1) {
                out.push_str(&s[run..i]);
                out.push(ch);
                i += 1 + len;
                run = i;
                continue;
            }
        }
        i += 1;
    }
    out.push_str(&s[run..]);
    out
}

/// `[A-Za-z][A-Za-z0-9.+-]{1,31}:[^\x00-\x20<>]*>` starting at `i`; returns
/// the index of the closing `>`.
fn scan_uri_autolink(b: &[u8], i: usize) -> Option<usize> {
    let mut j = i;
    if !b.get(j)?.is_ascii_alphabetic() {
        return None;
    }
    j += 1;
    let scheme_start = j;
    while j < b.len() && (b[j].is_ascii_alphanumeric() || matches!(b[j], b'.' | b'+' | b'-')) {
        j += 1;
    }
    let n = j - scheme_start;
    if !(1..=31).contains(&n) || b.get(j) != Some(&b':') {
        return None;
    }
    j += 1;
    while j < b.len() {
        let c = b[j];
        if c == b'>' {
            return Some(j);
        }
        if c <= 0x20 || c == b'<' {
            return None;
        }
        j += 1;
    }
    None
}

fn scan_email_autolink(b: &[u8], i: usize) -> Option<usize> {
    let mut j = i;
    let local_ok = |c: u8| c.is_ascii_alphanumeric() || b".!#$%&'*+/=?^_`{|}~-".contains(&c);
    while j < b.len() && local_ok(b[j]) {
        j += 1;
    }
    if j == i || b.get(j) != Some(&b'@') {
        return None;
    }
    j += 1;
    loop {
        // One domain label: alnum, up to 61 alnum/hyphen, alnum.
        let label_start = j;
        if !b.get(j)?.is_ascii_alphanumeric() {
            return None;
        }
        while j < b.len() && (b[j].is_ascii_alphanumeric() || b[j] == b'-') {
            j += 1;
        }
        // The label must end in an alphanumeric and be at most 63 long.
        while j > label_start && b[j - 1] == b'-' {
            j -= 1;
        }
        if j - label_start > 63 {
            return None;
        }
        match b.get(j) {
            Some(b'.') => j += 1,
            Some(b'>') => return Some(j),
            _ => return None,
        }
    }
}
