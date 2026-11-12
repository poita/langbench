/// Recursive-descent parser for the supported pattern syntax.
module btregex.parser;

import btregex.ast;
import btregex.charset;

/// Thrown when a pattern is not syntactically valid.
class RegexException : Exception
{
    /// Offset in the pattern where the problem was detected.
    size_t position;

    this(string msg, size_t position, string file = __FILE__, size_t line = __LINE__) pure @safe
    {
        super(msg, file, line);
        this.position = position;
    }
}

/// Result of parsing a pattern.
struct ParseResult
{
    Node root; /// root of the syntax tree
    int groupCount; /// number of capturing groups
}

/// Largest repeat count accepted in `{n,m}`.
enum int maxRepeat = 100_000;

/// Parses `pattern` into a syntax tree. Throws `RegexException` on bad syntax.
ParseResult parse(const(char)[] pattern) @safe
{
    auto p = Parser(pattern);
    auto root = p.parseAlt();
    if (p.pos != pattern.length)
        throw new RegexException("unmatched ')'", p.pos);
    return ParseResult(root, p.groups);
}

private struct Parser
{
    const(char)[] src;
    size_t pos;
    int groups;

    this(const(char)[] s) @safe
    {
        src = s;
    }

    bool atEnd() const pure nothrow @nogc @safe
    {
        return pos >= src.length;
    }

    char peek() const pure nothrow @nogc @safe
    {
        return src[pos];
    }

    Node parseAlt() @safe
    {
        Node[] branches = [parseSeq()];
        while (!atEnd && peek == '|')
        {
            pos++;
            branches ~= parseSeq();
        }
        if (branches.length == 1)
            return branches[0];
        auto n = new Node(NodeKind.alt);
        n.kids = branches;
        return n;
    }

    Node parseSeq() @safe
    {
        auto n = new Node(NodeKind.seq);
        while (!atEnd && peek != '|' && peek != ')')
            n.kids ~= parsePiece();
        return n;
    }

    Node parsePiece() @safe
    {
        auto atom = parseAtom();
        if (atEnd)
            return atom;
        int mn, mx;
        switch (peek)
        {
        case '*':
            pos++;
            mn = 0;
            mx = unbounded;
            break;
        case '+':
            pos++;
            mn = 1;
            mx = unbounded;
            break;
        case '?':
            pos++;
            mn = 0;
            mx = 1;
            break;
        case '{':
            parseBraces(mn, mx);
            break;
        default:
            return atom;
        }
        auto r = new Node(NodeKind.repeat);
        r.kids = [atom];
        r.min = mn;
        r.max = mx;
        return r;
    }

    int parseNumber() @safe
    {
        const start = pos;
        long v = 0;
        while (!atEnd && peek >= '0' && peek <= '9')
        {
            v = v * 10 + (peek - '0');
            if (v > maxRepeat)
                throw new RegexException("repeat count too large", start);
            pos++;
        }
        if (pos == start)
            throw new RegexException("expected a number", pos);
        return cast(int) v;
    }

    void parseBraces(out int mn, out int mx) @safe
    {
        pos++; // '{'
        mn = parseNumber();
        mx = mn;
        if (!atEnd && peek == ',')
        {
            pos++;
            if (!atEnd && peek == '}')
                mx = unbounded;
            else
                mx = parseNumber();
        }
        if (atEnd || peek != '}')
            throw new RegexException("unterminated '{'", pos);
        pos++;
        if (mx != unbounded && mx < mn)
            throw new RegexException("bad repeat range", pos);
    }

    Node parseAtom() @safe
    {
        const c = peek;
        switch (c)
        {
        case '(':
            {
                pos++;
                auto g = new Node(NodeKind.group);
                g.group = ++groups;
                g.kids = [parseAlt()];
                if (atEnd || peek != ')')
                    throw new RegexException("unmatched '('", pos);
                pos++;
                return g;
            }
        case '.':
            pos++;
            return new Node(NodeKind.any);
        case '^':
            pos++;
            return new Node(NodeKind.bol);
        case '$':
            pos++;
            return new Node(NodeKind.eol);
        case '[':
            return parseClass();
        case '\\':
            return parseEscape();
        case '*', '+', '?', '{', '}', ']':
            throw new RegexException("unexpected '" ~ c ~ "'", pos);
        default:
            pos++;
            return literal(c);
        }
    }

    static Node literal(char c) pure nothrow @safe
    {
        auto n = new Node(NodeKind.literal);
        n.ch = cast(ubyte) c;
        return n;
    }

