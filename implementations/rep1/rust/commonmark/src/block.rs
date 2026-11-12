//! Phase 1: block structure.
//!
//! The input is read line by line. Each line is first matched against the
//! chain of open blocks, then new blocks are started, and finally the rest of
//! the line is added to the innermost open leaf. This follows the line
//! processing of `cmark` (and Appendix A of the CommonMark specification).

use crate::node::{ListData, NodeId, NodeKind, Tree};
use crate::scan;
use crate::text::{decode_entities, is_space_or_tab, trim, unescape_backslashes};

const CODE_INDENT: usize = 4;

/// Parse-time state of a block (kept beside the node, discarded afterwards).
#[derive(Default)]
struct BlockInfo {
    open: bool,
    last_line_blank: bool,
    last_line_checked: bool,
    start_line: usize,
    /// Raw accumulated lines of paragraphs, headings and code blocks.
    content: String,
    /// List items: indentation of the marker and width of marker + padding.
    marker_offset: usize,
    padding: usize,
    /// Code blocks.
    fenced: bool,
    fence_char: u8,
    fence_len: usize,
    fence_offset: usize,
    /// Headings: whether this is a setext heading.
    setext: bool,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Tag {
    Document,
    BlockQuote,
    List,
    Item,
    Paragraph,
    Heading,
    ThematicBreak,
    Code,
}

enum FencePrefix {
    Matched,
    Failed,
    Closed,
}

struct BlockParser<'a> {
    tree: Tree,
    info: Vec<BlockInfo>,
    root: NodeId,
    /// The tip: the innermost open block.
    current: NodeId,
    line: &'a str,
    line_number: usize,
    offset: usize,
    column: usize,
    first_nonspace: usize,
    first_nonspace_column: usize,
    indent: usize,
    blank: bool,
    partially_consumed_tab: bool,
    /// A thematic-break scan starting before this position cannot succeed.
    thematic_kill_pos: usize,
}

/// Parses `input` into a tree of blocks. Returns the tree together with the
/// raw content of every paragraph and heading, which still has to go through
/// the inline parser.
pub(crate) fn parse_blocks(input: &str) -> (Tree, Vec<(NodeId, String)>) {
    let mut p = BlockParser::new();
    if !input.is_empty() {
        let body = input.strip_suffix('\n').unwrap_or(input);
        for line in body.split('\n') {
            p.process_line(line);
        }
    }
    p.finish()
}

impl<'a> BlockParser<'a> {
    fn new() -> Self {
        let tree = Tree::new();
        let root = Tree::ROOT;
        let info = vec![BlockInfo { open: true, ..Default::default() }];
        BlockParser {
            tree,
            info,
            root,
            current: root,
            line: "",
            line_number: 0,
            offset: 0,
            column: 0,
            first_nonspace: 0,
            first_nonspace_column: 0,
            indent: 0,
            blank: false,
            partially_consumed_tab: false,
            thematic_kill_pos: 0,
        }
    }

    // ---- small helpers -------------------------------------------------

    #[inline]
    fn peek(&self, i: usize) -> u8 {
        self.line.as_bytes().get(i).copied().unwrap_or(b'\n')
    }

    fn tag(&self, id: NodeId) -> Tag {
        match self.tree.node(id).kind {
            NodeKind::Document => Tag::Document,
            NodeKind::BlockQuote => Tag::BlockQuote,
            NodeKind::List(_) => Tag::List,
            NodeKind::Item => Tag::Item,
            NodeKind::Paragraph => Tag::Paragraph,
            NodeKind::Heading { .. } => Tag::Heading,
            NodeKind::ThematicBreak => Tag::ThematicBreak,
            NodeKind::CodeBlock { .. } => Tag::Code,
            _ => unreachable!("inline node in block tree"),
        }
    }

    fn new_block(&mut self, kind: NodeKind) -> NodeId {
        let id = self.tree.add(kind);
        self.info.push(BlockInfo {
            open: true,
            start_line: self.line_number,
            ..Default::default()
        });
        id
    }

