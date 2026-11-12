//! Phase 2: inline parsing.
//!
//! The content of a paragraph or heading is parsed left to right into inline
//! nodes using a delimiter stack for `*`/`_` runs and a bracket stack for
//! links and images, then emphasis is resolved with the "process emphasis"
//! algorithm of the CommonMark specification (with `openers_bottom` bounds so
//! that it runs in linear time).
//!
//! Everything here is iterative, so inline nesting thousands of levels deep
//! is fine.

use crate::node::{NodeId, NodeKind, Tree};
use crate::scan;
use crate::text::{self, is_punct, is_space};

/// Bytes that end a plain-text run.
const SPECIAL: [bool; 256] = {
    let mut t = [false; 256];
    let specials = b"\n`\\&<*_[]!";
    let mut i = 0;
    while i < specials.len() {
        t[specials[i] as usize] = true;
        i += 1;
    }
    t
};

/// An entry of the delimiter stack (a run of `*` or `_`).
struct Delim {
    ch: u8,
    /// Original length of the run (used by the "rule of 3").
    length: usize,
    can_open: bool,
    can_close: bool,
    /// The text node holding the (remaining) delimiter characters.
    node: NodeId,
    /// Index just after the run in the content.
    position: usize,
    prev: Option<usize>,
    next: Option<usize>,
}

/// An entry of the bracket stack (`[` or `![`).
#[derive(Clone, Copy)]
struct Bracket {
    image: bool,
    node: NodeId,
    /// Index just after the opening bracket.
    position: usize,
}

struct InlineParser<'a> {
    tree: &'a mut Tree,
    /// The paragraph or heading whose content is being parsed.
    root: NodeId,
    text: &'a str,
    s: &'a [u8],
    pos: usize,
    delims: Vec<Delim>,
    top: Option<usize>,
    brackets: Vec<Bracket>,
    link_closed: bool,
    /// cmark's backtick memo: `bt_last[k]` is the start of the last backtick
    /// run of length `k` met while scanning.
    bt_last: Vec<usize>,
    bt_scanned: bool,
}

/// Parses `content` (the raw text of a paragraph or heading) and appends the
/// resulting inline nodes to `parent`.
pub(crate) fn parse_inlines(tree: &mut Tree, parent: NodeId, content: &str) {
    let content = text::trim_end(content);
    if content.is_empty() {
        return;
    }
    let mut p = InlineParser {
        tree,
        root: parent,
        text: content,
        s: content.as_bytes(),
        pos: 0,
        delims: Vec::new(),
        top: None,
        brackets: Vec::new(),
        link_closed: true,
        bt_last: vec![0; 128],
        bt_scanned: false,
    };
    p.run();
}

impl<'a> InlineParser<'a> {
    fn run(&mut self) {
        let len = self.s.len();
        while self.pos < len {
            match self.s[self.pos] {
                b'\n' => self.newline(),
                b'`' => self.backticks(),
                b'\\' => self.backslash(),
                b'&' => self.entity(),
                b'<' => self.autolink(),
                b'*' | b'_' => self.delimiter_run(),
                b'[' => {
                    let node = self.push_text("[");
                    self.pos += 1;
                    self.brackets.push(Bracket { image: false, node, position: self.pos });
                    self.link_closed = false;
                }
                b'!' => {
                    if self.s.get(self.pos + 1) == Some(&b'[') {
                        let node = self.push_text("![");
                        self.pos += 2;
                        self.brackets.push(Bracket { image: true, node, position: self.pos });
                    } else {
                        self.push_text("!");
                        self.pos += 1;
                    }
                }
                b']' => self.close_bracket(),
                _ => self.plain_text(),
            }
        }
        self.process_emphasis(self.root, 0);
    }

    // ---- node helpers ---------------------------------------------------

    fn push_node(&mut self, kind: NodeKind) -> NodeId {
        let id = self.tree.add(kind);
        self.tree.append_child(self.root, id);
        id
    }

    fn push_text(&mut self, s: &str) -> NodeId {
        self.push_node(NodeKind::Text(s.to_string()))
    }

