/// Static analysis of a syntax tree used to speed up the search for a start position.
module regex.analysis;

import regex.ast;
import regex.charset;

/**
 * True if every match must begin with `^` (so only start position 0 can
 * succeed). Conservative: `false` means "unknown".
 */
bool isAnchored(const Node n) pure nothrow @safe
{
    final switch (n.kind)
    {
    case NodeKind.bol:
        return true;
    case NodeKind.literal, NodeKind.any, NodeKind.set, NodeKind.eol:
        return false;
    case NodeKind.seq:
        return n.children.length > 0 && isAnchored(n.children[0]);
    case NodeKind.alt:
        foreach (c; n.children)
            if (!isAnchored(c))
                return false;
        return true;
    case NodeKind.group:
        return isAnchored(n.children[0]);
    case NodeKind.repeat:
        return n.min >= 1 && n.max != 0 && isAnchored(n.children[0]);
    }
}

/**
 * Adds to `acc` every character that a match of `n` can begin with and
 * returns whether `n` can match without consuming anything.
 *
 * The result is a superset: it is safe to skip start positions whose
 * character is not in `acc` when the whole pattern is not nullable.
 */
bool firstChars(const Node n, ref CharSet acc) pure nothrow @safe
{
    final switch (n.kind)
    {
    case NodeKind.literal:
        acc.add(n.ch);
        return false;
    case NodeKind.any:
        acc = CharSet.full();
        return false;
    case NodeKind.set:
        acc.addSet(n.set);
        return false;
    case NodeKind.bol, NodeKind.eol:
        return true;
    case NodeKind.seq:
        foreach (c; n.children)
            if (!firstChars(c, acc))
                return false;
        return true;
    case NodeKind.alt:
        bool nullable = false;
        foreach (c; n.children)
            if (firstChars(c, acc))
                nullable = true;
        return nullable;
    case NodeKind.group:
        return firstChars(n.children[0], acc);
    case NodeKind.repeat:
        if (n.max == 0)
            return true;
        const bodyNullable = firstChars(n.children[0], acc);
        return bodyNullable || n.min == 0;
    }
}

/// True if `n` can match the empty string (decided statically, conservatively true).
bool canBeEmpty(const Node n) pure nothrow @safe
{
    final switch (n.kind)
    {
    case NodeKind.literal, NodeKind.any, NodeKind.set:
        return false;
    case NodeKind.bol, NodeKind.eol:
        return true;
    case NodeKind.seq:
        foreach (c; n.children)
            if (!canBeEmpty(c))
                return false;
        return true;
    case NodeKind.alt:
        foreach (c; n.children)
            if (canBeEmpty(c))
                return true;
        return false;
    case NodeKind.group:
        return canBeEmpty(n.children[0]);
    case NodeKind.repeat:
        return n.min == 0 || n.max == 0 || canBeEmpty(n.children[0]);
    }
}
