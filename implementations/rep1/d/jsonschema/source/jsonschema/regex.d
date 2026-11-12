/**
 * A small ECMA-262 flavoured regular-expression engine for *membership*
 * tests ("does the pattern match anywhere in this string?").
 *
 * The pattern is parsed into a syntax tree, compiled to a Thompson-style
 * program (counted repetition is expanded) and matched by simulating the
 * program on all threads at once, so a search costs O(program * subject)
 * time with no exponential backtracking.
 *
 * Supported: alternation, groups `(...)`/`(?:...)`, greedy and lazy
 * quantifiers `* + ? {n} {n,} {n,m}`, `.`, `^`, `$`, `\b`, `\B`, character
 * classes with ranges and the escapes `\d \D \w \W \s \S`, and the character
 * escapes `\n \r \t \f \v \0 \xHH \uHHHH \cX` plus escaped punctuation.
 * Matching is over Unicode code points and there are no flags.
 */
module jsonschema.regex;

import std.algorithm.sorting : sort;

/// Thrown when a pattern is outside the supported syntax.
class RegexException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__)
    {
        super(msg, file, line);
    }
}

private enum uint maxCodePoint = 0x10FFFF;

private alias Range = uint[2];

private immutable Range[] digitRanges = [[0x30, 0x39]];
private immutable Range[] wordRanges = [[0x30, 0x39], [0x41, 0x5A], [0x5F, 0x5F], [0x61, 0x7A]];
private immutable Range[] spaceRanges = [
    [0x09, 0x0D], [0x20, 0x20], [0xA0, 0xA0], [0x1680, 0x1680], [0x2000, 0x200A],
    [0x2028, 0x2029], [0x202F, 0x202F], [0x205F, 0x205F], [0x3000, 0x3000],
    [0xFEFF, 0xFEFF]
];

private Range[] normalizeRanges(Range[] rs)
{
    if (rs.length == 0)
        return rs;
    rs.sort!((a, b) => a[0] < b[0]);
    Range[] out_;
    out_ ~= rs[0];
    foreach (r; rs[1 .. $])
    {
        if (r[0] <= out_[$ - 1][1] + 1)
        {
            if (r[1] > out_[$ - 1][1])
                out_[$ - 1][1] = r[1];
        }
        else
            out_ ~= r;
    }
    return out_;
}

private Range[] complementRanges(Range[] rs)
{
    auto n = normalizeRanges(rs.dup);
    Range[] out_;
    uint next = 0;
    foreach (r; n)
    {
        if (r[0] > next)
            out_ ~= [next, r[0] - 1];
        next = r[1] + 1;
    }
    if (n.length == 0 || n[$ - 1][1] < maxCodePoint)
        out_ ~= [next, maxCodePoint];
    return out_;
}

// --- syntax tree ------------------------------------------------------------

private enum NodeKind
{
    empty,
    char_,
    any,
    set,
    bol,
    eol,
    wordB,
    notWordB,
    cat,
    alt,
    repeat,
}

private final class Node
{
    NodeKind kind;
    uint ch;
    Range[] ranges; // for set (already normalised and, if negated, complemented)
    Node[] kids; // cat / alt; repeat has kids[0]
    uint min, max; // repeat; max == uint.max means unbounded
    bool lazy_;

    this(NodeKind k)
    {
        kind = k;
    }
}

// --- parser -----------------------------------------------------------------

private struct PatternParser
{
    uint[] src;
    size_t pos;

    bool atEnd() const
    {
        return pos >= src.length;
    }

    RegexException fail(string msg)
    {
        return new RegexException(msg);
    }

    Node parseAlt()
    {
        Node[] branches = [parseCat()];
        while (!atEnd && src[pos] == '|')
        {
            pos++;
            branches ~= parseCat();
        }
        if (branches.length == 1)
            return branches[0];
        auto n = new Node(NodeKind.alt);
        n.kids = branches;
        return n;
    }

