//! Phase 1 of the Markdown conversion: the block structure.
//!
//! The parser reads the document line by line. Each line is matched against
//! the chain of open blocks, may open new blocks, and finally contributes its
//! text to the innermost open leaf block. The blocks live in an arena
//! (`Vec<Block>`) and refer to each other by index.

use super::inline::decode_entities;

pub(crate) const NONE: usize = usize::MAX;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub(crate) enum Kind {
    Document,
    BlockQuote,
    List,
    Item,
    Paragraph,
    Heading,
    ThematicBreak,
    IndentedCode,
    FencedCode,
}

#[derive(Debug)]
pub(crate) struct Block {
    pub kind: Kind,
    pub parent: usize,
    pub children: Vec<usize>,
    pub open: bool,
    pub last_line_blank: bool,
    pub last_line_checked: bool,
    pub start_line: usize,
    /// Raw text of leaf blocks (for fenced code: the info line, then the code).
    pub content: Vec<u8>,
    // Lists.
    pub ordered: bool,
    /// Bullet character, or the delimiter (`.` / `)`) of an ordered list.
    pub list_char: u8,
    pub start: u64,
    pub tight: bool,
    // Items.
    pub marker_offset: usize,
    pub padding: usize,
    // Headings.
    pub level: u8,
    // Fenced code.
    pub fence_char: u8,
    pub fence_len: usize,
    pub fence_offset: usize,
    pub info: String,
}

impl Block {
    fn new(kind: Kind, parent: usize, start_line: usize) -> Block {
        Block {
            kind,
            parent,
            children: Vec::new(),
            open: true,
            last_line_blank: false,
            last_line_checked: false,
            start_line,
            content: Vec::new(),
            ordered: false,
            list_char: 0,
            start: 0,
            tight: true,
            marker_offset: 0,
            padding: 0,
            level: 0,
            fence_char: 0,
            fence_len: 0,
            fence_offset: 0,
            info: String::new(),
        }
    }
}

/// The finished block tree. Index 0 is the document.
pub(crate) struct Tree {
    pub blocks: Vec<Block>,
}

const DOC: usize = 0;

fn is_space_or_tab(c: u8) -> bool {
    c == b' ' || c == b'\t'
}

fn is_ascii_punct(c: u8) -> bool {
    c.is_ascii_punctuation()
}

/// Result of matching a line against one open block.
enum Continue {
    Yes,
    No,
    /// The line closed a fenced code block and is fully consumed.
    Stop,
}

struct Parser<'a> {
    blocks: Vec<Block>,
    tip: usize,
    line: &'a [u8],
    line_number: usize,
    offset: usize,
    column: usize,
    first_nonspace: usize,
    first_nonspace_column: usize,
    indent: usize,
    blank: bool,
    partially_consumed_tab: bool,
}

/// Parse `input` into a block tree.
pub(crate) fn parse(input: &str) -> Tree {
    let mut p = Parser {
        blocks: vec![Block::new(Kind::Document, NONE, 0)],
        tip: DOC,
        line: &[],
        line_number: 0,
        offset: 0,
        column: 0,
        first_nonspace: 0,
        first_nonspace_column: 0,
        indent: 0,
        blank: false,
        partially_consumed_tab: false,
    };
    let bytes = input.as_bytes();
    let mut start = 0;
    while start < bytes.len() {
        let end = bytes[start..]
            .iter()
            .position(|&b| b == b'\n')
            .map_or(bytes.len(), |i| start + i);
        p.process_line(&bytes[start..end]);
        start = end + 1;
    }
    // Close every open block.
    while p.tip != DOC {
        p.tip = p.finalize(p.tip);
    }
    p.finalize(DOC);
    Tree { blocks: p.blocks }
}

impl<'a> Parser<'a> {
    /// Byte at `i`, treating the line as if it were followed by one `\n`.
    fn peek(&self, i: usize) -> u8 {
        if i < self.line.len() {
            self.line[i]
        } else if i == self.line.len() {
            b'\n'
        } else {
            0
        }
    }