    static bool isAlnum(char c) pure nothrow @nogc @safe
    {
        return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
    }

    /// If `c` is a set-escape letter (d D w W s S), returns the set via `s`.
    static bool setEscape(char c, out CharSet s) pure nothrow @nogc @safe
    {
        switch (c)
        {
        case 'd', 'D':
            s = CharSet.digits();
            break;
        case 'w', 'W':
            s = CharSet.word();
            break;
        case 's', 'S':
            s = CharSet.space();
            break;
        default:
            return false;
        }
        if (c == 'D' || c == 'W' || c == 'S')
            s.invert();
        return true;
    }

    Node parseEscape() @safe
    {
        pos++; // '\'
        if (atEnd)
            throw new RegexException("trailing backslash", pos);
        const c = peek;
        pos++;
        CharSet s;
        if (setEscape(c, s))
        {
            auto n = new Node(NodeKind.set);
            n.set = s;
            return n;
        }
        if (isAlnum(c))
            throw new RegexException("unsupported escape", pos - 1);
        return literal(c);
    }

    /// Parses one single character inside a class (handles `\x`).
    ubyte classChar() @safe
    {
        if (atEnd)
            throw new RegexException("unterminated class", pos);
        char c = peek;
        pos++;
        if (c == '\\')
        {
            if (atEnd)
                throw new RegexException("unterminated class", pos);
            c = peek;
            pos++;
            if (isAlnum(c))
                throw new RegexException("unsupported escape in class", pos - 1);
        }
        return cast(ubyte) c;
    }

    Node parseClass() @safe
    {
        pos++; // '['
        bool negate = false;
        if (!atEnd && peek == '^')
        {
            negate = true;
            pos++;
        }
        CharSet set;
        bool first = true;
        while (true)
        {
            if (atEnd)
                throw new RegexException("unterminated class", pos);
            if (peek == ']' && !first)
                break;
            first = false;
            CharSet esc;
            if (peek == '\\' && pos + 1 < src.length && setEscape(src[pos + 1], esc))
            {
                pos += 2;
                set.addAll(esc);
                continue;
            }
            const lo = classChar();
            if (pos + 1 < src.length && peek == '-' && src[pos + 1] != ']')
            {
                pos++;
                const hi = classChar();
                if (hi < lo)
                    throw new RegexException("bad class range", pos);
                set.addRange(lo, hi);
            }
            else
                set.add(lo);
        }
        pos++; // ']'
        if (negate)
            set.invert();
        auto n = new Node(NodeKind.set);
        n.set = set;
        return n;
    }
}

unittest
{
    import std.exception : assertThrown;

    auto r = parse("(a|b)+c{2,3}");
    assert(r.groupCount == 1);
    assert(r.root.kind == NodeKind.seq && r.root.kids.length == 2);
    assert(r.root.kids[0].kind == NodeKind.repeat);
    assert(r.root.kids[1].min == 2 && r.root.kids[1].max == 3);

    assert(parse("").root.kids.length == 0);
    assert(parse("a|").root.kind == NodeKind.alt);
    assert(parse("(()())").groupCount == 3);
    assert(parse("x{2,}").root.kids[0].max == unbounded);

    assertThrown!RegexException(parse("(a"));
    assertThrown!RegexException(parse("a)"));
    assertThrown!RegexException(parse("*a"));
    assertThrown!RegexException(parse("[a"));
    assertThrown!RegexException(parse("a{2"));
    assertThrown!RegexException(parse("a{3,2}"));
    assertThrown!RegexException(parse("\\"));
    assertThrown!RegexException(parse("[z-a]"));
}

unittest
{
    // Class details: leading/trailing '-', escapes, negation, literal '^'.
    auto cls = (string p) => parse(p).root.kids[0].set;
    auto a = cls("[-a]");
    assert(a.has('-') && a.has('a') && !a.has('b'));
    auto b = cls("[a-]");
    assert(b.has('-') && b.has('a'));
    auto c = cls("[a\\-c]");
    assert(c.has('-') && !c.has('b'));
    auto d = cls("[a-c]");
    assert(d.has('b') && !d.has('-'));
    auto e = cls("[^a]");
    assert(!e.has('a') && e.has('b'));
    auto f = cls("[a^]");
    assert(f.has('^'));
    auto g = cls("[\\d\\]x]");
    assert(g.has('7') && g.has(']') && g.has('x') && !g.has('y'));
    auto h = cls("[\\W]");
    assert(h.has('-') && !h.has('a'));
}
