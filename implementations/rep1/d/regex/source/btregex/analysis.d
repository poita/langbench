/// Static analysis of a syntax tree used to skip hopeless start positions.
module btregex.analysis;

import btregex.ast;
import btregex.charset;

/// What can be said about where a match may start.
struct StartInfo
{
    /// Characters that can be the first character of a match.
    CharSet first;
    /// True if the pattern can match without consuming a character (or
    /// begins with a zero-width assertion); every start position must then
    /// be tried, including the end of the subject.
    bool nullable;
    /// True if every match must start at offset 0.
    bool anchoredStart;
}

/// Computes the `StartInfo` for a tree.
StartInfo analyse(Node root) @safe
{
    StartInfo info;
    info.nullable = collectFirst(root, info.first);
    info.anchoredStart = requiresStart(root);
    return info;
}

/// Adds to `into` every character that may begin a match of `n`; returns
/// whether `n` can match without consuming anything.
private bool collectFirst(Node n, ref CharSet into) @safe
{
    final switch (n.kind)
    {
    case NodeKind.literal:
        into.add(n.ch);
        return false;
    case NodeKind.any:
        foreach (c; 0 .. 256)
            into.add(cast(ubyte) c);
        return false;
    case NodeKind.set:
        into.addAll(n.set);
        return false;
    case NodeKind.bol, NodeKind.eol:
        return true;
    case NodeKind.seq:
        foreach (k; n.kids)
            if (!collectFirst(k, into))
                return false;
        return true;
    case NodeKind.alt:
        bool nullable = false;
        foreach (k; n.kids)
            if (collectFirst(k, into))
                nullable = true;
        return nullable;
    case NodeKind.group:
        return collectFirst(n.kids[0], into);
    case NodeKind.repeat:
        if (n.max == 0)
            return true;
        const inner = collectFirst(n.kids[0], into);
        return inner || n.min == 0;
    }
}

/// True if any match of `n` must be reached with the position at 0, given
/// that nothing has been consumed before `n` is entered.
private bool requiresStart(Node n) @safe
{
    final switch (n.kind)
    {
    case NodeKind.bol:
        return true;
    case NodeKind.literal, NodeKind.any, NodeKind.set, NodeKind.eol:
        return false;
    case NodeKind.seq:
        // If any element demands position 0 then the whole sequence matched
        // starting at 0 (or can never match at all).
        foreach (k; n.kids)
            if (requiresStart(k))
                return true;
        return false;
    case NodeKind.alt:
        foreach (k; n.kids)
            if (!requiresStart(k))
                return false;
        return true;
    case NodeKind.group:
        return requiresStart(n.kids[0]);
    case NodeKind.repeat:
        return n.min >= 1 && requiresStart(n.kids[0]);
    }
}

unittest
{
    import btregex.parser : parse;

    auto info = analyse(parse("ab|[cd]x").root);
    assert(info.first.has('a') && info.first.has('c') && info.first.has('d'));
    assert(!info.first.has('b') && !info.nullable && !info.anchoredStart);

    assert(analyse(parse("a*").root).nullable);
    assert(analyse(parse("^a").root).anchoredStart);
    assert(analyse(parse("(^a|^b)c").root).anchoredStart);
    assert(!analyse(parse("(^a|b)c").root).anchoredStart);
    assert(!analyse(parse("(^a)*").root).anchoredStart);
    assert(analyse(parse("(^a)+").root).anchoredStart);
    assert(analyse(parse("$").root).nullable);
    auto f = analyse(parse("^a?b").root);
    assert(f.first.has('a') && f.first.has('b') && !f.nullable);
    assert(analyse(parse("a{0}b").root).first.has('b'));
}