    fn can_contain(&self, parent: NodeId, child: &NodeKind) -> bool {
        match self.tag(parent) {
            Tag::Document | Tag::BlockQuote | Tag::Item => !matches!(child, NodeKind::Item),
            Tag::List => matches!(child, NodeKind::Item),
            _ => false,
        }
    }

    /// Adds a new block under `parent`, closing blocks that cannot hold it.
    fn add_child(&mut self, mut parent: NodeId, kind: NodeKind) -> NodeId {
        while !self.can_contain(parent, &kind) {
            parent = self.finalize(parent);
        }
        let id = self.new_block(kind);
        self.tree.append_child(parent, id);
        id
    }

    fn last_open_child(&self, id: NodeId) -> Option<NodeId> {
        self.tree.node(id).last_child.filter(|c| self.info[c.idx()].open)
    }

    fn find_first_nonspace(&mut self) {
        if self.first_nonspace <= self.offset {
            self.first_nonspace = self.offset;
            self.first_nonspace_column = self.column;
            let mut chars_to_tab = 4 - (self.column % 4);
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
        }
        self.indent = self.first_nonspace_column - self.column;
        self.blank = self.peek(self.first_nonspace) == b'\n';
    }

    /// Advances over `count` columns (`columns == true`) or characters.
    fn advance(&mut self, mut count: usize, columns: bool) {
        let bytes = self.line.as_bytes();
        while count > 0 && self.offset < bytes.len() {
            if bytes[self.offset] == b'\t' {
                let chars_to_tab = 4 - (self.column % 4);
                if columns {
                    self.partially_consumed_tab = chars_to_tab > count;
                    let adv = chars_to_tab.min(count);
                    self.column += adv;
                    if !self.partially_consumed_tab {
                        self.offset += 1;
                    }
                    count -= adv;
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

    /// Appends the rest of the line (plus a newline) to a block's content.
    fn add_line(&mut self, id: NodeId) {
        let content = &mut self.info[id.idx()].content;
        if self.partially_consumed_tab {
            self.offset += 1;
            let n = 4 - (self.column % 4);
            for _ in 0..n {
                content.push(' ');
            }
        }
        content.push_str(&self.line[self.offset..]);
        content.push('\n');
    }

    // ---- line processing ----------------------------------------------

    fn process_line(&mut self, line: &'a str) {
        self.line = line;
        self.line_number += 1;
        self.offset = 0;
        self.column = 0;
        self.first_nonspace = 0;
        self.first_nonspace_column = 0;
        self.indent = 0;
        self.blank = false;
        self.partially_consumed_tab = false;
        self.thematic_kill_pos = 0;

        let Some(last_matched) = self.check_open_blocks() else {
            return;
        };
        let mut container = last_matched;
        self.open_new_blocks(&mut container);
        self.add_text_to_container(container, last_matched);
    }

    /// Step 1: walk down the open blocks. Returns the last block that matched
    /// the line, or `None` if the line closed a fence (and is fully handled).
    fn check_open_blocks(&mut self) -> Option<NodeId> {
        let mut container = self.root;
        loop {
            let Some(child) = self.last_open_child(container) else {
                return Some(container);
            };
            self.find_first_nonspace();
            let ok = match self.tag(child) {
                Tag::BlockQuote => {
                    if self.indent <= 3 && self.peek(self.first_nonspace) == b'>' {
                        self.advance(self.first_nonspace + 1 - self.offset, false);
                        if is_space_or_tab(self.peek(self.offset)) {
                            self.advance(1, true);
                        }
                        true
                    } else {
                        false
                    }
                }
                Tag::Item => {
                    let need = self.info[child.idx()].marker_offset + self.info[child.idx()].padding;
                    if self.indent >= need {
                        self.advance(need, true);
                        true
                    } else if self.blank && self.tree.node(child).first_child.is_some() {
                        self.advance(self.first_nonspace - self.offset, false);
                        true
                    } else {
                        false
                    }
                }
                Tag::Code => match self.code_block_prefix(child) {
                    FencePrefix::Matched => true,
                    FencePrefix::Failed => false,
                    FencePrefix::Closed => return None,
                },
                Tag::Heading => false,
                Tag::Paragraph => !self.blank,
                _ => true,
            };
            if !ok {
                return Some(container);
            }
            container = child;
        }
    }

    fn code_block_prefix(&mut self, code: NodeId) -> FencePrefix {
        let (fenced, fence_char, fence_len, fence_offset) = {
            let i = &self.info[code.idx()];
            (i.fenced, i.fence_char, i.fence_len, i.fence_offset)
        };
        if !fenced {
            if self.indent >= CODE_INDENT {
                self.advance(CODE_INDENT, true);
                FencePrefix::Matched
            } else if self.blank {
                self.advance(self.first_nonspace - self.offset, false);
                FencePrefix::Matched
            } else {
                FencePrefix::Failed
            }
        } else {
            let mut matched = 0;
            if self.indent <= 3 && self.peek(self.first_nonspace) == fence_char {
                matched = scan::close_code_fence(self.line.as_bytes(), self.first_nonspace, fence_char);
            }
            if matched >= fence_len && matched > 0 {
                self.current = self.finalize(code);
                FencePrefix::Closed
            } else {
                let mut i = fence_offset;
                while i > 0 && is_space_or_tab(self.peek(self.offset)) {
                    self.advance(1, true);
                    i -= 1;
                }
                FencePrefix::Matched
            }
        }
    }

    /// Step 2: start new blocks.
    fn open_new_blocks(&mut self, container: &mut NodeId) {
        let mut maybe_lazy = self.tag(self.current) == Tag::Paragraph;
        loop {
            if self.tag(*container) == Tag::Code {
                break;
            }
            self.find_first_nonspace();
            let indented = self.indent >= CODE_INDENT;
            let fns = self.first_nonspace;
            let c = self.peek(fns);
            let bytes = self.line.as_bytes();

            let opened = 'attempt: {
                if !indented && c == b'>' {
                    self.advance(fns + 1 - self.offset, false);
                    if is_space_or_tab(self.peek(self.offset)) {
                        self.advance(1, true);
                    }
                    *container = self.add_child(*container, NodeKind::BlockQuote);
                    break 'attempt true;
                }
                if !indented {
                    if let Some((level, matched)) = scan::atx_heading_start(bytes, fns) {
                        self.advance(fns + matched - self.offset, false);
                        *container = self.add_child(*container, NodeKind::Heading { level });
                        break 'attempt true;
                    }
                    if let Some((fc, flen)) = scan::open_code_fence(bytes, fns) {
                        let fence_offset = fns - self.offset;
                        *container = self.add_child(
                            *container,
                            NodeKind::CodeBlock { info: String::new(), literal: String::new() },
                        );
                        let i = &mut self.info[container.idx()];
                        i.fenced = true;
                        i.fence_char = fc;
                        i.fence_len = flen;
                        i.fence_offset = fence_offset;
                        self.advance(fns + flen - self.offset, false);
                        break 'attempt true;
                    }
                    if self.tag(*container) == Tag::Paragraph {
                        if let Some(level) = scan::setext_level(bytes, fns) {
                            self.tree.node_mut(*container).kind = NodeKind::Heading { level };
                            self.info[container.idx()].setext = true;
                            self.advance(self.line.len() - self.offset, false);
                            break 'attempt true;
                        }
                    }
                    if fns >= self.thematic_kill_pos {
                        match scan::thematic_break(bytes, fns) {
                            Ok(()) => {
                                *container = self.add_child(*container, NodeKind::ThematicBreak);
                                self.advance(self.line.len() - self.offset, false);
                                break 'attempt true;
                            }
                            Err(kill) => self.thematic_kill_pos = kill,
                        }
                    }
                    let interrupts = self.tag(*container) == Tag::Paragraph;
                    if let Some((matched, data)) = scan::list_marker(bytes, fns, interrupts) {
                        self.open_list_item(container, matched, data);
                        break 'attempt true;
                    }
                }
                if indented && !maybe_lazy && !self.blank {
                    self.advance(CODE_INDENT, true);
                    *container = self.add_child(
                        *container,
                        NodeKind::CodeBlock { info: String::new(), literal: String::new() },
                    );
                    break 'attempt true;
                }
                false
            };
            if !opened {
                break;
            }
            if matches!(self.tag(*container), Tag::Paragraph | Tag::Heading | Tag::Code) {
                break;
            }
            maybe_lazy = false;
        }
    }

    fn open_list_item(&mut self, container: &mut NodeId, matched: usize, data: ListData) {
        self.advance(self.first_nonspace + matched - self.offset, false);
        let save_tab = self.partially_consumed_tab;
        let save_offset = self.offset;
        let save_column = self.column;
        while self.column - save_column <= 5 && is_space_or_tab(self.peek(self.offset)) {
            self.advance(1, true);
        }
        let i = self.column - save_column;
        let padding;
        if !(1..5).contains(&i) || self.peek(self.offset) == b'\n' {
            padding = matched + 1;
            self.partially_consumed_tab = save_tab;
            self.offset = save_offset;
            self.column = save_column;
            if i > 0 {
                self.advance(1, true);
            }
        } else {
            padding = matched + i;
        }
        let marker_offset = self.indent;

        let same_list = match &self.tree.node(*container).kind {
            NodeKind::List(l) => l.ordered == data.ordered && l.marker == data.marker,
            _ => false,
        };
        if !same_list {
            *container = self.add_child(*container, NodeKind::List(data));
        }
        *container = self.add_child(*container, NodeKind::Item);
        let info = &mut self.info[container.idx()];
        info.marker_offset = marker_offset;
        info.padding = padding;
    }

    /// Step 3: add the rest of the line to the right place.
    fn add_text_to_container(&mut self, container: NodeId, last_matched: NodeId) {
        self.find_first_nonspace();

        if self.blank {
            if let Some(last) = self.tree.node(container).last_child {
                self.info[last.idx()].last_line_blank = true;
            }
        }
        let ctag = self.tag(container);
        let last_line_blank = self.blank
            && ctag != Tag::BlockQuote
            && ctag != Tag::Heading
            && ctag != Tag::ThematicBreak
            && !(ctag == Tag::Code && self.info[container.idx()].fenced)
            && !(ctag == Tag::Item
                && self.tree.node(container).first_child.is_none()
                && self.info[container.idx()].start_line == self.line_number);
        self.info[container.idx()].last_line_blank = last_line_blank;
        let mut tmp = container;
        while let Some(p) = self.tree.node(tmp).parent {
            self.info[p.idx()].last_line_blank = false;
            tmp = p;
        }

        if self.current != last_matched
            && container == last_matched
            && !self.blank
            && self.tag(self.current) == Tag::Paragraph
        {
            // Lazy continuation line.
            let cur = self.current;
            self.add_line(cur);
            return;
        }

        while self.current != last_matched {
            self.current = self.finalize(self.current);
        }
        let mut container = container;
        if self.tag(container) == Tag::Code {
            self.add_line(container);
        } else if self.blank {
            // nothing to add
        } else if matches!(self.tag(container), Tag::Paragraph | Tag::Heading) {
            self.advance(self.first_nonspace - self.offset, false);
            if self.tag(container) == Tag::Heading && !self.info[container.idx()].setext {
                self.add_atx_line(container);
            } else {
                self.add_line(container);
            }
        } else {
            container = self.add_child(container, NodeKind::Paragraph);
            self.advance(self.first_nonspace - self.offset, false);
            self.add_line(container);
        }
        self.current = container;
    }

    /// Adds the content of an ATX heading line, minus the closing sequence.
    fn add_atx_line(&mut self, id: NodeId) {
        let rest = &self.line[self.offset..];
        let mut end = crate::text::trim_end(rest).len();
        let b = rest.as_bytes();
        let mut n = end;
        while n > 0 && b[n - 1] == b'#' {
            n -= 1;
        }
        if n != end && (n == 0 || is_space_or_tab(b[n - 1])) {
            end = crate::text::trim_end(&rest[..n]).len();
        }
        let content = &mut self.info[id.idx()].content;
        content.push_str(&rest[..end]);
        content.push('\n');
    }

    // ---- closing blocks -------------------------------------------------

    /// Closes a block and returns its parent.
    fn finalize(&mut self, id: NodeId) -> NodeId {
        let parent = self.tree.node(id).parent.expect("root is never finalized here");
        self.info[id.idx()].open = false;
        match self.tag(id) {
            Tag::Code => self.finalize_code(id),
            Tag::List => self.finalize_list(id),
            _ => {}
        }
        parent
    }

    fn finalize_code(&mut self, id: NodeId) {
        let content = std::mem::take(&mut self.info[id.idx()].content);
        let (info, literal) = if !self.info[id.idx()].fenced {
            let b = content.as_bytes();
            let mut i = b.len();
            while i > 0 && matches!(b[i - 1], b' ' | b'\t' | b'\n') {
                i -= 1;
            }
            let mut lit = if i == 0 {
                String::new()
            } else {
                // Cut at the first newline at or after the last non-blank.
                let cut = content[i..].find('\n').map_or(content.len(), |p| p + i);
                content[..cut].to_string()
            };
            lit.push('\n');
            (String::new(), lit)
        } else {
            let nl = content.find('\n').unwrap_or(content.len());
            let info = unescape_backslashes(trim(&decode_entities(&content[..nl])));
            let lit = content[(nl + 1).min(content.len())..].to_string();
            (info, lit)
        };
        self.tree.node_mut(id).kind = NodeKind::CodeBlock { info, literal };
    }

    fn ends_with_blank_line(&mut self, mut n: NodeId) -> bool {
        loop {
            if self.info[n.idx()].last_line_checked {
                return self.info[n.idx()].last_line_blank;
            }
            self.info[n.idx()].last_line_checked = true;
            let node = self.tree.node(n);
            match (&node.kind, node.last_child) {
                (NodeKind::List(_) | NodeKind::Item, Some(last)) => n = last,
                _ => return self.info[n.idx()].last_line_blank,
            }
        }
    }

    fn finalize_list(&mut self, id: NodeId) {
        let mut tight = true;
        let mut item = self.tree.node(id).first_child;
        'items: while let Some(it) = item {
            let item_next = self.tree.node(it).next;
            if self.info[it.idx()].last_line_blank && item_next.is_some() {
                tight = false;
                break;
            }
            let mut sub = self.tree.node(it).first_child;
            while let Some(s) = sub {
                let sub_next = self.tree.node(s).next;
                if (item_next.is_some() || sub_next.is_some()) && self.ends_with_blank_line(s) {
                    tight = false;
                    break 'items;
                }
                sub = sub_next;
            }
            item = item_next;
        }
        if let NodeKind::List(l) = &mut self.tree.node_mut(id).kind {
            l.tight = tight;
        }
    }

    fn finish(mut self) -> (Tree, Vec<(NodeId, String)>) {
        while self.current != self.root {
            self.current = self.finalize(self.current);
        }
        let mut leaves = Vec::new();
        for i in 0..self.info.len() {
            if matches!(self.tree.nodes[i].kind, NodeKind::Paragraph | NodeKind::Heading { .. }) {
                leaves.push((NodeId(i as u32), std::mem::take(&mut self.info[i].content)));
            }
        }
        (self.tree, leaves)
    }
}
