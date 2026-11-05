/// Static analyses over the syntax tree: nullability, start-anchoring and
/// the set of bytes a match can begin with.
module regexvm.analysis;

import regexvm.ast;
import regexvm.charset;

/// True if `n` can match without consuming input (statically decided; a
/// `true` answer is conservative).  `^`, `$`, `x{0}`, `x*`, `x?` and empty
/// branches are nullable.
bool isNullable(Node n)
{
    if (n.nullableCache)
        return n.nullableCache == 2;
    bool r;
    final switch (n.kind)
    {
    case NodeKind.literal, NodeKind.any, NodeKind.set:
        r = false;
        break;
    case NodeKind.bol, NodeKind.eol:
        r = true;
        break;
    case NodeKind.seq:
        r = true;
        foreach (c; n.children)
            if (!isNullable(c)) { r = false; break; }
        break;
    case NodeKind.alt:
        r = false;
        foreach (c; n.children)
            if (isNullable(c)) { r = true; break; }
        break;
    case NodeKind.group:
        r = isNullable(n.children[0]);
        break;
    case NodeKind.repeat:
        r = n.min == 0 || n.max == 0 || isNullable(n.children[0]);
        break;
    }
    n.nullableCache = r ? 2 : 1;
    return r;
}

/// True if every match of `n` must begin with `^` (so only start position 0
/// can succeed): `^` first in a seq, all branches of an alt anchored, a
/// group with an anchored body, a repeat with `min >= 1` and anchored body.
bool isAnchoredAtStart(const Node n)
{
    final switch (n.kind)
    {
    case NodeKind.bol:
        return true;
    case NodeKind.literal, NodeKind.any, NodeKind.set, NodeKind.eol:
        return false;
    case NodeKind.seq:
        return n.children.length > 0 && isAnchoredAtStart(n.children[0]);
    case NodeKind.alt:
        foreach (c; n.children)
            if (!isAnchoredAtStart(c))
                return false;
        return true;
    case NodeKind.group:
        return isAnchoredAtStart(n.children[0]);
    case NodeKind.repeat:
        return n.min >= 1 && n.max != 0 && isAnchoredAtStart(n.children[0]);
    }
}

/// First-byte information for a (sub)pattern.
struct FirstInfo
{
    CharSet set;    /// bytes a non-empty match of the node can begin with
    bool nullable;  /// the node can match the empty string
}

/// Computes the first-byte set and nullability of `n`.
FirstInfo firstInfo(Node n)
{
    FirstInfo r;
    final switch (n.kind)
    {
    case NodeKind.literal:
        r.set.add(n.ch);
        break;
    case NodeKind.any:
        r.set = CharSet.all();
        break;
    case NodeKind.set:
        r.set = n.set;
        break;
    case NodeKind.bol, NodeKind.eol:
        r.nullable = true;
        break;
    case NodeKind.seq:
        r.nullable = true;
        foreach (c; n.children)
        {
            auto f = firstInfo(c);
            r.set.addSet(f.set);
            if (!f.nullable)
            {
                r.nullable = false;
                break;
            }
        }
        break;
    case NodeKind.alt:
        foreach (c; n.children)
        {
            auto f = firstInfo(c);
            r.set.addSet(f.set);
            r.nullable = r.nullable || f.nullable;
        }
        break;
    case NodeKind.group:
        r = firstInfo(n.children[0]);
        break;
    case NodeKind.repeat:
        if (n.max == 0)
        {
            r.nullable = true;  // the body never runs
            break;
        }
        r = firstInfo(n.children[0]);
        r.nullable = r.nullable || n.min == 0;
        break;
    }
    return r;
}
