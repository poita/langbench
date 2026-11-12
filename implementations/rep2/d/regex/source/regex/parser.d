/**
 * Recursive-descent parser for the supported pattern syntax.
 *
 * Grammar:
 * ---
 * regex      := branch ( '|' branch )*
 * branch     := piece*
 * piece      := atom quantifier?
 * atom       := literal | '.' | '^' | '$' | class | escape | '(' regex ')'
 * quantifier := '*' | '+' | '?' | '{' n '}' | '{' n ',' '}' | '{' n ',' m '}'
 * ---
 */
module regex.parser;

import regex.ast;
import regex.charset;
import regex.exception;

/// Result of parsing a pattern.
struct Parsed
{
    Node root;       /// syntax tree of the whole pattern
    int groupCount;  /// number of capturing groups
}

/// Largest count accepted in a `{n,m}` quantifier.
enum maxRepeat = 100;
/// Largest number of capturing groups accepted in one pattern.
enum maxGroups = 50;

/// Parses `pattern`. Throws `RegexException` if it is not valid.
Parsed parse(const(char)[] pattern) @safe
{
    auto p = Parser(pattern);
    auto root = p.parseRegex();
    if (p.pos != pattern.length)
        throw new RegexException("unmatched ')'", p.pos);
    return Parsed(root, p.groups);
}

private struct Parser
{
    const(char)[] src;
    size_t pos;
    int groups;

    this(const(char)[] s) pure nothrow @safe
    {
        src = s;
    }

    bool atEnd() const pure nothrow @safe
    {
        return pos >= src.length;
    }

    char peek() const pure nothrow @safe
    {
        return src[pos];
    }

    RegexException error(string msg) const pure nothrow @safe
    {
        return new RegexException(msg, pos);
    }

    Node parseRegex() @safe
    {
        Node[] branches = [parseBranch()];
        while (!atEnd && peek == '|')
        {
            pos++;
            branches ~= parseBranch();
        }
        if (branches.length == 1)
            return branches[0];
        auto n = new Node(NodeKind.alt);
        n.children = branches;
        return n;
    }