    Node parseCat()
    {
        Node[] parts;
        while (!atEnd && src[pos] != '|' && src[pos] != ')')
            parts ~= parseQuantified();
        if (parts.length == 0)
            return new Node(NodeKind.empty);
        if (parts.length == 1)
            return parts[0];
        auto n = new Node(NodeKind.cat);
        n.kids = parts;
        return n;
    }

    Node parseQuantified()
    {
        auto atom = parseAtom();
        while (!atEnd)
        {
            uint mn, mx;
            immutable c = src[pos];
            if (c == '*')
            {
                mn = 0;
                mx = uint.max;
                pos++;
            }
            else if (c == '+')
            {
                mn = 1;
                mx = uint.max;
                pos++;
            }
            else if (c == '?')
            {
                mn = 0;
                mx = 1;
                pos++;
            }
            else if (c == '{')
            {
                if (!tryBraces(mn, mx))
                    break;
            }
            else
                break;
            auto r = new Node(NodeKind.repeat);
            r.kids = [atom];
            r.min = mn;
            r.max = mx;
            if (!atEnd && src[pos] == '?')
            {
                r.lazy_ = true;
                pos++;
            }
            atom = r;
        }
        return atom;
    }

    // Parses {n}, {n,}, {n,m} at `pos`; leaves `pos` unchanged and returns
    // false when the text is not a well-formed quantifier.
    bool tryBraces(out uint mn, out uint mx)
    {
        size_t p = pos + 1;
        bool digits(out ulong v)
        {
            size_t s = p;
            v = 0;
            while (p < src.length && src[p] >= '0' && src[p] <= '9')
            {
                if (v < 10_000_000_000UL)
                    v = v * 10 + (src[p] - '0');
                p++;
            }
            return p > s;
        }

        ulong a, b;
        if (!digits(a))
            return false;
        bool unbounded = false;
        if (p < src.length && src[p] == ',')
        {
            p++;
            if (p < src.length && src[p] == '}')
            {
                unbounded = true;
                b = 0;
            }
            else if (!digits(b))
                return false;
        }
        else
            b = a;
        if (p >= src.length || src[p] != '}')
            return false;
        p++;
        enum ulong cap = 1_000_000;
        if (a > cap || (!unbounded && b > cap))
            throw fail("repetition count too large");
        if (!unbounded && b < a)
            throw fail("bad repetition range");
        mn = cast(uint) a;
        mx = unbounded ? uint.max : cast(uint) b;
        pos = p;
        return true;
    }

    Node parseAtom()
    {
        immutable c = src[pos];
        switch (c)
        {
        case '(':
            {
                pos++;
                if (pos + 1 < src.length && src[pos] == '?' && src[pos + 1] == ':')
                    pos += 2;
                else if (!atEnd && src[pos] == '?')
                    throw fail("unsupported group syntax");
                auto inner = parseAlt();
                if (atEnd || src[pos] != ')')
                    throw fail("missing ')'");
                pos++;
                return inner;
            }
        case ')':
            throw fail("unmatched ')'");
        case '[':
            return parseClass();
        case '.':
            pos++;
            return new Node(NodeKind.any);
        case '^':
            pos++;
            return new Node(NodeKind.bol);
        case '$':
            pos++;
            return new Node(NodeKind.eol);
        case '\\':
            return parseAtomEscape();
        case '*':
        case '+':
        case '?':
            throw fail("nothing to repeat");
        default:
            pos++;
            return charNode(c);
        }
    }

    static Node charNode(uint c)
    {
        auto n = new Node(NodeKind.char_);
        n.ch = c;
        return n;
    }

    static Node setNode(Range[] rs, bool negate)
    {
        auto n = new Node(NodeKind.set);
        auto norm = normalizeRanges(rs.dup);
        n.ranges = negate ? complementRanges(norm) : norm;
        return n;
    }

