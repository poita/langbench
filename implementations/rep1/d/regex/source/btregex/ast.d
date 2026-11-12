/// Syntax tree produced by the parser.
module btregex.ast;

import btregex.charset;

/// Kind of a syntax-tree node.
enum NodeKind : ubyte
{
    literal, /// a single character (`ch`)
    any, /// `.`
    set, /// character class (`set`)
    bol, /// `^`
    eol, /// `$`
    seq, /// concatenation of `kids` (possibly empty)
    alt, /// ordered choice between `kids`
    group, /// capturing group number `group` around `kids[0]`
    repeat, /// `kids[0]` repeated `min .. max` times (`max == unbounded` for no limit)
}

/// Marker for an unbounded repeat count.
enum int unbounded = -1;

/// A node of the pattern syntax tree.
final class Node
{
    NodeKind kind;
    ubyte ch;
    CharSet set;
    Node[] kids;
    int group;
    int min;
    int max;

    this(NodeKind kind) pure nothrow @safe
    {
        this.kind = kind;
    }

    /// True for nodes that always consume exactly one character.
    bool isSingleChar() const pure nothrow @nogc @safe
    {
        return kind == NodeKind.literal || kind == NodeKind.any || kind == NodeKind.set;
    }
}
