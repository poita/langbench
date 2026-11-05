/// Tree nodes shared by the Markdown block parser, inline parser and renderer.
module sitegen.markdown.node;

/// What a `Node` is. Block kinds come first, then inline kinds.
enum NodeKind : ubyte
{
    document,
    blockQuote,
    list,
    item,
    paragraph,
    heading,
    thematicBreak,
    codeBlock,
    // inlines
    text,
    softBreak,
    lineBreak,
    code,
    emph,
    strong,
    link,
    image,
}

/// One node of the document tree.
///
/// Blocks and inlines live in one tree; children form a doubly linked sibling
/// list so that re-parenting a run of nodes costs O(1) per node.
final class Node
{
    NodeKind kind;
    Node parent, firstChild, lastChild, prev, next;

    // ---- block state -------------------------------------------------
    bool open = true;
    bool lastLineBlank;
    bool lastLineChecked;
    int startLine;
    /// Raw text of a leaf block (paragraph, heading, code block).
    char[] content;

    // heading
    int level;
    bool setext;

    // list / list item
    bool ordered;
    char delimiter; // bullet character, or '.' / ')' for ordered lists
    int start;
    bool tight;
    int markerOffset;
    int padding;

    // code block
    bool fenced;
    char fenceChar;
    int fenceLength;
    int fenceOffset;
    string info;

    // ---- inline data -------------------------------------------------
    /// Text of a text/code node.
    string literal;
    /// Destination and title of a link or image.
    string url;
    string title;
    bool hasTitle;

    this(NodeKind kind) pure nothrow @safe
    {
        this.kind = kind;
    }

    /// Append `child` as the last child.
    void appendChild(Node child) pure nothrow @safe
    {
        child.parent = this;
        child.next = null;
        child.prev = lastChild;
        if (lastChild !is null)
            lastChild.next = child;
        else
            firstChild = child;
        lastChild = child;
    }

    /// Detach this node from its parent and siblings.
    void unlink() pure nothrow @safe
    {
        if (prev !is null)
            prev.next = next;
        else if (parent !is null)
            parent.firstChild = next;
        if (next !is null)
            next.prev = prev;
        else if (parent !is null)
            parent.lastChild = prev;
        parent = null;
        prev = null;
        next = null;
    }

    /// Insert this (detached) node immediately after `sibling`.
    void insertAfter(Node sibling) pure nothrow @safe
    {
        parent = sibling.parent;
        prev = sibling;
        next = sibling.next;
        if (sibling.next !is null)
            sibling.next.prev = this;
        else if (parent !is null)
            parent.lastChild = this;
        sibling.next = this;
    }
}