    static int hexv(uint c)
    {
        if (c >= '0' && c <= '9')
            return c - '0';
        if (c >= 'a' && c <= 'f')
            return c - 'a' + 10;
        if (c >= 'A' && c <= 'F')
            return c - 'A' + 10;
        return -1;
    }

    // Reads exactly `n` hex digits at pos; returns -1 (pos unchanged) on failure.
    long readHex(size_t n)
    {
        if (pos + n > src.length)
            return -1;
        uint v = 0;
        foreach (i; 0 .. n)
        {
            immutable h = hexv(src[pos + i]);
            if (h < 0)
                return -1;
            v = v * 16 + h;
        }
        pos += n;
        return v;
    }

    // After a backslash and its escape letter `e` (already consumed), parses
    // a single-character escape. Returns the code point.
    uint charEscape(uint e, bool inClass)
    {
        switch (e)
        {
        case 'n':
            return '\n';
        case 'r':
            return '\r';
        case 't':
            return '\t';
        case 'f':
            return '\f';
        case 'v':
            return '\v';
        case '0':
            return 0;
        case 'b':
            return inClass ? 8 : 'b';
        case 'x':
            {
                auto h = readHex(2);
                return h < 0 ? 'x' : cast(uint) h;
            }
        case 'u':
            {
                auto h = readHex(4);
                if (h < 0)
                    return 'u';
                uint cp = cast(uint) h;
                if (cp >= 0xD800 && cp <= 0xDBFF && pos + 1 < src.length
                        && src[pos] == '\\' && src[pos + 1] == 'u')
                {
                    immutable save = pos;
                    pos += 2;
                    auto lo = readHex(4);
                    if (lo >= 0xDC00 && lo <= 0xDFFF)
                        cp = 0x10000 + ((cp - 0xD800) << 10) + (cast(uint) lo - 0xDC00);
                    else
                        pos = save;
                }
                return cp;
            }
        case 'c':
            {
                if (!atEnd && ((src[pos] | 0x20) >= 'a' && (src[pos] | 0x20) <= 'z'))
                {
                    immutable l = src[pos++];
                    return l % 32;
                }
                return 'c'; // not a control escape: identity escape
            }
        default:
            return e; // identity escape
        }
    }

    Node parseAtomEscape()
    {
        pos++; // backslash
        if (atEnd)
            throw fail("trailing backslash");
        immutable e = src[pos++];
        switch (e)
        {
        case 'd':
            return setNode(digitRanges.dup, false);
        case 'D':
            return setNode(digitRanges.dup, true);
        case 'w':
            return setNode(wordRanges.dup, false);
        case 'W':
            return setNode(wordRanges.dup, true);
        case 's':
            return setNode(spaceRanges.dup, false);
        case 'S':
            return setNode(spaceRanges.dup, true);
        case 'b':
            return new Node(NodeKind.wordB);
        case 'B':
            return new Node(NodeKind.notWordB);
        default:
            return charNode(charEscape(e, false));
        }
    }

    // A class atom: either a single code point or a set of ranges.
    struct ClassAtom
    {
        bool isSet;
        uint ch;
        Range[] set;
    }

    ClassAtom parseClassAtom()
    {
        immutable c = src[pos++];
        ClassAtom a;
        if (c != '\\')
        {
            a.ch = c;
            return a;
        }
        if (atEnd)
            throw fail("trailing backslash");
        immutable e = src[pos++];
        switch (e)
        {
        case 'd':
            a.isSet = true;
            a.set = digitRanges.dup;
            return a;
        case 'D':
            a.isSet = true;
            a.set = complementRanges(digitRanges.dup);
            return a;
        case 'w':
            a.isSet = true;
            a.set = wordRanges.dup;
            return a;
        case 'W':
            a.isSet = true;
            a.set = complementRanges(wordRanges.dup);
            return a;
        case 's':
            a.isSet = true;
            a.set = spaceRanges.dup;
            return a;
        case 'S':
            a.isSet = true;
            a.set = complementRanges(spaceRanges.dup);
            return a;
        default:
            a.ch = charEscape(e, true);
            return a;
        }
    }

