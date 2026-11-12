//! Rendering of the block tree (and its inline content) to HTML.

use super::block::{Block, Kind, Tree};
use super::inline::{self, INode, INodeKind, NONE, ROOT};

/// Append `s` to `out`, escaping `&`, `<`, `>` and `"`.
pub(crate) fn escape_html(out: &mut String, s: &str) {
    let mut last = 0;
    for (i, c) in s.bytes().enumerate() {
        let rep = match c {
            b'&' => "&amp;",
            b'<' => "&lt;",
            b'>' => "&gt;",
            b'"' => "&quot;",
            _ => continue,
        };
        out.push_str(&s[last..i]);
        out.push_str(rep);
        last = i + 1;
    }
    out.push_str(&s[last..]);
}

/// The whitespace characters of cmark's `isspace`.
const WHITESPACE: [char; 6] = [' ', '\t', '\n', '\x0b', '\x0c', '\r'];

fn cr(out: &mut String) {
    if !out.is_empty() && !out.ends_with('\n') {
        out.push('\n');
    }
}

fn starts_with_ignore_case(s: &str, prefix: &str) -> bool {
    s.len() >= prefix.len() && s.as_bytes()[..prefix.len()].eq_ignore_ascii_case(prefix.as_bytes())
}

/// Append a destination as an `href`/`src` attribute value.
fn escape_href(out: &mut String, dest: &str) {
    let blocked = ["javascript:", "vbscript:", "file:", "data:"]
        .iter()
        .any(|p| starts_with_ignore_case(dest, p));
    let allowed = [
        "data:image/png",
        "data:image/gif",
        "data:image/jpeg",
        "data:image/webp",
    ]
    .iter()
    .any(|p| starts_with_ignore_case(dest, p));
    if blocked && !allowed {
        return;
    }
    const HEX: &[u8; 16] = b"0123456789ABCDEF";
    for &c in dest.as_bytes() {
        match c {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' => out.push(c as char),
            b'-' | b'_' | b'.' | b'~' | b'!' | b'#' | b'$' | b'%' | b'(' | b')' | b'*' | b'+'
            | b',' | b'/' | b':' | b';' | b'=' | b'?' | b'@' => out.push(c as char),
            b'&' => out.push_str("&amp;"),
            b'\'' => out.push_str("&#x27;"),
            _ => {
                out.push('%');
                out.push(HEX[(c >> 4) as usize] as char);
                out.push(HEX[(c & 15) as usize] as char);
            }
        }
    }
}

pub(crate) fn render(tree: &Tree) -> String {
    let mut out = String::new();
    render_block(tree, 0, &mut out);
    out
}

fn render_children(tree: &Tree, b: &Block, out: &mut String) {
    for &c in &b.children {
        render_block(tree, c, out);
    }
}

fn render_block(tree: &Tree, id: usize, out: &mut String) {
    let b = &tree.blocks[id];
    match b.kind {
        Kind::Document => render_children(tree, b, out),
        Kind::BlockQuote => {
            cr(out);
            out.push_str("<blockquote>\n");
            render_children(tree, b, out);
            cr(out);
            out.push_str("</blockquote>\n");
        }
        Kind::List => {
            cr(out);
            let tag = if b.ordered { "ol" } else { "ul" };
            if b.ordered && b.start != 1 {
                out.push_str(&format!("<ol start=\"{}\">\n", b.start));
            } else {
                out.push_str(&format!("<{}>\n", tag));
            }
            render_children(tree, b, out);
            out.push_str(&format!("</{}>\n", tag));
        }
        Kind::Item => {
            cr(out);
            out.push_str("<li>");
            render_children(tree, b, out);
            out.push_str("</li>\n");
        }
        Kind::Paragraph => {
            let tight = b.parent != usize::MAX && {
                let item = &tree.blocks[b.parent];
                item.parent != usize::MAX && {
                    let g = &tree.blocks[item.parent];
                    g.kind == Kind::List && g.tight
                }
            };
            if !tight {
                cr(out);
                out.push_str("<p>");
            }
            render_inlines(&b.content, out);
            if !tight {
                out.push_str("</p>\n");
            }
        }
        Kind::Heading => {
            cr(out);
            out.push_str(&format!("<h{}>", b.level));
            render_inlines(&b.content, out);
            out.push_str(&format!("</h{}>\n", b.level));
        }
        Kind::ThematicBreak => {
            cr(out);
            out.push_str("<hr />\n");
        }
        Kind::IndentedCode | Kind::FencedCode => {
            cr(out);
            let info = b.info.as_str();
            if info.is_empty() {
                out.push_str("<pre><code>");
            } else {
                let lang = info.split(WHITESPACE).next().unwrap_or("");
                out.push_str("<pre><code class=\"");
                if !lang.starts_with("language-") {
                    out.push_str("language-");
                }
                escape_html(out, lang);
                out.push_str("\">");
            }
            escape_html(out, &String::from_utf8_lossy(&b.content));
            out.push_str("</code></pre>\n");
        }
    }
}