    fn find_first_nonspace(&mut self) {
        let mut chars_to_tab = 4 - (self.column % 4);
        self.first_nonspace = self.offset;
        self.first_nonspace_column = self.column;
        loop {
            match self.peek(self.first_nonspace) {
                b' ' => {
                    self.first_nonspace += 1;
                    self.first_nonspace_column += 1;
                    chars_to_tab -= 1;
                    if chars_to_tab == 0 {
                        chars_to_tab = 4;
                    }
                }
                b'\t' => {
                    self.first_nonspace += 1;
                    self.first_nonspace_column += chars_to_tab;
                    chars_to_tab = 4;
                }
                _ => break,
            }
        }
        self.indent = self.first_nonspace_column - self.column;
        let c = self.peek(self.first_nonspace);
        self.blank = c == b'\n' || self.first_nonspace >= self.line.len();
    }

    /// Advance `count` characters (or columns, when `columns`).
    fn advance(&mut self, mut count: usize, columns: bool) {
        while count > 0 {
            if self.offset >= self.line.len() {
                // Past the end of the line: nothing left to consume.
                self.offset = self.line.len() + 1;
                break;
            }
            let c = self.line[self.offset];
            if c == b'\t' {
                let chars_to_tab = 4 - (self.column % 4);
                if columns {
                    self.partially_consumed_tab = chars_to_tab > count;
                    let advance = chars_to_tab.min(count);
                    self.column += advance;
                    if !self.partially_consumed_tab {
                        self.offset += 1;
                    }
                    count -= advance;
                } else {
                    self.partially_consumed_tab = false;
                    self.column += chars_to_tab;
                    self.offset += 1;
                    count -= 1;
                }
            } else {
                self.partially_consumed_tab = false;
                self.offset += 1;
                self.column += 1;
                count -= 1;
            }
        }
    }

    /// Append the rest of the line (plus a newline) to `block`'s content.
    fn add_line(&mut self, block: usize) {
        if self.partially_consumed_tab {
            self.offset += 1;
            let chars_to_tab = 4 - (self.column % 4);
            for _ in 0..chars_to_tab {
                self.blocks[block].content.push(b' ');
            }
        }
        if self.offset < self.line.len() {
            let rest = &self.line[self.offset..];
            self.blocks[block].content.extend_from_slice(rest);
        }
        self.blocks[block].content.push(b'\n');
    }

    fn can_contain(parent: Kind, child: Kind) -> bool {
        match parent {
            Kind::Document | Kind::BlockQuote | Kind::Item => child != Kind::Item,
            Kind::List => child == Kind::Item,
            _ => false,
        }
    }

    fn add_child(&mut self, mut parent: usize, kind: Kind) -> usize {
        while !Self::can_contain(self.blocks[parent].kind, kind) {
            parent = self.finalize(parent);
        }
        let id = self.blocks.len();
        self.blocks.push(Block::new(kind, parent, self.line_number));
        self.blocks[parent].children.push(id);
        id
    }

    /// Close a block, returning its parent.
    fn finalize(&mut self, b: usize) -> usize {
        let parent = self.blocks[b].parent;
        self.blocks[b].open = false;
        match self.blocks[b].kind {
            Kind::IndentedCode => {
                let blk = &mut self.blocks[b];
                remove_trailing_blank_lines(&mut blk.content);
                blk.content.push(b'\n');
            }
            Kind::FencedCode => {
                let blk = &mut self.blocks[b];
                let first_len = blk
                    .content
                    .iter()
                    .position(|&c| c == b'\n')
                    .unwrap_or(blk.content.len());
                let info_raw = String::from_utf8_lossy(&blk.content[..first_len]).into_owned();
                let decoded = decode_entities(&info_raw);
                let trimmed = decoded.trim_matches(|c: char| {
                    matches!(c, ' ' | '\t' | '\n' | '\x0b' | '\x0c' | '\r')
                });
                blk.info = unescape_backslashes(trimmed);
                let rest_start = (first_len + 1).min(blk.content.len());
                blk.content.drain(..rest_start);
            }
            Kind::List => self.finalize_list(b),
            _ => {}
        }
        parent
    }

