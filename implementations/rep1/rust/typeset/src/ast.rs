//! The block tree produced by the Codexa parser.

use crate::metrics::Family;
use crate::settings::Align;

/// A style tag in `{tag|...}`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Tag {
    Bold,
    Italic,
    Mono,
    Larger,
    Smaller,
}

/// One element of parsed inline text.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Inline {
    /// An ordinary character.
    Char(char),
    /// A space (runs are collapsed when the horizontal list is built).
    Space,
    /// A rigid space: `~` or `\ `.
    Rigid,
    /// A discretionary hyphenation point `\-`.
    Disc,
    /// A styled span.
    Style(Tag, Vec<Inline>),
    /// A footnote: its 1-based number in source order and its text.
    Note(usize, Vec<Inline>),
}

/// Document metadata from `@doc`.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Meta {
    pub title: String,
    pub author: String,
    pub date: String,
}

/// Attributes of a `@block`.
#[derive(Clone, Debug, Default)]
pub struct GroupAttrs {
    pub align: Option<Align>,
    pub indent: Option<i64>,
    pub right_indent: Option<i64>,
    pub font: Option<Family>,
    pub size: Option<i64>,
    pub leading: Option<i64>,
}

/// One item of a list.
#[derive(Clone, Debug)]
pub struct ListItem {
    pub text: Vec<Inline>,
    pub blocks: Vec<Block>,
}

/// A table row or rule.
#[derive(Clone, Debug)]
pub enum TableElem {
    Row(Vec<Vec<Inline>>),
    HRule,
}

/// A block of the document.
#[derive(Clone, Debug)]
pub enum Block {
    Heading { level: usize, unnumbered: bool, text: Vec<Inline> },
    Paragraph(Vec<Inline>),
    Quote(Vec<Block>),
    Group(GroupAttrs, Vec<Block>),
    List { ordered: bool, start: i64, items: Vec<ListItem> },
    Table { cols: usize, aligns: Vec<Align>, elems: Vec<TableElem> },
    Pre(Vec<String>),
    Figure { height: i64, width: Option<i64>, caption: Vec<Inline> },
    Rule,
    VSpace(i64),
    NewPage,
}

/// The `@toc` block.
#[derive(Clone, Debug)]
pub struct TocSpec {
    /// The `title` attribute, used literally, if given.
    pub title: Option<String>,
}

/// A parsed document.
#[derive(Clone, Debug, Default)]
pub struct Document {
    pub meta: Meta,
    pub toc: Option<TocSpec>,
    pub blocks: Vec<Block>,
}