/// Parse the raw content of a paragraph or heading and append its HTML.
fn render_inlines(content: &[u8], out: &mut String) {
    let text = String::from_utf8_lossy(content);
    let trimmed = text.trim_end_matches(WHITESPACE);
    let nodes = inline::parse(trimmed);
    render_inline_tree(&nodes, out);
}

fn render_inline_tree(nodes: &[INode], out: &mut String) {
    let mut node = nodes[ROOT].first;
    if node == NONE {
        return;
    }
    loop {
        // Enter `node`; returns whether to descend into its children.
        let descend = match &nodes[node].kind {
            INodeKind::Root => false,
            INodeKind::Text(t) => {
                escape_html(out, t);
                false
            }
            INodeKind::SoftBreak => {
                out.push('\n');
                false
            }
            INodeKind::LineBreak => {
                out.push_str("<br />\n");
                false
            }
            INodeKind::Code(c) => {
                out.push_str("<code>");
                escape_html(out, c);
                out.push_str("</code>");
                false
            }
            INodeKind::Emph => {
                out.push_str("<em>");
                true
            }
            INodeKind::Strong => {
                out.push_str("<strong>");
                true
            }
            INodeKind::Link { dest, title } => {
                out.push_str("<a href=\"");
                escape_href(out, dest);
                out.push('"');
                if let Some(t) = title {
                    out.push_str(" title=\"");
                    escape_html(out, t);
                    out.push('"');
                }
                out.push('>');
                true
            }
            INodeKind::Image { dest, title } => {
                out.push_str("<img src=\"");
                escape_href(out, dest);
                out.push_str("\" alt=\"");
                plain_text(nodes, node, out);
                out.push('"');
                if let Some(t) = title {
                    out.push_str(" title=\"");
                    escape_html(out, t);
                    out.push('"');
                }
                out.push_str(" />");
                false
            }
        };
        if descend && nodes[node].first != NONE {
            node = nodes[node].first;
            continue;
        }
        // Leave `node`, and every ancestor whose last child we just left.
        let mut cur = node;
        loop {
            if cur != node || descend {
                close_tag(&nodes[cur].kind, out);
            }
            if nodes[cur].next != NONE {
                node = nodes[cur].next;
                break;
            }
            cur = nodes[cur].parent;
            if cur == ROOT || cur == NONE {
                return;
            }
        }
    }
}

fn close_tag(kind: &INodeKind, out: &mut String) {
    match kind {
        INodeKind::Emph => out.push_str("</em>"),
        INodeKind::Strong => out.push_str("</strong>"),
        INodeKind::Link { .. } => out.push_str("</a>"),
        _ => {}
    }
}

/// The plain text of the descendants of `image`, for the `alt` attribute.
fn plain_text(nodes: &[INode], image: usize, out: &mut String) {
    let mut node = nodes[image].first;
    if node == NONE {
        return;
    }
    loop {
        match &nodes[node].kind {
            INodeKind::Text(t) | INodeKind::Code(t) => escape_html(out, t),
            INodeKind::SoftBreak | INodeKind::LineBreak => out.push(' '),
            _ => {}
        }
        if nodes[node].first != NONE {
            node = nodes[node].first;
            continue;
        }
        loop {
            if nodes[node].next != NONE {
                node = nodes[node].next;
                break;
            }
            node = nodes[node].parent;
            if node == image {
                return;
            }
        }
    }
}