    fn finalize_list(&mut self, list: usize) {
        let mut tight = true;
        let items = self.blocks[list].children.clone();
        'outer: for (ii, &item) in items.iter().enumerate() {
            let has_next_item = ii + 1 < items.len();
            if self.blocks[item].last_line_blank && has_next_item {
                tight = false;
                break;
            }
            let subs = self.blocks[item].children.clone();
            for (si, &sub) in subs.iter().enumerate() {
                let has_next_sub = si + 1 < subs.len();
                if (has_next_item || has_next_sub) && self.ends_with_blank_line(sub) {
                    tight = false;
                    break 'outer;
                }
            }
        }
        self.blocks[list].tight = tight;
    }

    /// cmark's memoised "ends with a blank line" test.
    fn ends_with_blank_line(&mut self, mut node: usize) -> bool {
        loop {
            if self.blocks[node].last_line_checked {
                return self.blocks[node].last_line_blank;
            }
            self.blocks[node].last_line_checked = true;
            let kind = self.blocks[node].kind;
            if matches!(kind, Kind::List | Kind::Item) {
                if let Some(&last) = self.blocks[node].children.last() {
                    node = last;
                    continue;
                }
            }
            return self.blocks[node].last_line_blank;
        }
    }

    fn process_line(&mut self, line: &'a [u8]) {
        self.line = line;
        self.line_number += 1;
        self.offset = 0;
        self.column = 0;
        self.blank = false;
        self.partially_consumed_tab = false;

        // Step 1: continue open blocks.
        let mut container = DOC;
        loop {
            let last = match self.blocks[container].children.last() {
                Some(&l) if self.blocks[l].open => l,
                _ => break,
            };
            self.find_first_nonspace();
            match self.continue_block(last) {
                Continue::Yes => container = last,
                Continue::No => break,
                Continue::Stop => return,
            }
        }
        let last_matched = container;

        // Step 2: start new blocks.
        container = self.open_new_blocks(container);

        // Step 3: add the text of the line.
        self.find_first_nonspace();
        if self.blank {
            if let Some(&last_child) = self.blocks[container].children.last() {
                self.blocks[last_child].last_line_blank = true;
            }
        }
        let ckind = self.blocks[container].kind;
        let last_line_blank = self.blank
            && ckind != Kind::BlockQuote
            && ckind != Kind::Heading
            && ckind != Kind::ThematicBreak
            && ckind != Kind::FencedCode
            && !(ckind == Kind::Item
                && self.blocks[container].children.is_empty()
                && self.blocks[container].start_line == self.line_number);
        self.blocks[container].last_line_blank = last_line_blank;
        let mut anc = self.blocks[container].parent;
        while anc != NONE {
            self.blocks[anc].last_line_blank = false;
            anc = self.blocks[anc].parent;
        }

        if self.tip != last_matched
            && container == last_matched
            && !self.blank
            && self.blocks[self.tip].kind == Kind::Paragraph
        {
            // Lazy continuation line.
            let tip = self.tip;
            self.add_line(tip);
            return;
        }

        // Close every open block below last_matched.
        while self.tip != last_matched {
            self.tip = self.finalize(self.tip);
        }

        let ckind = self.blocks[container].kind;
        if matches!(ckind, Kind::IndentedCode | Kind::FencedCode) {
            self.add_line(container);
        } else if self.blank {
            // Nothing to add.
        } else if matches!(ckind, Kind::Heading | Kind::Paragraph) {
            self.advance(self.first_nonspace - self.offset, false);
            if ckind == Kind::Heading
                && self.blocks[container].level > 0
                && !self.is_setext(container)
            {
                self.add_atx_line(container);
            } else {
                self.add_line(container);
            }
        } else {
            container = self.add_child(container, Kind::Paragraph);
            self.advance(self.first_nonspace - self.offset, false);
            self.add_line(container);
        }
        self.tip = container;
    }

    fn is_setext(&self, b: usize) -> bool {
        // Setext headings are created from paragraphs, which already have content.
        !self.blocks[b].content.is_empty()
    }

    /// Add the text of an ATX heading line, removing the closing `#` sequence.
    fn add_atx_line(&mut self, block: usize) {
        let start = self.offset.min(self.line.len());
        let mut end = self.line.len();
        while end > start && matches!(self.line[end - 1], b' ' | b'\t' | b'\x0b' | b'\x0c' | b'\r')
        {
            end -= 1;
        }
        let mut n = end;
        while n > start && self.line[n - 1] == b'#' {
            n -= 1;
        }
        if n != end && (n == start || is_space_or_tab(self.line[n - 1])) {
            end = n;
            while end > start && is_space_or_tab(self.line[end - 1]) {
                end -= 1;
            }
        }
        let content = &self.line[start..end];
        self.blocks[block].content.extend_from_slice(content);
        self.blocks[block].content.push(b'\n');
    }

    fn continue_block(&mut self, b: usize) -> Continue {
        match self.blocks[b].kind {
            Kind::BlockQuote => {
                if self.indent <= 3 && self.peek(self.first_nonspace) == b'>' {
                    self.advance(self.first_nonspace + 1 - self.offset, false);
                    if is_space_or_tab(self.peek(self.offset)) {
                        self.advance(1, true);
                    }
                    Continue::Yes
                } else {
                    Continue::No
                }
            }
            Kind::Item => {
                let need = self.blocks[b].marker_offset + self.blocks[b].padding;
                if self.indent >= need {
                    self.advance(need, true);
                    Continue::Yes
                } else if self.blank && !self.blocks[b].children.is_empty() {
                    self.advance(self.first_nonspace - self.offset, false);
                    Continue::Yes
                } else {
                    Continue::No
                }
            }
            Kind::IndentedCode => {
                if self.indent >= 4 {
                    self.advance(4, true);
                    Continue::Yes
                } else if self.blank {
                    self.advance(self.first_nonspace - self.offset, false);
                    Continue::Yes
                } else {
                    Continue::No
                }
            }
            Kind::FencedCode => {
                let fc = self.blocks[b].fence_char;
                let fl = self.blocks[b].fence_len;
                if self.indent <= 3 && self.peek(self.first_nonspace) == fc {
                    let mut i = self.first_nonspace;
                    while self.peek(i) == fc && i < self.line.len() {
                        i += 1;
                    }
                    let run = i - self.first_nonspace;
                    if run >= fl {
                        while i < self.line.len() && is_space_or_tab(self.line[i]) {
                            i += 1;
                        }
                        if i >= self.line.len() {
                            self.tip = self.finalize(b);
                            return Continue::Stop;
                        }
                    }
                }
                let mut skip = self.blocks[b].fence_offset;
                while skip > 0 && is_space_or_tab(self.peek(self.offset)) {
                    self.advance(1, true);
                    skip -= 1;
                }
                Continue::Yes
            }
            Kind::Heading => Continue::No,
            Kind::Paragraph => {
                if self.blank {
                    Continue::No
                } else {
                    Continue::Yes
                }
            }
            Kind::ThematicBreak | Kind::List | Kind::Document => Continue::Yes,
        }
    }

    fn open_new_blocks(&mut self, mut container: usize) -> usize {
        let mut maybe_lazy = self.blocks[self.tip].kind == Kind::Paragraph;
        loop {
            let ckind = self.blocks[container].kind;
            if matches!(ckind, Kind::IndentedCode | Kind::FencedCode) {
                break;
            }
            self.find_first_nonspace();
            let indented = self.indent >= 4;
            let c = self.peek(self.first_nonspace);

            if !indented && c == b'>' {
                self.advance(self.first_nonspace + 1 - self.offset, false);
                if is_space_or_tab(self.peek(self.offset)) {
                    self.advance(1, true);
                }
                container = self.add_child(container, Kind::BlockQuote);
            } else if let (false, Some((level, len))) = (indented, self.scan_atx_start(c)) {
                self.advance(self.first_nonspace + len - self.offset, false);
                container = self.add_child(container, Kind::Heading);
                self.blocks[container].level = level;
                break;
            } else if let (false, Some((fc, len))) = (indented, self.scan_open_fence(c)) {
                let fence_offset = self.first_nonspace - self.offset;
                container = self.add_child(container, Kind::FencedCode);
                let blk = &mut self.blocks[container];
                blk.fence_char = fc;
                blk.fence_len = len;
                blk.fence_offset = fence_offset;
                self.advance(self.first_nonspace + len - self.offset, false);
                break;
            } else if !indented
                && ckind == Kind::Paragraph
                && (c == b'=' || c == b'-')
                && self.scan_setext(c).is_some()
            {
                let level = if c == b'=' { 1 } else { 2 };
                self.blocks[container].kind = Kind::Heading;
                self.blocks[container].level = level;
                self.advance(self.line.len().saturating_sub(self.offset), false);
                break;
            } else if !indented && self.scan_thematic_break(c) {
                container = self.add_child(container, Kind::ThematicBreak);
                self.advance(self.line.len().saturating_sub(self.offset), false);
                break;
            } else if self.indent < 4 && self.try_list_item(&mut container) {
                // container is now the new item.
            } else if indented && !maybe_lazy && !self.blank {
                self.advance(4, true);
                container = self.add_child(container, Kind::IndentedCode);
                break;
            } else {
                break;
            }
            maybe_lazy = false;
        }
        container
    }

    fn scan_atx_start(&self, c: u8) -> Option<(u8, usize)> {
        if c != b'#' {
            return None;
        }
        let mut i = self.first_nonspace;
        while self.peek(i) == b'#' && i < self.line.len() {
            i += 1;
        }
        let level = i - self.first_nonspace;
        if !(1..=6).contains(&level) {
            return None;
        }
        let after = self.peek(i);
        if !(is_space_or_tab(after) || i >= self.line.len()) {
            return None;
        }
        while i < self.line.len() && is_space_or_tab(self.line[i]) {
            i += 1;
        }
        Some((level as u8, i - self.first_nonspace))
    }

    fn scan_open_fence(&self, c: u8) -> Option<(u8, usize)> {
        if c != b'`' && c != b'~' {
            return None;
        }
        let mut i = self.first_nonspace;
        while i < self.line.len() && self.line[i] == c {
            i += 1;
        }
        let run = i - self.first_nonspace;
        if run < 3 {
            return None;
        }
        if c == b'`' && self.line[i..].contains(&b'`') {
            return None;
        }
        Some((c, run))
    }

    fn scan_setext(&self, c: u8) -> Option<()> {
        let mut i = self.first_nonspace;
        while i < self.line.len() && self.line[i] == c {
            i += 1;
        }
        while i < self.line.len() && is_space_or_tab(self.line[i]) {
            i += 1;
        }
        if i >= self.line.len() {
            Some(())
        } else {
            None
        }
    }

    fn scan_thematic_break(&self, c: u8) -> bool {
        if c != b'*' && c != b'_' && c != b'-' {
            return false;
        }
        let mut count = 0;
        let mut i = self.first_nonspace;
        while i < self.line.len() {
            let ch = self.line[i];
            if ch == c {
                count += 1;
            } else if !is_space_or_tab(ch) {
                return false;
            }
            i += 1;
        }
        count >= 3
    }

    /// Try to start a list item at the current position. On success updates
    /// `container` to the new item and returns true.
    fn try_list_item(&mut self, container: &mut usize) -> bool {
        let interrupts_paragraph = self.blocks[*container].kind == Kind::Paragraph;
        let c = self.peek(self.first_nonspace);
        let mut i = self.first_nonspace;
        let ordered;
        let list_char;
        let mut start: u64 = 0;
        if c == b'-' || c == b'+' || c == b'*' {
            i += 1;
            if !matches!(self.peek(i), b' ' | b'\t' | b'\n') && i < self.line.len() {
                return false;
            }
            if interrupts_paragraph && self.rest_blank(i) {
                return false;
            }
            ordered = false;
            list_char = c;
        } else if c.is_ascii_digit() {
            let mut digits = 0;
            while digits < 9 && i < self.line.len() && self.line[i].is_ascii_digit() {
                start = start * 10 + u64::from(self.line[i] - b'0');
                i += 1;
                digits += 1;
            }
            let d = self.peek(i);
            if (d != b'.' && d != b')') || i >= self.line.len() {
                return false;
            }
            i += 1;
            if !matches!(self.peek(i), b' ' | b'\t' | b'\n') && i < self.line.len() {
                return false;
            }
            if interrupts_paragraph && (start != 1 || self.rest_blank(i)) {
                return false;
            }
            ordered = true;
            list_char = d;
        } else {
            return false;
        }
        let width = i - self.first_nonspace;
        let marker_offset = self.indent;
        self.advance(self.first_nonspace + width - self.offset, false);
        let save_offset = self.offset;
        let save_column = self.column;
        let save_partial = self.partially_consumed_tab;
        while self.column - save_column <= 5 && is_space_or_tab(self.peek(self.offset)) {
            self.advance(1, true);
        }
        let n = self.column - save_column;
        let padding;
        if !(1..5).contains(&n) || self.offset >= self.line.len() {
            padding = width + 1;
            self.offset = save_offset;
            self.column = save_column;
            self.partially_consumed_tab = save_partial;
            if n > 0 {
                self.advance(1, true);
            }
        } else {
            padding = width + n;
        }

        let ck = self.blocks[*container].kind;
        let same_list = ck == Kind::List
            && self.blocks[*container].ordered == ordered
            && self.blocks[*container].list_char == list_char;
        if !same_list {
            let list = self.add_child(*container, Kind::List);
            let b = &mut self.blocks[list];
            b.ordered = ordered;
            b.list_char = list_char;
            b.start = start;
            *container = list;
        }
        let item = self.add_child(*container, Kind::Item);
        self.blocks[item].marker_offset = marker_offset;
        self.blocks[item].padding = padding;
        *container = item;
        true
    }

    /// True when only spaces and tabs remain on the line from `i`.
    fn rest_blank(&self, mut i: usize) -> bool {
        while i < self.line.len() && is_space_or_tab(self.line[i]) {
            i += 1;
        }
        i >= self.line.len()
    }
}

fn remove_trailing_blank_lines(content: &mut Vec<u8>) {
    let mut i = content.len();
    while i > 0 && matches!(content[i - 1], b' ' | b'\t' | b'\n' | b'\r') {
        i -= 1;
    }
    if i == 0 {
        content.clear();
        return;
    }
    // `i` is one past the last non-blank byte; cut at the first newline at or after it.
    let cut = content[i - 1..]
        .iter()
        .position(|&c| c == b'\n' || c == b'\r')
        .map(|p| p + i - 1);
    if let Some(cut) = cut {
        content.truncate(cut);
    }
}

/// Remove the backslash from every backslash-escaped ASCII punctuation character.
pub(crate) fn unescape_backslashes(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = String::with_capacity(s.len());
    let mut i = 0;
    let mut run_start = 0;
    while i < b.len() {
        if b[i] == b'\\' && i + 1 < b.len() && is_ascii_punct(b[i + 1]) {
            out.push_str(&s[run_start..i]);
            i += 1;
            run_start = i;
            i += 1;
        } else {
            i += 1;
        }
    }
    out.push_str(&s[run_start..]);
    out
}
