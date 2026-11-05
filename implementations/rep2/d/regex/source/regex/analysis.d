/// Static analysis of syntax trees: nullability, anchoring and first-character sets.
module regex.analysis;

import regex.ast;
import regex.charset;

/// Whether `n` can match without consuming any character.
bool nullable(Node n) @safe
{
    if (n.nullableCache >= 0)
        return n.nullableCache != 0;
    CharSet ignored;
    return firstSet(n, ignored);
}

/++
    Adds to `set` every character that can begin a non-empty match of `n`,
    and returns whether `n` is nullable (can match the empty string).
+/
bool firstSet(Node n, ref CharSet set) @safe
{
    bool result;
    final switch (n.kind)
    {
    case NodeKind.literal:
        set.add(n.ch);
        result = false;
        break;
    case NodeKind.any:
        set.unite(CharSet.all());
        result = false;
        break;
    case NodeKind.set:
        set.unite(n.set);
        result = false;
        break;
    case NodeKind.bol, NodeKind.eol:
        result = true;
        break;
    case NodeKind.seq:
        result = true;
        foreach (c; n.children)
            if (!firstSet(c, set))
            {
                result = false;
                break;
            }
        break;
    case NodeKind.alt:
        result = false;
        foreach (c; n.children)
            if (firstSet(c, set))
                result = true;
        break;
    case NodeKind.group:
        result = firstSet(n.children[0], set);
        break;
    case NodeKind.repeat:
        if (n.max == 0)
            result = true;
        else
        {
            const inner = firstSet(n.children[0], set);
            result = inner || n.min == 0;
        }
        break;
    }
    n.nullableCache = result ? 1 : 0;
    return result;
}

/// Whether every match of `n` must begin with `^` (so only start 0 can match).
bool anchoredAtStart(Node n) @safe
{
    final switch (n.kind)
    {
    case NodeKind.bol:
        return true;
    case NodeKind.literal, NodeKind.any, NodeKind.set, NodeKind.eol:
        return false;
    case NodeKind.seq:
        return n.children.length > 0 && anchoredAtStart(n.children[0]);
    case NodeKind.alt:
        foreach (c; n.children)
            if (!anchoredAtStart(c))
                return false;
        return true;
    case NodeKind.group:
        return anchoredAtStart(n.children[0]);
    case NodeKind.repeat:
        return n.min >= 1 && n.max != 0 && anchoredAtStart(n.children[0]);
    }
}