    fn text_len(&self, id: NodeId) -> usize {
        match &self.tree.node(id).kind {
            NodeKind::Text(t) => t.len(),
            _ => 0,
        }
    }

    fn truncate_text(&mut self, id: NodeId, by: usize) {
        if let NodeKind::Text(t) = &mut self.tree.node_mut(id).kind {
            let n = t.len() - by;
            t.truncate(n);
        }
    }

    // ---- simple constructs ----------------------------------------------

    fn plain_text(&mut self) {
        let start = self.pos;
        let mut end = start + 1;
        while end < self.s.len() && !SPECIAL[self.s[end] as usize] {
            end += 1;
        }
        self.pos = end;
        let mut run = &self.text[start..end];
        if self.s.get(end) == Some(&b'\n') {
            run = text::trim_end(run);
        }
        if !run.is_empty() {
            self.push_text(run);
        }
    }

    fn newline(&mut self) {
        let nl = self.pos;
        self.pos += 1;
        while self.pos < self.s.len() && matches!(self.s[self.pos], b' ' | b'\t') {
            self.pos += 1;
        }
        let hard = nl >= 2 && self.s[nl - 1] == b' ' && self.s[nl - 2] == b' ';
        self.push_node(if hard { NodeKind::LineBreak } else { NodeKind::SoftBreak });
    }

    fn backslash(&mut self) {
        match self.s.get(self.pos + 1) {
            Some(&b) if is_punct(b) => {
                let t = &self.text[self.pos + 1..self.pos + 2];
                self.push_text(t);
                self.pos += 2;
            }
            Some(b'\n') => {
                self.push_node(NodeKind::LineBreak);
                self.pos += 2;
            }
            _ => {
                self.push_text("\\");
                self.pos += 1;
            }
        }
    }

    fn entity(&mut self) {
        match text::match_entity(&self.s[self.pos..]) {
            Some((ch, len)) => {
                let mut buf = [0u8; 4];
                self.push_text(ch.encode_utf8(&mut buf));
                self.pos += len;
            }
            None => {
                self.push_text("&");
                self.pos += 1;
            }
        }
    }

    fn autolink(&mut self) {
        let body = &self.s[self.pos + 1..];
        match scan::autolink(body) {
            Some(a) => {
                let raw = &self.text[self.pos + 1..self.pos + 1 + a.len];
                let decoded = text::decode_entities(raw);
                let dest = if a.email { format!("mailto:{decoded}") } else { decoded.clone() };
                let link = self.push_node(NodeKind::Link { dest, title: None });
                let child = self.tree.add(NodeKind::Text(decoded));
                self.tree.append_child(link, child);
                self.pos += a.len + 2;
            }
            None => {
                self.push_text("<");
                self.pos += 1;
            }
        }
    }

    // ---- code spans -----------------------------------------------------

    fn backticks(&mut self) {
        let start = self.pos;
        let mut p = start;
        while p < self.s.len() && self.s[p] == b'`' {
            p += 1;
        }
        let n = p - start;
        match self.find_closing_ticks(p, n) {
            Some(close) => {
                let mut code: String = self.text[p..close].replace('\n', " ");
                let b = code.as_bytes();
                if b.len() >= 2
                    && b[0] == b' '
                    && b[b.len() - 1] == b' '
                    && b.iter().any(|&c| c != b' ')
                {
                    code = code[1..code.len() - 1].to_string();
                }
                self.push_node(NodeKind::Code(code));
                self.pos = close + n;
            }
            None => {
                self.push_text(&self.text[start..p]);
                self.pos = p;
            }
        }
    }

    /// Finds a backtick run of exactly `n` after `p`, using the memo so that
    /// repeated failing searches do not rescan the content.
    fn find_closing_ticks(&mut self, p: usize, n: usize) -> Option<usize> {
        if self.bt_scanned && self.bt_last.get(n).copied().unwrap_or(0) <= p {
            return None;
        }
        let len = self.s.len();
        let mut i = p;
        loop {
            while i < len && self.s[i] != b'`' {
                i += 1;
            }
            if i >= len {
                self.bt_scanned = true;
                return None;
            }
            let run_start = i;
            while i < len && self.s[i] == b'`' {
                i += 1;
            }
            let k = i - run_start;
            if k >= self.bt_last.len() {
                self.bt_last.resize(k + 1, 0);
            }
            self.bt_last[k] = run_start;
            if k == n {
                return Some(run_start);
            }
        }
    }

