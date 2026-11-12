//! A CommonMark (subset) to HTML converter.
//!
//! The converter reproduces the output of the reference implementation
//! `cmark` 0.31.2 for a subset of CommonMark: thematic breaks, ATX and setext
//! headings, indented and fenced code blocks, paragraphs, block quotes, lists,
//! backslash escapes, numeric entities and the entities `&amp; &lt; &gt;
//! &quot;`, code spans, emphasis, inline links and images, autolinks and line
//! breaks. Raw HTML, link reference definitions and extensions are *not*
//! supported.
//!
//! It works in two phases, like `cmark`: [`block`] reads the input line by
//! line and builds the tree of blocks; [`inline`] then parses the text of
//! each paragraph and heading into inline nodes; finally [`html`] renders the
//! tree. All three run in time linear in the input (plus the block nesting
//! depth per line) and none of them recurses on the document structure.
//!
//! # Example
//!
//! ```
//! let html = commonmark::to_html("# Hello\n\nSome *emphasis* and a [link](/url).\n");
//! assert_eq!(
//!     html,
//!     "<h1>Hello</h1>\n<p>Some <em>emphasis</em> and a <a href=\"/url\">link</a>.</p>\n"
//! );
//! ```
//!
//! To inspect the parsed tree instead of rendering it:
//!
//! ```
//! use commonmark::{Document, NodeKind};
//!
//! let doc = Document::parse("> quote");
//! let quote = doc.children(doc.root()).next().unwrap();
//! assert_eq!(doc.node(quote).kind(), &NodeKind::BlockQuote);
//! ```

mod block;
mod html;
mod inline;
mod node;
mod scan;
mod text;

pub use node::{Children, ListData, Node, NodeId, NodeKind, Tree};

/// A parsed document: the tree of blocks and inlines.
#[derive(Clone, Debug)]
pub struct Document {
    tree: Tree,
}

impl Document {
    /// Parses a Markdown document.
    ///
    /// Any `&str` is accepted; line endings are expected to be `\n`.
    pub fn parse(input: &str) -> Document {
        let (mut tree, leaves) = block::parse_blocks(input);
        for (id, content) in leaves {
            inline::parse_inlines(&mut tree, id, &content);
        }
        tree.fix_parents();
        Document { tree }
    }

    /// Renders the document as HTML.
    pub fn to_html(&self) -> String {
        html::render(&self.tree)
    }

    /// The id of the root ([`NodeKind::Document`]) node.
    pub fn root(&self) -> NodeId {
        Tree::ROOT
    }

    /// Looks up a node.
    pub fn node(&self, id: NodeId) -> &Node {
        self.tree.node(id)
    }

    /// Iterates over the children of a node.
    pub fn children(&self, id: NodeId) -> Children<'_> {
        self.tree.children(id)
    }

    /// The underlying tree.
    pub fn tree(&self) -> &Tree {
        &self.tree
    }
}

/// Converts Markdown to HTML in one call.
pub fn to_html(input: &str) -> String {
    Document::parse(input).to_html()
}
