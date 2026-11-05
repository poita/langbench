/// Syntax tree produced by the parser and consumed by the analyser and
/// compiler.
module regexvm.ast;

import regexvm.charset;

/// Node categories.
enum NodeKind : ubyte
{
    literal, /// one specific byte (`ch`)
    any,     /// `.`
    set,     /// character class or set escape (`set`)
    bol,     /// `^`
    eol,     /// `$`
    seq,     /// concatenation of `children` (empty = matches the empty string)
    alt,     /// ordered choice between `children`
    group,   /// capturing group `group` around `children[0]`
    repeat,  /// `children[0]{min,max}`; `max == unbounded` means no upper limit
}

/// Value of `Node.max` for an unbounded repetition.
enum int unbounded = -1;

/// A syntax-tree node.
final class Node
{
    NodeKind kind;
    ubyte ch;            /// literal byte (`literal`)
    CharSet set;         /// members (`set`)
    Node[] children;     /// operands (`seq`, `alt`, `group`, `repeat`)
    int group;           /// 1-based group number (`group`)
    int min;             /// minimum iterations (`repeat`)
    int max;             /// maximum iterations or `unbounded` (`repeat`)

    // Caches filled in lazily by later phases.
    package byte nullableCache;  // 0 unknown, 1 no, 2 yes
    package int setIndex = -1;   // index in the program's class table

    this(NodeKind kind) pure nothrow @safe { this.kind = kind; }

    /// Literal node.
    static Node literal(ubyte c)
    {
        auto n = new Node(NodeKind.literal);
        n.ch = c;
        return n;
    }

    /// Class node.
    static Node classOf(CharSet s)
    {
        auto n = new Node(NodeKind.set);
        n.set = s;
        return n;
    }

    /// Node with children (`seq`, `alt`).
    static Node of(NodeKind kind, Node[] children)
    {
        auto n = new Node(kind);
        n.children = children;
        return n;
    }

    /// Capturing group node.
    static Node capture(int index, Node body_)
    {
        auto n = new Node(NodeKind.group);
        n.group = index;
        n.children = [body_];
        return n;
    }

    /// Repetition node.
    static Node repetition(Node body_, int min, int max)
    {
        auto n = new Node(NodeKind.repeat);
        n.children = [body_];
        n.min = min;
        n.max = max;
        return n;
    }

    /// True for nodes that consume exactly one byte and contain no group.
    bool isSingleChar() const pure nothrow @nogc @safe
    {
        return kind == NodeKind.literal || kind == NodeKind.any || kind == NodeKind.set;
    }
}

/// A parsed pattern.
struct Ast
{
    Node root;       /// the whole pattern
    int groupCount;  /// number of capturing groups
}

/// Renders a tree as a compact S-expression (for tests and debugging).
/// Example: `a(b|c)*` -> `(seq a (rep 0 inf (group 1 (alt (seq b) (seq c)))))`.
string toSExpr(const Node n)
{
    import std.conv : to;
    import std.array : join;
    import std.algorithm : map;
    import std.format : format;

    final switch (n.kind)
    {
    case NodeKind.literal: return [cast(char) n.ch].idup;
    case NodeKind.any: return "any";
    case NodeKind.set: return format("[set:%d]", n.set.count);
    case NodeKind.bol: return "bol";
    case NodeKind.eol: return "eol";
    case NodeKind.seq:
        return n.children.length == 0 ? "(seq)"
            : "(seq " ~ n.children.map!(c => toSExpr(c)).join(" ") ~ ")";
    case NodeKind.alt:
        return "(alt " ~ n.children.map!(c => toSExpr(c)).join(" ") ~ ")";
    case NodeKind.group:
        return format("(group %d %s)", n.group, toSExpr(n.children[0]));
    case NodeKind.repeat:
        return format("(rep %d %s %s)", n.min,
                      n.max == unbounded ? "inf" : n.max.to!string, toSExpr(n.children[0]));
    }
}