    Node parseBranch() @safe
    {
        Node[] items;
        while (!atEnd && peek != '|' && peek != ')')
            items ~= parsePiece();
        if (items.length == 1)
            return items[0];
        auto n = new Node(NodeKind.seq);
        n.children = items;
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
        case '*': pos++; lo = 0; hi = unbounded; break;
        case '+': pos++; lo = 1; hi = unbounded; break;
        case '?': pos++; lo = 0; hi = 1; break;
        case '{': parseBraces(lo, hi); break;
        default: return atom;
        }
        if (atom.kind == NodeKind.bol || atom.kind == NodeKind.eol)
            throw error("quantifier after anchor");
        auto r = new Node(NodeKind.repeat);
        r.min = lo;
        r.max = hi;
        r.children = [atom];
        if (!atEnd && (peek == '*' || peek == '+' || peek == '?' || peek == '{'))
            throw error("quantifier follows quantifier");
        return r;
    }

    int parseNumber() @safe
    {
        if (atEnd || peek < '0' || peek > '9')
            throw error("expected a number in quantifier");
        int v = 0;
        while (!atEnd && peek >= '0' && peek <= '9')
        {
            v = v * 10 + (peek - '0');
            if (v > maxRepeat)
                throw error("repeat count too large");
            pos++;
        }
        return v;
    }

    void parseBraces(out int lo, out int hi) @safe
    {
        pos++; // '{'
        lo = parseNumber();
        hi = lo;
        if (!atEnd && peek == ',')
        {
            pos++;
            if (!atEnd && peek == '}')
                hi = unbounded;
            else
                hi = parseNumber();
        }
        if (atEnd || peek != '}')
            throw error("unterminated quantifier");
        pos++;
        if (hi != unbounded && hi < lo)
            throw error("quantifier minimum exceeds maximum");
    }

    Node parseAtom() @safe
    {
        immutable c = peek;
        switch (c)
        {
        case '(':
            return parseGroup();
        case '[':
            return parseClass();
        case '\\':
            return parseEscape();
        case '.':
            pos++;
            return new Node(NodeKind.any);
        case '^':
            pos++;
            return new Node(NodeKind.bol);
        case '$':
            pos++;
            return new Node(NodeKind.eol);
        case '*': case '+': case '?':
            throw error("nothing to repeat");
        case '{': case '}': case ']':
            throw error("unexpected metacharacter");
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

    static Node setNode(CharSet s) pure nothrow @safe
    {
        auto n = new Node(NodeKind.set);
        n.set = s;
        return n;
    }

    Node parseGroup() @safe
    {
        pos++; // '('
        if (groups >= maxGroups)
            throw error("too many groups");
        auto g = new Node(NodeKind.group);
        g.group = ++groups;
        g.children = [parseRegex()];
        if (atEnd || peek != ')')
            throw error("missing ')'");
        pos++;
        return g;
    }

    /// If `c` names a set escape (`dDwWsS`), returns its set via `s`.
    static bool setEscape(char c, out CharSet s) pure nothrow @safe
    {
        switch (c)
        {
        case 'd': s = CharSet.digits(); return true;
        case 'D': s = CharSet.digits().negated(); return true;
        case 'w': s = CharSet.word(); return true;
        case 'W': s = CharSet.word().negated(); return true;
        case 's': s = CharSet.space(); return true;
        case 'S': s = CharSet.space().negated(); return true;
        default: return false;
        }
    }

    static bool isAlnum(char c) pure nothrow @safe
    {
        return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
    }

    Node parseEscape() @safe
    {
        pos++; // '\'
        if (atEnd)
            throw error("trailing backslash");
        immutable c = peek;
        pos++;
        CharSet s;
        if (setEscape(c, s))
            return setNode(s);
        if (isAlnum(c))
            throw error("unsupported escape");
        return literal(c);
    }

    /// Parses one single-character class item (plain or escaped).
    ubyte classChar() @safe
    {
        immutable c = peek;
        pos++;
        if (c != '\\')
            return cast(ubyte) c;
        if (atEnd)
            throw error("trailing backslash");
        immutable e = peek;
        if (isAlnum(e))
            throw error("unsupported escape in class");
        pos++;
        return cast(ubyte) e;
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
        bool any = false;
        while (true)
        {
            if (atEnd)
                throw error("unterminated class");
            if (peek == ']')
            {
                pos++;
                break;
            }
            any = true;
            CharSet esc;
            if (peek == '\\' && pos + 1 < src.length && setEscape(src[pos + 1], esc))
            {
                pos += 2;
                set.addSet(esc);
                continue;
            }
            immutable lo = classChar();
            // `x-y` is a range unless the '-' is the last character before ']'.
            if (pos + 1 < src.length && peek == '-' && src[pos + 1] != ']')
            {
                pos++;
                if (peek == '\\' && pos + 1 < src.length && setEscape(src[pos + 1], esc))
                    throw error("set escape as range end");
                immutable hi = classChar();
                if (hi < lo)
                    throw error("range out of order");
                set.addRange(lo, hi);
            }
            else
                set.add(lo);
        }
        if (!any)
            throw error("empty class");
        return setNode(negate ? set.negated() : set);
    }
}

version (unittest)
{
    private Node p1(string s) @safe
    {
        return parse(s).root;
    }

    private bool fails(string s) @safe
    {
        try
        {
            parse(s);
            return false;
        }
        catch (RegexException)
            return true;
    }
}

unittest
{
    // structure
    auto r = parse("(a|b)c*");
    assert(r.groupCount == 1);
    assert(r.root.kind == NodeKind.seq && r.root.children.length == 2);
    assert(r.root.children[0].kind == NodeKind.group);
    assert(r.root.children[1].kind == NodeKind.repeat);
    assert(r.root.children[1].min == 0 && r.root.children[1].max == unbounded);
    assert(p1("").kind == NodeKind.seq && p1("").children.length == 0);
    assert(p1("a|").kind == NodeKind.alt && p1("a|").children.length == 2);
    assert(parse("()(())").groupCount == 3);
}

unittest
{
    // quantifier forms
    auto n = p1("a{2,5}");
    assert(n.min == 2 && n.max == 5);
    n = p1("a{3}");
    assert(n.min == 3 && n.max == 3);
    n = p1("a{3,}");
    assert(n.min == 3 && n.max == unbounded);
    n = p1("a{0}");
    assert(n.min == 0 && n.max == 0);
    assert(p1("a+").min == 1 && p1("a?").max == 1);
}

unittest
{
    // classes
    auto n = p1("[a-c-]");
    assert(n.set.contains('b') && n.set.contains('-') && !n.set.contains('d'));
    n = p1("[-a]");
    assert(n.set.contains('-') && n.set.contains('a'));
    n = p1("[^a-c]");
    assert(!n.set.contains('a') && n.set.contains('z'));
    n = p1("[\\]\\-x^]");
    assert(n.set.contains(']') && n.set.contains('-') && n.set.contains('^') && n.set.contains('x'));
    n = p1("[\\d_]");
    assert(n.set.contains('7') && n.set.contains('_') && !n.set.contains('a'));
    n = p1("[+--]"); // range '+'..'-'
    assert(n.set.contains(',') && n.set.contains('-'));
    n = p1("[a\\-z]");
    assert(n.set.contains('-') && !n.set.contains('b'));
}

unittest
{
    // escapes
    assert(p1("\\.").kind == NodeKind.literal && p1("\\.").ch == '.');
    assert(p1("\\ ").ch == ' ');
    assert(p1("\\d").set.contains('3'));
    assert(!p1("\\D").set.contains('3') && p1("\\D").set.contains('a'));
    assert(p1("\\s").set.contains(' '));
    assert(p1("\\W").set.contains('-') && !p1("\\W").set.contains('_'));
}

unittest
{
    // invalid patterns are rejected
    assert(fails("("));
    assert(fails("a)"));
    assert(fails("*a"));
    assert(fails("a**"));
    assert(fails("a{2"));
    assert(fails("a{3,2}"));
    assert(fails("a{101}"));
    assert(fails("[a"));
    assert(fails("[]"));
    assert(fails("[z-a]"));
    assert(fails("\\q"));
    assert(fails("a\\"));
    assert(fails("^*"));
}

unittest
{
    // first-character and anchoring analysis
    CharSet f;
    assert(!p1("ab").collectFirst(f) && f.contains('a') && !f.contains('b'));
    CharSet g;
    assert(p1("a*b").collectFirst(g) == false && g.contains('a') && g.contains('b'));
    CharSet h;
    assert(p1("a?").collectFirst(h));
    assert(p1("^a").anchoredAtStart);
    assert(p1("^a|^b").anchoredAtStart);
    assert(!p1("^a|b").anchoredAtStart);
    assert(!p1("(^a)?").anchoredAtStart);
    assert(p1("(^a)+").anchoredAtStart);
    assert(p1("a*").nullable && !p1("a+").nullable && p1("(a*){2}").nullable);
}
