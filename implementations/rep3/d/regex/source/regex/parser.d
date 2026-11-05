/// Recursive-descent parser for the pattern syntax.
module regex.parser;

import regex.ast;
import regex.charset;

/// Thrown for malformed patterns.
class RegexException : Exception
{
    /// Offset in the pattern at which the problem was detected.
    size_t offset;

    this(string msg, size_t offset = 0, string file = __FILE__, size_t line = __LINE__) pure @safe
    {
        super(msg, file, line);
        this.offset = offset;
    }
}

/// Largest repetition count accepted in `{n,m}`.
enum maxRepeatCount = 1000;

/// Largest number of capture groups accepted.
enum maxGroups = 1000;

/**
 * Parses `pattern` into a syntax tree.
 *
 * Throws: `RegexException` if the pattern is not valid.
 */
ParsedPattern parse(const(char)[] pattern) @safe
{
    auto p = Parser(pattern);
    Node root = p.parseAlt();
    if (p.pos != pattern.length)
        throw new RegexException("unmatched ')'", p.pos);
    return ParsedPattern(root, p.groups);
}

private bool isAlnum(char c) pure nothrow @nogc @safe
{
    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
}

private struct Parser
{
    const(char)[] src;
    size_t pos;
    int groups;

    bool atEnd() const pure nothrow @nogc @safe { return pos >= src.length; }

    Node parseAlt() @safe
    {
        Node[] branches = [parseSeq()];
        while (!atEnd && src[pos] == '|')
        {
            ++pos;
            branches ~= parseSeq();
        }
        if (branches.length == 1)
            return branches[0];
        auto n = new Node(NodeKind.alt);
        n.children = branches;
        return n;
    }

    Node parseSeq() @safe
    {
        auto n = new Node(NodeKind.seq);
        while (!atEnd && src[pos] != '|' && src[pos] != ')')
            n.children ~= parsePiece();
        return n;
    }

    Node parsePiece() @safe
    {
        Node atom = parseAtom();
        if (atEnd)
            return atom;
        int lo, hi;
        switch (src[pos])
        {
        case '*': ++pos; lo = 0; hi = -1; break;
        case '+': ++pos; lo = 1; hi = -1; break;
        case '?': ++pos; lo = 0; hi = 1; break;
        case '{': parseBraces(lo, hi); break;
        default: return atom;
        }
        if (atom.kind == NodeKind.bol || atom.kind == NodeKind.eol)
            throw new RegexException("quantifier after anchor", pos);
        auto r = new Node(NodeKind.repeat);
        r.children = [atom];
        r.min = lo;
        r.max = hi;
        if (!atEnd && (src[pos] == '*' || src[pos] == '+' || src[pos] == '?' || src[pos] == '{'))
            throw new RegexException("quantifier after quantifier", pos);
        return r;
    }

    int parseNumber() @safe
    {
        size_t start = pos;
        long v = 0;
        while (!atEnd && src[pos] >= '0' && src[pos] <= '9')
        {
            v = v * 10 + (src[pos] - '0');
            if (v > maxRepeatCount)
                throw new RegexException("repeat count too large", start);
            ++pos;
        }
        if (pos == start)
            throw new RegexException("expected a number", pos);
        return cast(int) v;
    }

    void parseBraces(out int lo, out int hi) @safe
    {
        ++pos; // '{'
        lo = parseNumber();
        hi = lo;
        if (!atEnd && src[pos] == ',')
        {
            ++pos;
            if (!atEnd && src[pos] == '}')
                hi = -1;
            else
                hi = parseNumber();
        }
        if (atEnd || src[pos] != '}')
            throw new RegexException("unterminated '{'", pos);
        ++pos;
        if (hi >= 0 && hi < lo)
            throw new RegexException("bad repeat range", pos);
    }

