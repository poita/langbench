/// Block-level syntax tree: node kinds and the `Document` container.
module commonmark.ast;

/// The kinds of block nodes.
enum BlockKind : ubyte
{
    document,
    blockQuote,
    list,
    item,
    paragraph,
    heading,
    thematicBreak,
    indentedCode,
    fencedCode,
}

/// One block node. Blocks live in `Document.blocks` and refer to each other
/// by index; index 0 is the document root and also serves as "none" in the
/// child/sibling links.
struct Block
{
    BlockKind kind;
    /// Still accepting lines (only meaningful while parsing).
    bool open = true;
    /// Whether the last line of this block was blank (list tightness).
    bool lastLineBlank;
    /// Memo flag for the tightness computation.
    bool lastLineChecked;
    /// List: ordered list?
    bool ordered;
    /// List: tight (items rendered without paragraph tags)?
    bool tight = true;
    /// List: bullet character or ordered delimiter (`.` / `)`).
    char marker;
    /// Heading level (1-6).
    ubyte level;
    /// Fenced code: fence character.
    char fenceChar;
    /// Fenced code: fence length.
    int fenceLength;
    /// Fenced code: indentation of the opening fence.
    int fenceOffset;
    /// List item: indentation of the marker.
    int markerOffset;
    /// List item: columns needed to continue the item.
    int padding;
    /// Ordered list: start number.
    int start;
    /// 1-based number of the line on which the block started.
    int line;
    /// Tree links; 0 means "none".
    int parent, firstChild, lastChild, next, prev;
    /// Raw text of paragraphs, headings and code blocks.
    char[] content;
    /// Fenced code: decoded info string.
    string info;
}

/// The result of parsing the block structure of a document.
struct Document
{
    /// All blocks; `blocks[0]` is the document.
    Block[] blocks;
}
