/// Syntax tree produced by the parser.
module regex.ast;

import regex.charset;

/// Kind of a syntax-tree node.
enum NodeKind : ubyte
{
    literal, /// one specific character (`ch`)
    any,     /// `.`
    set,     /// character class or set escape (`set`)
    bol,     /// `^`
    eol,     /// `$`
    seq,     /// concatenation of `children` (possibly none)
    alt,     /// ordered choice between `children` (at least two)
    group,   /// capturing group number `group` around `children[0]`
    repeat,  /// `children[0]` repeated `min` .. `max` times (`max < 0`: unbounded)
}

/// A node of the pattern syntax tree.
final class Node
{
    NodeKind kind;
    ubyte ch;           /// for `literal`
    CharSet set;        /// for `set`
    Node[] children;    /// for `seq`, `alt`, `group`, `repeat`
    int group;          /// for `group`: 1-based group number
    int min;            /// for `repeat`
    int max;            /// for `repeat`; negative means unbounded

    this(NodeKind kind) pure nothrow @safe
    {
        this.kind = kind;
    }

    /// True for nodes that consume exactly one character and hold no group.
    bool isSingleChar() const pure nothrow @nogc @safe
    {
        return kind == NodeKind.literal || kind == NodeKind.any || kind == NodeKind.set;
    }
}

/// Result of parsing: the tree and the number of capture groups.
struct ParsedPattern
{
    Node root;
    int groupCount;
}