    // ---- emphasis delimiters --------------------------------------------

    fn delimiter_run(&mut self) {
        let start = self.pos;
        let c = self.s[start];
        let mut end = start;
        while end < self.s.len() && self.s[end] == c {
            end += 1;
        }
        let n = end - start;
        let before = if start == 0 { b'\n' } else { self.s[start - 1] };
        let after = if end >= self.s.len() { b'\n' } else { self.s[end] };
        // Non-ASCII bytes count as ordinary (letter-like) characters.
        let (bws, aws) = (is_space(before), is_space(after));
        let (bp, ap) = (is_punct(before), is_punct(after));
        let left = !aws && (!ap || bws || bp);
        let right = !bws && (!bp || aws || ap);
        let (can_open, can_close) = if c == b'*' {
            (left, right)
        } else {
            (left && (!right || bp), right && (!left || ap))
        };
        let node = self.push_text(&self.text[start..end]);
        self.pos = end;
        if can_open || can_close {
            let idx = self.delims.len();
            self.delims.push(Delim {
                ch: c,
                length: n,
                can_open,
                can_close,
                node,
                position: end,
                prev: self.top,
                next: None,
            });
            if let Some(t) = self.top {
                self.delims[t].next = Some(idx);
            }
            self.top = Some(idx);
        }
    }

    /// Removes a delimiter entry from the stack in O(1).
    fn remove_delim(&mut self, i: usize) {
        let (prev, next) = (self.delims[i].prev, self.delims[i].next);
        if let Some(p) = prev {
            self.delims[p].next = next;
        }
        if let Some(n) = next {
            self.delims[n].prev = prev;
        }
        if self.top == Some(i) {
            self.top = prev;
        }
    }

    /// Resolves emphasis among the delimiters positioned at or after
    /// `stack_bottom`; the delimiters' text nodes are children of `parent`.
    fn process_emphasis(&mut self, parent: NodeId, stack_bottom: usize) {
        // The first entry with position >= stack_bottom.
        let mut closer = None;
        let mut cand = self.top;
        while let Some(i) = cand {
            if self.delims[i].position < stack_bottom {
                break;
            }
            closer = Some(i);
            cand = self.delims[i].prev;
        }

        let mut openers_bottom = [stack_bottom; 12];
        while let Some(ci) = closer {
            if !self.delims[ci].can_close {
                closer = self.delims[ci].next;
                continue;
            }
            let (cch, clen, c_open) = {
                let d = &self.delims[ci];
                (d.ch, d.length, d.can_open)
            };
            let kind = (if cch == b'_' { 6 } else { 0 }) + (if c_open { 3 } else { 0 }) + clen % 3;
            let mut opener = self.delims[ci].prev;
            let mut found = None;
            while let Some(oi) = opener {
                let o = &self.delims[oi];
                if o.position < openers_bottom[kind] {
                    break;
                }
                if o.can_open
                    && o.ch == cch
                    && ((!c_open && !o.can_close) || clen % 3 == 0 || (o.length + clen) % 3 != 0)
                {
                    found = Some(oi);
                    break;
                }
                opener = o.prev;
            }

            let Some(oi) = found else {
                openers_bottom[kind] = self.delims[ci].position;
                let next = self.delims[ci].next;
                if !c_open {
                    self.remove_delim(ci);
                }
                closer = next;
                continue;
            };

            let (onode, cnode) = (self.delims[oi].node, self.delims[ci].node);
            let (olen, clen_now) = (self.text_len(onode), self.text_len(cnode));
            let use_delims = if olen >= 2 && clen_now >= 2 { 2 } else { 1 };
            self.truncate_text(onode, use_delims);
            self.truncate_text(cnode, use_delims);

            // Everything between the two text nodes goes into the new node.
            let emph = self.tree.add(if use_delims == 2 { NodeKind::Strong } else { NodeKind::Emph });
            let first = self.tree.node(onode).next.filter(|&n| n != cnode);
            if let Some(first) = first {
                let last = self.tree.node(cnode).prev.expect("closer has a previous sibling");
                self.tree.node_mut(first).prev = None;
                self.tree.node_mut(last).next = None;
                let e = self.tree.node_mut(emph);
                e.first_child = Some(first);
                e.last_child = Some(last);
            }
            self.tree.node_mut(onode).next = Some(emph);
            self.tree.node_mut(emph).prev = Some(onode);
            self.tree.node_mut(emph).next = Some(cnode);
            self.tree.node_mut(cnode).prev = Some(emph);
            self.tree.node_mut(emph).parent = Some(parent);

            // Drop the delimiters between opener and closer.
            self.delims[oi].next = Some(ci);
            self.delims[ci].prev = Some(oi);

            if self.text_len(onode) == 0 {
                self.tree.unlink(parent, onode);
                self.remove_delim(oi);
            }
            if self.text_len(cnode) == 0 {
                self.tree.unlink(parent, cnode);
                let next = self.delims[ci].next;
                self.remove_delim(ci);
                closer = next;
            }
        }

        while let Some(t) = self.top {
            if self.delims[t].position >= stack_bottom {
                self.top = self.delims[t].prev;
            } else {
                break;
            }
        }
        if let Some(t) = self.top {
            self.delims[t].next = None;
        }
    }

