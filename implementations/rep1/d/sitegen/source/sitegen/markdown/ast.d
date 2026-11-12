/**
 * Node types shared by the block parser, the inline parser and the HTML
 * renderer of the Markdown converter.
 *
 * The converter works in two phases, as in the CommonMark reference
 * implementation: phase 1 builds a tree of $(LREF Block)s line by line, phase 2
 * parses the raw text of paragraphs and headings into a list of $(LREF Inline)
 * nodes.
 */
module sitegen.markdown.ast;

import std.array : Appender;

/// The kinds of block node.
enum BlockKind : ubyte
{
    document,
    blockQuote,
    list,
    item,
    paragraph,
    heading,
    thematicBreak,
    codeBlock,
}

/// A node of the block tree.
final class Block
{
    BlockKind kind;
    Block parent;
    Block[] children;

    /// True until the block is closed ("finalized").
    bool open = true;
    /// Bookkeeping for list tightness (see the block parser).
    bool lastLineBlank;
    bool lastLineChecked;
    /// 1-based number of the line on which the block started.
    size_t startLine;

    /// Raw text accumulated by paragraphs, headings and code blocks.
    Appender!(char[]) content;

    // --- list and list item data ---
    bool ordered;
    /// The bullet character for bullet lists, `.` or `)` for ordered lists.
    char delimiter;
    /// The start number of an ordered list.
    int start;
    bool tight;
    int markerOffset;
    int padding;

    // --- heading data ---
    int level;
    bool setext;

    // --- code block data ---
    bool fenced;
    char fenceChar;
    int fenceLength;
    int fenceOffset;
    string info;

    /// The inline content of a paragraph or heading (phase 2).
    Inline inlines;

    this(BlockKind kind, size_t startLine)
    {
        this.kind = kind;
        this.startLine = startLine;
    }

    /// The last child, or `null`.
    @property Block lastChild() pure nothrow @nogc
    {
        return children.length ? children[$ - 1] : null;
    }
}

/// The kinds of inline node.
enum InlineKind : ubyte
{
    text,
    softbreak,
    linebreak,
    code,
    emph,
    strong,
    link,
    image,
}

/// A node of the inline list.  Siblings form a doubly linked list so that
/// wrapping and removing runs of nodes costs O(1).
final class Inline
{
    InlineKind kind;
    /// Text of `text` and `code` nodes.
    string text;
    Inline prev, next;
    Inline firstChild, lastChild;
    /// Destination and title of `link` and `image` nodes.
    string dest;
    string title;
    bool hasTitle;

    this(InlineKind kind, string text = null)
    {
        this.kind = kind;
        this.text = text;
    }
}
