/// Syntax tree produced by the parser.
module regex.ast;

import regex.charset;

/// Kinds of syntax tree node.
enum NodeKind : ubyte
{
    literal, /// one specific character (`ch`)
    any, /// `.`
    set, /// character class or set escape (`set`)
    bol, /// `^`
    eol, /// `$`
    seq, /// concatenation of `children`
    alt, /// ordered choice between `children`
    group, /// capturing group `groupIndex` around `children[0]`
    repeat, /// `children[0]` repeated `min .. max` times
}

/// Marks an unbounded upper repetition limit.
enum int unbounded = -1;

/// A node in the syntax tree.
final class Node
{
    NodeKind kind;
    ubyte ch; /// for `literal`
    CharSet set; /// for `set`
    Node[] children;
    int groupIndex; /// 1-based, for `group`
    int min; /// for `repeat`
    int max = unbounded; /// for `repeat`; `unbounded` means no limit

    /// Cached result of `regex.analysis.nullable` (-1 = not yet computed).
    byte nullableCache = -1;

    ///
    this(NodeKind kind) @safe pure nothrow
    {
        this.kind = kind;
    }

    /// Whether the node consumes exactly one character and holds no group.
    bool isSingleChar() const @safe pure nothrow @nogc
    {
        return kind == NodeKind.literal || kind == NodeKind.any || kind == NodeKind.set;
    }

    /// The set of characters a single-character node matches.
    CharSet charSet() const @safe pure nothrow @nogc
    in (isSingleChar)
    {
        final switch (kind)
        {
        case NodeKind.literal:
            return CharSet.single(ch);
        case NodeKind.any:
            return CharSet.all();
        case NodeKind.set:
            return set;
        case NodeKind.bol, NodeKind.eol, NodeKind.seq, NodeKind.alt,
                NodeKind.group, NodeKind.repeat:
            assert(0);
        }
    }
}
