//! A CommonMark-subset to HTML converter.
//!
//! The converter implements the block structure rules, emphasis and link
//! rules of CommonMark 0.31.2 for the constructs listed below and renders
//! HTML exactly as the reference implementation `cmark` does with default
//! options.
//!
//! Supported: thematic breaks, ATX and setext headings, indented and fenced
//! code blocks, paragraphs, block quotes, lists, backslash escapes, entity
//! references (`&amp;` `&lt;` `&gt;` `&quot;` and numeric ones), code spans,
//! emphasis and strong emphasis, inline links and images, autolinks, and hard
//! and soft line breaks.
//!
//! Not supported: HTML blocks and raw inline HTML (a `<` that does not start
//! an autolink is ordinary text), link reference definitions, other named
//! entities, and all extensions.
//!
//! ```
//! let html = sitegen::markdown::to_html("# Hi\n\nSome *emphasis*.\n");
//! assert_eq!(html, "<h1>Hi</h1>\n<p>Some <em>emphasis</em>.</p>\n");
//! ```

mod block;
mod html;
mod inline;

/// Convert a Markdown document to HTML.
///
/// The result ends with a newline unless the document produces no output, in
/// which case it is empty. Line endings in `input` must be `\n`.
pub fn to_html(input: &str) -> String {
    let tree = block::parse(input);
    html::render(&tree)
}