    Node parseClass()
    {
        pos++; // [
        bool negate = false;
        if (!atEnd && src[pos] == '^')
        {
            negate = true;
            pos++;
        }
        Range[] rs;
        while (true)
        {
            if (atEnd)
                throw fail("unterminated character class");
            if (src[pos] == ']')
            {
                pos++;
                break;
            }
            auto lo = parseClassAtom();
            if (!lo.isSet && pos + 1 < src.length && src[pos] == '-' && src[pos + 1] != ']')
            {
                immutable save = pos;
                pos++;
                auto hi = parseClassAtom();
                if (hi.isSet)
                {
                    // "a-\d": the dash is literal.
                    rs ~= [lo.ch, lo.ch];
                    rs ~= [cast(uint) '-', cast(uint) '-'];
                    rs ~= hi.set;
                }
                else
                {
                    if (hi.ch < lo.ch)
                        throw fail("range out of order in character class");
                    rs ~= [lo.ch, hi.ch];
                }
                cast(void) save;
                continue;
            }
            if (lo.isSet)
                rs ~= lo.set;
            else
                rs ~= [lo.ch, lo.ch];
        }
        return setNode(rs, negate);
    }
}

// --- program ----------------------------------------------------------------

private enum Op : ubyte
{
    char_,
    any,
    set,
    split,
    jmp,
    bol,
    eol,
    wordB,
    notWordB,
    match,
}

private struct Inst
{
    Op op;
    uint ch; // char_
    int x, y; // split targets / jmp target / set index
}

private final class Compiler
{
    Inst[] prog;
    Range[][] sets;
    enum size_t maxProgram = 4_000_000;

    int emit(Inst i)
    {
        if (prog.length >= maxProgram)
            throw new RegexException("pattern too large");
        prog ~= i;
        return cast(int) prog.length - 1;
    }

    void compile(Node n)
    {
        final switch (n.kind)
        {
        case NodeKind.empty:
            break;
        case NodeKind.char_:
            emit(Inst(Op.char_, n.ch));
            break;
        case NodeKind.any:
            emit(Inst(Op.any));
            break;
        case NodeKind.set:
            sets ~= n.ranges;
            emit(Inst(Op.set, 0, cast(int) sets.length - 1));
            break;
        case NodeKind.bol:
            emit(Inst(Op.bol));
            break;
        case NodeKind.eol:
            emit(Inst(Op.eol));
            break;
        case NodeKind.wordB:
            emit(Inst(Op.wordB));
            break;
        case NodeKind.notWordB:
            emit(Inst(Op.notWordB));
            break;
        case NodeKind.cat:
            foreach (k; n.kids)
                compile(k);
            break;
        case NodeKind.alt:
            {
                int[] jumps;
                foreach (i, k; n.kids)
                {
                    if (i + 1 < n.kids.length)
                    {
                        auto sp = emit(Inst(Op.split));
                        prog[sp].x = sp + 1;
                        compile(k);
                        jumps ~= emit(Inst(Op.jmp));
                        prog[sp].y = cast(int) prog.length;
                    }
                    else
                        compile(k);
                }
                foreach (j; jumps)
                    prog[j].x = cast(int) prog.length;
                break;
            }
        case NodeKind.repeat:
            compileRepeat(n);
            break;
        }
    }

    void compileRepeat(Node n)
    {
        auto body_ = n.kids[0];
        foreach (_; 0 .. n.min)
            compile(body_);
        if (n.max == uint.max)
        {
            // L: split(body, out); body; jmp L
            auto sp = emit(Inst(Op.split));
            compile(body_);
            auto j = emit(Inst(Op.jmp));
            prog[j].x = sp;
            setSplit(sp, sp + 1, cast(int) prog.length, n.lazy_);
        }
        else
        {
            // (body (body (...)?)?)? as a chain of optional copies
            int[] splits;
            foreach (_; n.min .. n.max)
            {
                auto sp = emit(Inst(Op.split));
                splits ~= sp;
                compile(body_);
            }
            foreach (sp; splits)
                setSplit(sp, sp + 1, cast(int) prog.length, n.lazy_);
        }
    }

