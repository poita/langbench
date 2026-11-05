/// Recursive-descent parser for the supported pattern syntax.
module regex.parser;

import regex.ast;
import regex.charset;
import regex.exception;

/// Result of parsing a pattern.
struct Parsed
{
    Node root; /// root of the syntax tree
    int groupCount; /// number of capturing groups
}

/// Parse `pattern` into a syntax tree. Throws `RegexException` on invalid syntax.
Parsed parse(const(char)[] pattern) @safe
{
    auto p = Parser(pattern);
    auto root = p.parseAlt();
    if (p.pos != pattern.length)
        throw p.error("unmatched ')'");
    return Parsed(root, p.groups);
}

private struct Parser
{
    const(char)[] src;
    size_t pos;
    int groups;

    RegexException error(string msg) const @safe
    {
        return new RegexException(msg, pos);
    }

    bool atEnd() const @safe pure nothrow @nogc
    {
        return pos >= src.length;
    }

    char peek() const @safe pure nothrow @nogc
    {
        return src[pos];
    }

    Node parseAlt() @safe
    {
        Node[] branches = [parseSeq()];
        while (!atEnd && peek == '|')
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
        while (!atEnd && peek != '|' && peek != ')')
            n.children ~= parsePiece();
        return n;
    }

    Node parsePiece() @safe
    {
        auto atom = parseAtom();
        if (atEnd)
            return atom;
        int lo, hi;
        switch (peek)
        {
        case '*':
            ++pos;
            lo = 0;
            hi = unbounded;
            break;
        case '+':
            ++pos;
            lo = 1;
            hi = unbounded;
            break;
        case '?':
            ++pos;
            lo = 0;
            hi = 1;
            break;
        case '{':
            parseBraces(lo, hi);
            break;
        default:
            return atom;
        }
        if (atom.kind == NodeKind.bol || atom.kind == NodeKind.eol)
            throw error("quantifier after anchor");
        auto r = new Node(NodeKind.repeat);
        r.children = [atom];
        r.min = lo;
        r.max = hi;
        return r;
    }

    int parseInt() @safe
    {
        if (atEnd || peek < '0' || peek > '9')
            throw error("number expected");
        int v = 0;
        while (!atEnd && peek >= '0' && peek <= '9')
        {
            v = v * 10 + (peek - '0');
            if (v > 100_000)
                throw error("repetition count too large");
            ++pos;
        }
        return v;
    }

    /// Parses `{n}`, `{n,}` or `{n,m}` with `pos` at the `{`.
    void parseBraces(out int lo, out int hi) @safe
    {
        ++pos; // '{'
        lo = parseInt();
        hi = lo;
        if (!atEnd && peek == ',')
        {
            ++pos;
            hi = (!atEnd && peek == '}') ? unbounded : parseInt();
        }
        if (atEnd || peek != '}')
            throw error("'}' expected");
        ++pos;
        if (hi != unbounded && hi < lo)
            throw error("bad repetition range");
    }

    Node parseAtom() @safe
    {
        const c = peek;
        switch (c)
        {
        case '.':
            ++pos;
            return new Node(NodeKind.any);
        case '^':
            ++pos;
            return new Node(NodeKind.bol);
        case '$':
            ++pos;
            return new Node(NodeKind.eol);
        case '[':
            return parseClass();
        case '\\':
            return parseEscape();
        case '(':
            {
                ++pos;
                auto g = new Node(NodeKind.group);
                g.groupIndex = ++groups;
                g.children = [parseAlt()];
                if (atEnd || peek != ')')
                    throw error("')' expected");
                ++pos;
                return g;
            }
        case '*', '+', '?', '{':
            throw error("nothing to repeat");
        case ']', '}':
            throw error("unexpected character");
        default:
            ++pos;
            auto n = new Node(NodeKind.literal);
            n.ch = cast(ubyte) c;
            return n;
        }
    }

    static bool isAlnum(char c) @safe pure nothrow @nogc
    {
        return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
    }

    /// If `c` names a set escape (`dDwWsS`), store its set and return true.
    static bool setEscape(char c, out CharSet s) @safe pure nothrow @nogc
    {
        switch (c)
        {
        case 'd':
            s = CharSet.digits();
            return true;
        case 'w':
            s = CharSet.word();
            return true;
        case 's':
            s = CharSet.space();
            return true;
        case 'D':
            s = CharSet.digits();
            s.invert();
            return true;
        case 'W':
            s = CharSet.word();
            s.invert();
            return true;
        case 'S':
            s = CharSet.space();
            s.invert();
            return true;
        default:
            return false;
        }
    }

    Node parseEscape() @safe
    {
        ++pos; // '\'
        if (atEnd)
            throw error("trailing backslash");
        const c = peek;
        ++pos;
        CharSet s;
        if (setEscape(c, s))
        {
            auto n = new Node(NodeKind.set);
            n.set = s;
            return n;
        }
        if (isAlnum(c))
            throw error("unknown escape");
        auto n = new Node(NodeKind.literal);
        n.ch = cast(ubyte) c;
        return n;
    }

    /// Reads one single character inside a class (plain or escaped).
    ubyte classChar() @safe
    {
        if (atEnd)
            throw error("unterminated class");
        char c = peek;
        ++pos;
        if (c == '\\')
        {
            if (atEnd)
                throw error("unterminated class");
            c = peek;
            ++pos;
            if (isAlnum(c))
                throw error("unknown escape in class");
        }
        return cast(ubyte) c;
    }

    Node parseClass() @safe
    {
        ++pos; // '['
        bool negate = false;
        if (!atEnd && peek == '^')
        {
            negate = true;
            ++pos;
        }
        CharSet set;
        bool any = false;
        for (;;)
        {
            if (atEnd)
                throw error("unterminated class");
            if (peek == ']' && any)
            {
                ++pos;
                break;
            }
            any = true;
            CharSet esc;
            if (peek == '\\' && pos + 1 < src.length && setEscape(src[pos + 1], esc))
            {
                pos += 2;
                set.unite(esc);
                continue;
            }
            const lo = classChar();
            if (pos + 1 < src.length && peek == '-' && src[pos + 1] != ']')
            {
                ++pos;
                const hi = classChar();
                if (hi < lo)
                    throw error("bad range in class");
                set.addRange(lo, hi);
            }
            else
                set.add(lo);
        }
        if (negate)
            set.invert();
        auto n = new Node(NodeKind.set);
        n.set = set;
        return n;
    }
}
