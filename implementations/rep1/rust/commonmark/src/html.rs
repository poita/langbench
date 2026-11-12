//! HTML rendering: one iterative walk over the finished tree.

use crate::node::{NodeId, NodeKind, Tree};
use crate::text::{encode_href, escape_html, is_space, is_unsafe_url};

struct Renderer<'a> {
    tree: &'a Tree,
    out: String,
    /// While inside an image description: the image node. Only text is output.
    plain: Option<NodeId>,
}

/// Renders the tree as HTML.
pub(crate) fn render(tree: &Tree) -> String {
    let mut r = Renderer { tree, out: String::new(), plain: None };
    r.walk();
    r.out
}

impl<'a> Renderer<'a> {
    fn cr(&mut self) {
        if !self.out.is_empty() && !self.out.ends_with('\n') {
            self.out.push('\n');
        }
    }

    fn walk(&mut self) {
        let tree = self.tree;
        // Stack of (node, next child to visit).
        let mut stack: Vec<(NodeId, Option<NodeId>)> = Vec::new();
        self.enter(Tree::ROOT);
        stack.push((Tree::ROOT, tree.node(Tree::ROOT).first_child));
        while let Some(top) = stack.last_mut() {
            match top.1 {
                Some(child) => {
                    top.1 = tree.node(child).next;
                    self.enter(child);
                    match tree.node(child).first_child {
                        Some(first) => stack.push((child, Some(first))),
                        None => self.exit(child),
                    }
                }
                None => {
                    let (node, _) = stack.pop().unwrap();
                    self.exit(node);
                }
            }
        }
    }

    fn is_tight_paragraph(&self, id: NodeId) -> bool {
        let Some(item) = self.tree.node(id).parent else { return false };
        let Some(list) = self.tree.node(item).parent else { return false };
        matches!(&self.tree.node(list).kind, NodeKind::List(l) if l.tight)
    }

    fn enter(&mut self, id: NodeId) {
        let node = self.tree.node(id);
        if self.plain.is_some() {
            match &node.kind {
                NodeKind::Text(t) | NodeKind::Code(t) => escape_html(&mut self.out, t),
                NodeKind::SoftBreak | NodeKind::LineBreak => self.out.push(' '),
                _ => {}
            }
            return;
        }
        match &node.kind {
            NodeKind::Document => {}
            NodeKind::BlockQuote => {
                self.cr();
                self.out.push_str("<blockquote>\n");
            }
            NodeKind::List(l) => {
                self.cr();
                if !l.ordered {
                    self.out.push_str("<ul>\n");
                } else if l.start == 1 {
                    self.out.push_str("<ol>\n");
                } else {
                    self.out.push_str(&format!("<ol start=\"{}\">\n", l.start));
                }
            }
            NodeKind::Item => {
                self.cr();
                self.out.push_str("<li>");
            }
            NodeKind::Paragraph => {
                if !self.is_tight_paragraph(id) {
                    self.cr();
                    self.out.push_str("<p>");
                }
            }
            NodeKind::Heading { level } => {
                self.cr();
                self.out.push_str(&format!("<h{level}>"));
            }
            NodeKind::ThematicBreak => {
                self.cr();
                self.out.push_str("<hr />\n");
            }
            NodeKind::CodeBlock { info, literal } => {
                self.cr();
                if info.is_empty() {
                    self.out.push_str("<pre><code>");
                } else {
                    let end = info
                        .bytes()
                        .position(is_space)
                        .unwrap_or(info.len());
                    let word = &info[..end];
                    self.out.push_str("<pre><code class=\"");
                    if !word.starts_with("language-") {
                        self.out.push_str("language-");
                    }
                    escape_html(&mut self.out, word);
                    self.out.push_str("\">");
                }
                escape_html(&mut self.out, literal);
                self.out.push_str("</code></pre>\n");
            }
            NodeKind::Text(t) => escape_html(&mut self.out, t),
            NodeKind::SoftBreak => self.out.push('\n'),
            NodeKind::LineBreak => self.out.push_str("<br />\n"),
            NodeKind::Code(c) => {
                self.out.push_str("<code>");
                escape_html(&mut self.out, c);
                self.out.push_str("</code>");
            }
            NodeKind::Emph => self.out.push_str("<em>"),
            NodeKind::Strong => self.out.push_str("<strong>"),
            NodeKind::Link { dest, title } => {
                self.out.push_str("<a href=\"");
                if !is_unsafe_url(dest) {
                    encode_href(&mut self.out, dest);
                }
                self.out.push('"');
                if let Some(t) = title {
                    self.out.push_str(" title=\"");
                    escape_html(&mut self.out, t);
                    self.out.push('"');
                }
                self.out.push('>');
            }
            NodeKind::Image { dest, .. } => {
                self.out.push_str("<img src=\"");
                if !is_unsafe_url(dest) {
                    encode_href(&mut self.out, dest);
                }
                self.out.push_str("\" alt=\"");
                self.plain = Some(id);
            }
        }
    }

    fn exit(&mut self, id: NodeId) {
        let node = self.tree.node(id);
        if let Some(p) = self.plain {
            if p != id {
                return;
            }
            self.plain = None;
            if let NodeKind::Image { title, .. } = &node.kind {
                self.out.push('"');
                if let Some(t) = title {
                    self.out.push_str(" title=\"");
                    escape_html(&mut self.out, t);
                    self.out.push('"');
                }
                self.out.push_str(" />");
            }
            return;
        }
        match &node.kind {
            NodeKind::BlockQuote => {
                self.cr();
                self.out.push_str("</blockquote>\n");
            }
            NodeKind::List(l) => self.out.push_str(if l.ordered { "</ol>\n" } else { "</ul>\n" }),
            NodeKind::Item => self.out.push_str("</li>\n"),
            NodeKind::Paragraph => {
                if !self.is_tight_paragraph(id) {
                    self.out.push_str("</p>\n");
                }
            }
            NodeKind::Heading { level } => self.out.push_str(&format!("</h{level}>\n")),
            NodeKind::Emph => self.out.push_str("</em>"),
            NodeKind::Strong => self.out.push_str("</strong>"),
            NodeKind::Link { .. } => self.out.push_str("</a>"),
            _ => {}
        }
    }
}