    void setSplit(int sp, int a, int b, bool lazy_)
    {
        prog[sp].x = lazy_ ? b : a;
        prog[sp].y = lazy_ ? a : b;
    }
}

// --- matcher ----------------------------------------------------------------

private bool inRanges(const Range[] rs, uint c)
{
    size_t lo = 0, hi = rs.length;
    while (lo < hi)
    {
        immutable mid = (lo + hi) / 2;
        if (c < rs[mid][0])
            hi = mid;
        else if (c > rs[mid][1])
            lo = mid + 1;
        else
            return true;
    }
    return false;
}

private bool isWordChar(uint c)
{
    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_';
}

private bool isLineTerminator(uint c)
{
    return c == 0x0A || c == 0x0D || c == 0x2028 || c == 0x2029;
}

/// A compiled regular expression.
final class Regex
{
    private Inst[] prog;
    private Range[][] sets;

    /// Compiles `pattern`; throws `RegexException` when it is not supported.
    this(string pattern)
    {
        import std.utf : byDchar;

        uint[] cps;
        foreach (c; pattern.byDchar)
            cps ~= c;
        auto parser = PatternParser(cps);
        auto tree = parser.parseAlt();
        if (!parser.atEnd)
            throw new RegexException("unmatched ')'");
        auto comp = new Compiler;
        comp.compile(tree);
        comp.emit(Inst(Op.match));
        prog = comp.prog;
        sets = comp.sets;
    }

    // scratch state reused across searches (the validator is single-threaded)
    private int[] mark;
    private int generation;
    private int[] clist, nlist, stack;
    private uint[] subject;

    /// True when the pattern matches anywhere in `text`.
    bool matches(const(char)[] text)
    {
        import std.utf : byDchar;

        subject.length = 0;
        assumeSafeAppend(subject);
        foreach (c; text.byDchar)
            subject ~= c;
        return search(subject);
    }

    private bool search(const uint[] s)
    {
        immutable n = s.length;
        if (mark.length != prog.length)
        {
            mark = new int[prog.length];
            generation = 0;
        }
        clist.length = 0;
        nlist.length = 0;
        assumeSafeAppend(clist);
        assumeSafeAppend(nlist);
        nextGen();
        for (size_t pos = 0;; pos++)
        {
            // start a new thread at this position (generation already current)
            if (addThread(clist, 0, s, pos))
                return true;
            if (pos >= n)
                return false;
            immutable c = s[pos];
            nextGen();
            nlist.length = 0;
            foreach (pc; clist)
            {
                immutable ins = prog[pc];
                bool ok = false;
                final switch (ins.op)
                {
                case Op.char_:
                    ok = c == ins.ch;
                    break;
                case Op.any:
                    ok = !isLineTerminator(c);
                    break;
                case Op.set:
                    ok = inRanges(sets[ins.x], c);
                    break;
                case Op.split:
                case Op.jmp:
                case Op.bol:
                case Op.eol:
                case Op.wordB:
                case Op.notWordB:
                case Op.match:
                    break;
                }
                if (ok && addThread(nlist, pc + 1, s, pos + 1))
                    return true;
            }
            auto t = clist;
            clist = nlist;
            nlist = t;
        }
    }

    private void nextGen()
    {
        generation++;
    }

