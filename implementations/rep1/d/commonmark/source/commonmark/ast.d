/**
 * Block-level syntax tree produced by `commonmark.block.parseBlocks`.
 *
 * The tree consists of `Block` nodes. Containers (document, block quote, list,
 * list item) own child blocks; leaves (paragraph, heading, thematic break,
 * code block) carry text. Inline content is not part of this tree: the raw text
 * of paragraphs and headings is parsed lazily by `commonmark.inline`.
 */
module commonmark.ast;

/// The kinds of block nodes.
enum BlockKind : ubyte
{
    /// The root of every tree.
    document,
    /// A `>` block quote.
    blockQuote,
    /// A bullet or ordered list; contains only `item` blocks.
    list,
    /// A list item.
    item,
    /// A paragraph; `Block.text` is its raw inline content.
    paragraph,
    /// An ATX or setext heading; `Block.text` is its raw inline content.
    heading,
    /// A thematic break (`***`, `---`, `___`).
    thematicBreak,
    /// An indented or fenced code block; `Block.text` is the literal content.
    codeBlock,
}

/// A node of the block tree. Children are linked as a doubly linked list.
final class Block
{
    /// What kind of block this is.
    BlockKind kind;
    /// Parent block, or `null` for the document.
    Block parent;
    /// First and last child (containers only).
    Block firstChild, lastChild;
    /// Previous and next sibling.
    Block prev, next;

    /// Leaf content: raw inline text (paragraph, heading) or literal code.
    string text;

    // --- list and item data ---
    /// List: true for an ordered list.
    bool ordered;
    /// List/item: the bullet character, or `.` / `)` for ordered lists.
    char delimiter;
    /// List: the start number of an ordered list.
    int start = 1;
    /// List: true if the list is tight (no blank lines between its blocks).
    bool tight;
    /// Item: indentation of the marker.
    int markerOffset;
    /// Item: columns from the marker offset to the item's content.
    int padding;

    // --- heading data ---
    /// Heading level (1 to 6).
    int level;

    // --- code block data ---
    /// True for a fenced code block.
    bool fenced;
    /// Fenced code: the info string, with entities and escapes decoded.
    string info;

    // --- parser bookkeeping (not meaningful once parsing is done) ---
    package bool open = true;
    package bool lastLineBlank;
    package bool lastLineChecked;
    package bool setext;
    package int startLine;
    package char fenceChar;
    package int fenceLength;
    package int fenceOffset;
    package char[] buf;

    /// Creates a block of the given kind.
    this(BlockKind kind) @safe pure nothrow
    {
        this.kind = kind;
    }

    /// Appends `child` as the last child of this block.
    package void appendChild(Block child) @safe pure nothrow @nogc
    {
        child.parent = this;
        child.prev = lastChild;
        child.next = null;
        if (lastChild !is null)
            lastChild.next = child;
        else
            firstChild = child;
        lastChild = child;
    }
}