    Node parseAtom() @safe
    {
        char c = src[pos];
        switch (c)
        {
        case '(':
            {
                ++pos;
                if (groups >= maxGroups)
                    throw new RegexException("too many groups", pos);
                int number = ++groups;
                Node body_ = parseAlt();
                if (atEnd || src[pos] != ')')
                    throw new RegexException("missing ')'", pos);
                ++pos;
                auto g = new Node(NodeKind.group);
                g.group = number;
                g.children = [body_];
                return g;
            }
        case '.': ++pos; return new Node(NodeKind.any);
        case '^': ++pos; return new Node(NodeKind.bol);
        case '$': ++pos; return new Node(NodeKind.eol);
        case '[': ++pos; return parseClass();
        case '\\': ++pos; return parseEscape();
        case '*', '+', '?', '{':
            throw new RegexException("nothing to repeat", pos);
        case ']', '}':
            throw new RegexException("unexpected '" ~ c ~ "'", pos);
        default:
            ++pos;
            return literal(c);
        }
    }

    static Node literal(char c) @safe
    {
        auto n = new Node(NodeKind.literal);
        n.ch = cast(ubyte) c;
        return n;
    }

    /// Returns the set for a set escape letter, or false if `e` is not one.
    static bool setEscape(char e, out CharSet s) pure nothrow @nogc @safe
    {
        switch (e)
        {
        case 'd': s = CharSet.digits(); return true;
        case 'D': s = CharSet.digits(); s.negate(); return true;
        case 'w': s = CharSet.word(); return true;
        case 'W': s = CharSet.word(); s.negate(); return true;
        case 's': s = CharSet.space(); return true;
        case 'S': s = CharSet.space(); s.negate(); return true;
        default: return false;
        }
    }

    Node parseEscape() @safe
    {
        if (atEnd)
            throw new RegexException("trailing backslash", pos);
        char e = src[pos++];
        CharSet s;
        if (setEscape(e, s))
        {
            auto n = new Node(NodeKind.set);
            n.set = s;
            return n;
        }
        if (isAlnum(e))
            throw new RegexException("unsupported escape '\\" ~ e ~ "'", pos - 1);
        return literal(e);
    }

    Node parseClass() @safe
    {
        CharSet set;
        bool negated = false;
        if (!atEnd && src[pos] == '^')
        {
            negated = true;
            ++pos;
        }
        bool first = true;
        for (;;)
        {
            if (atEnd)
                throw new RegexException("unterminated class", pos);
            char c = src[pos];
            if (c == ']')
            {
                if (first)
                    throw new RegexException("empty class", pos);
                ++pos;
                break;
            }
            first = false;
            char lo = classChar(set);
            if (classWasSet)
                continue;
            // Range `lo-hi` unless the '-' is last before ']'.
            if (pos + 1 < src.length && src[pos] == '-' && src[pos + 1] != ']')
            {
                ++pos;
                CharSet dummy;
                char hi = classChar(dummy);
                if (classWasSet)
                    throw new RegexException("set escape as range end", pos);
                if (cast(ubyte) hi < cast(ubyte) lo)
                    throw new RegexException("range out of order", pos);
                set.addRange(cast(ubyte) lo, cast(ubyte) hi);
            }
            else
                set.add(cast(ubyte) lo);
        }
        if (negated)
            set.negate();
        auto n = new Node(NodeKind.set);
        n.set = set;
        return n;
    }

    bool classWasSet;

    /// Reads one class item. If it is a set escape, merges it into `into`,
    /// sets `classWasSet` and returns 0xFF; otherwise returns the character.
    char classChar(ref CharSet into) @safe
    {
        classWasSet = false;
        if (atEnd)
            throw new RegexException("unterminated class", pos);
        char c = src[pos++];
        if (c != '\\')
            return c;
        if (atEnd)
            throw new RegexException("trailing backslash", pos);
        char e = src[pos++];
        CharSet s;
        if (setEscape(e, s))
        {
            into.addSet(s);
            classWasSet = true;
            return 0xFF;
        }
        if (isAlnum(e))
            throw new RegexException("unsupported escape '\\" ~ e ~ "'", pos - 1);
        return e;
    }
}