    // Follows empty transitions from `pc` at subject position `pos`, appending
    // consuming instructions to `list`. Returns true if `match` is reached.
    private bool addThread(ref int[] list, int pc0, const uint[] s, size_t pos)
    {
        stack.length = 0;
        stack ~= pc0;
        while (stack.length)
        {
            immutable pc = stack[$ - 1];
            stack.length = stack.length - 1;
            if (mark[pc] == generation)
                continue;
            mark[pc] = generation;
            immutable ins = prog[pc];
            final switch (ins.op)
            {
            case Op.char_:
            case Op.any:
            case Op.set:
                list ~= pc;
                break;
            case Op.jmp:
                stack ~= ins.x;
                break;
            case Op.split:
                // push y first so x is explored first (order is irrelevant here)
                stack ~= ins.y;
                stack ~= ins.x;
                break;
            case Op.bol:
                if (pos == 0)
                    stack ~= pc + 1;
                break;
            case Op.eol:
                if (pos == s.length)
                    stack ~= pc + 1;
                break;
            case Op.wordB:
            case Op.notWordB:
                {
                    immutable a = pos > 0 && isWordChar(s[pos - 1]);
                    immutable b = pos < s.length && isWordChar(s[pos]);
                    if ((a != b) == (ins.op == Op.wordB))
                        stack ~= pc + 1;
                    break;
                }
            case Op.match:
                return true;
            }
        }
        return false;
    }
}

/// A cache of compiled patterns keyed by pattern text.
final class RegexCache
{
    private Regex[string] cache;

    /// Returns the compiled form of `pattern`, compiling it on first use.
    Regex get(string pattern)
    {
        if (auto p = pattern in cache)
            return *p;
        auto r = new Regex(pattern);
        cache[pattern] = r;
        return r;
    }
}

version (unittest)
{
    private bool m(string pat, string s)
    {
        return new Regex(pat).matches(s);
    }
}

unittest
{
    assert(m("bar", "foobarbaz"));
    assert(!m("^bar", "foobarbaz"));
    assert(m("^foo", "foobarbaz"));
    assert(m("baz$", "foobarbaz"));
    assert(!m("^a$", "a\n"));
    assert(m("^$", ""));
    assert(m("a|b", "xxb"));
    assert(!m("^(a|b)$", "ab"));
    assert(m("^(?:ab)+$", "ababab"));
    assert(m("^a{2,3}$", "aaa"));
    assert(!m("^a{2,3}$", "aaaa"));
    assert(m("^a{2,}$", "aaaaa"));
    assert(m("a{x", "a{x"));
    assert(m("^a{,3}$", "a{,3}"));
    assert(m("^a*?b$", "aaab"));
}

unittest
{
    assert(m("\\bcat\\b", "écat "));
    assert(!m("\\bcat\\b", "concat"));
    assert(m("\\Bcat", "concat"));
    assert(m("^\\d+$", "12345"));
    assert(!m("^\\d+$", "12a45"));
    assert(m("^\\w+$", "abc_123"));
    assert(m("^\\s$", " "));
    assert(m("^\\S$", "x"));
    assert(m("^[a-c]+$", "abcabc"));
    assert(!m("^[^a-c]+$", "abd"));
    assert(m("^[\\d-x]+$", "1-x"));
    assert(m("^[a-]+$", "a-a"));
    assert(m("^.$", "\U0001F4A9"));
    assert(!m("^.$", "\n"));
    assert(m("^\\u0041\\x42\\cJ$", "AB\n"));
    assert(m("^\\ud83d\\udca9$", "\U0001F4A9"));
    assert(m("^\\.\\*\\/$", ".*/"));
    assert(m("^[\\b]$", "\u0008"));
    assert(m("^[^]$", "z"));
}

unittest
{
    // No exponential blow-up.
    import std.array : replicate;

    auto r = new Regex("^(a+)+$");
    assert(!r.matches("a".replicate(5000) ~ "b"));
    auto r2 = new Regex("(x+x+)+y");
    assert(!r2.matches("x".replicate(5000)));
    assert(new Regex("^(?:a{0,100}){0,100}$").matches("aaa"));
}

unittest
{
    import std.exception : assertThrown;

    assertThrown!RegexException(new Regex("(abc"));
    assertThrown!RegexException(new Regex("abc)"));
    assertThrown!RegexException(new Regex("[abc"));
    assertThrown!RegexException(new Regex("*a"));
}
