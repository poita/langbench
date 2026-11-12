/**
 * Syntax tree produced by the parser and consumed by the compiler.
 */
module regex.ast;

import regex.charset;

/// The kinds of syntax-tree node.
enum NodeKind : ubyte
{
    literal, /// a single byte, `ch`
    any,     /// `.`
    set,     /// a character class or set escape, `set`
    bol,     /// `^`
    eol,     /// `$`
    seq,     /// concatenation of `children`
    alt,     /// ordered choice between `children`
    group,   /// capturing group number `group` around `children[0]`
    repeat,  /// `children[0]` repeated `min .. max` times (greedy)
}

/// Value of `Node.max` meaning "no upper bound".
enum unbounded = -1;

/// One node of the syntax tree.
final class Node
{
    NodeKind kind;
    ubyte ch;           /// for `literal`
    CharSet set;        /// for `set`
    int group;          /// for `group`: 1-based group number
    int min, max;       /// for `repeat`; `max == unbounded` for no limit
    Node[] children;

    this(NodeKind kind) pure nothrow @safe
    {
        this.kind = kind;
    }

    /// True if the node can match without consuming any character.
    bool nullable() const pure nothrow @safe
    {
        final switch (kind)
        {
        case NodeKind.literal:
        case NodeKind.any:
        case NodeKind.set:
            return false;
        case NodeKind.bol:
        case NodeKind.eol:
            return true;
        case NodeKind.seq:
            foreach (c; children)
                if (!c.nullable)
                    return false;
            return true;
        case NodeKind.alt:
            foreach (c; children)
                if (c.nullable)
                    return true;
            return false;
        case NodeKind.group:
            return children[0].nullable;
        case NodeKind.repeat:
            return min == 0 || children[0].nullable;
        }
    }

    /**
     * Adds to `into` every byte that can be the first character consumed by a
     * successful match of this node. Returns true if the node is nullable
     * (so what follows it also contributes first characters).
     */
    bool collectFirst(ref CharSet into) const pure nothrow @safe
    {
        final switch (kind)
        {
        case NodeKind.literal:
            into.add(ch);
            return false;
        case NodeKind.any:
            into.addSet(CharSet.all());
            return false;
        case NodeKind.set:
            into.addSet(set);
            return false;
        case NodeKind.bol:
        case NodeKind.eol:
            return true;
        case NodeKind.seq:
            foreach (c; children)
                if (!c.collectFirst(into))
                    return false;
            return true;
        case NodeKind.alt:
            bool nullable = false;
            foreach (c; children)
                nullable |= c.collectFirst(into);
            return nullable;
        case NodeKind.group:
            return children[0].collectFirst(into);
        case NodeKind.repeat:
            if (max == 0)
                return true;
            return children[0].collectFirst(into) || min == 0;
        }
    }

    /**
     * True if every successful match of this node must begin at subject
     * position 0 (i.e. an unconditional `^` precedes any consumption).
     */
    bool anchoredAtStart() const pure nothrow @safe
    {
        final switch (kind)
        {
        case NodeKind.bol:
            return true;
        case NodeKind.literal:
        case NodeKind.any:
        case NodeKind.set:
        case NodeKind.eol:
            return false;
        case NodeKind.seq:
            foreach (c; children)
                if (c.anchoredAtStart)
                    return true;
            return false;
        case NodeKind.alt:
            foreach (c; children)
                if (!c.anchoredAtStart)
                    return false;
            return children.length > 0;
        case NodeKind.group:
            return children[0].anchoredAtStart;
        case NodeKind.repeat:
            return min >= 1 && children[0].anchoredAtStart;
        }
    }
}