    // ---- links and images -----------------------------------------------

    fn skip_spaces(&self, mut i: usize) -> usize {
        while i < self.s.len() && is_space(self.s[i]) {
            i += 1;
        }
        i
    }

    /// Parses `(destination "title")` starting at the `(` at `i`.
    /// Returns the raw destination, the raw title and the end position.
    fn scan_inline_link(&self, i: usize) -> Option<(&'a str, Option<&'a str>, usize)> {
        let s = self.s;
        let i = self.skip_spaces(i + 1);
        let (ds, de, after) = scan::link_destination(s, i)?;
        let mut j = self.skip_spaces(after);
        let mut title = None;
        if j > after {
            if let Some(end) = scan::link_title(s, j) {
                title = Some(&self.text[j + 1..end - 1]);
                j = end;
            }
        }
        j = self.skip_spaces(j);
        if s.get(j) == Some(&b')') {
            Some((&self.text[ds..de], title, j + 1))
        } else {
            None
        }
    }

    fn close_bracket(&mut self) {
        self.pos += 1;
        let Some(&opener) = self.brackets.last() else {
            self.push_text("]");
            return;
        };
        if !opener.image && self.link_closed {
            self.brackets.pop();
            self.push_text("]");
            return;
        }
        let Some((raw_dest, raw_title, end)) =
            (self.s.get(self.pos) == Some(&b'(')).then(|| self.scan_inline_link(self.pos)).flatten()
        else {
            self.brackets.pop();
            self.push_text("]");
            return;
        };
        let dest = text::clean_url(raw_dest);
        let title = raw_title.map(text::clean_title);
        let kind = if opener.image {
            NodeKind::Image { dest, title }
        } else {
            NodeKind::Link { dest, title }
        };
        let node = self.tree.add(kind);

        // Move every node after the opener's text node into the new node.
        let tail_first = self.tree.node(opener.node).next;
        let tail_last = self.tree.node(self.root).last_child;
        if let Some(first) = tail_first {
            self.tree.node_mut(first).prev = None;
            let n = self.tree.node_mut(node);
            n.first_child = Some(first);
            n.last_child = tail_last;
            self.tree.node_mut(opener.node).next = None;
            self.tree.node_mut(self.root).last_child = Some(opener.node);
        }
        self.tree.unlink(self.root, opener.node);
        self.tree.append_child(self.root, node);

        self.process_emphasis(node, opener.position);
        self.brackets.pop();
        if !opener.image {
            self.link_closed = true;
        }
        self.pos = end;
    }
}
