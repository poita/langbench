/**
 * A small ECMA-262 style regular-expression engine for membership tests.
 *
 * Supported syntax: alternation, grouping (`(...)`, `(?:...)`), the
 * quantifiers `* + ? {n} {n,} {n,m}` (lazy forms are accepted; laziness never
 * changes whether a match exists), `.`, `^`, `$`, `\b`, `\B`, character
 * classes with ranges, the class escapes `\d \D \w \W \s \S` and the
 * character escapes `\n \r \t \f \v \0 \xHH \uHHHH \cX` plus escaped
 * punctuation. Matching is over Unicode code points with no flags.
 *
 * The pattern is compiled to a Thompson NFA program and simulated in
 * O(program size * subject length) time, so there is no catastrophic
 * backtracking. A $(LREF Regex) keeps scratch buffers and is therefore not
 * safe to share between threads.
 */
module jsonschema.regex;

import std.algorithm.sorting : sort;

/// Thrown for patterns outside the supported syntax.
class RegexException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__)
    {
        super(msg, file, line);
    }
}

private struct Range
{
    uint lo, hi;
}

private enum uint maxCodePoint = 0x10FFFF;

/// A set of code points stored as sorted, disjoint ranges.
private struct CharClass
{
    uint[] lo, hi;
    ulong[2] ascii;

    static CharClass fromRanges(Range[] rs)
    {
        rs = rs.dup;
        rs.sort!((a, b) => a.lo < b.lo);
        CharClass c;
        foreach (r; rs)
        {
            if (c.lo.length && r.lo <= c.hi[$ - 1] + 1)
            {
                if (r.hi > c.hi[$ - 1])
                    c.hi[$ - 1] = r.hi;
            }
            else
            {
                c.lo ~= r.lo;
                c.hi ~= r.hi;
            }
        }
        foreach (i; 0 .. c.lo.length)
        {
            foreach (ch; c.lo[i] .. (c.hi[i] < 127 ? c.hi[i] : 127) + 1)
                if (ch < 128)
                    c.ascii[ch >> 6] |= 1UL << (ch & 63);
        }
        return c;
    }

    CharClass negated() const
    {
        Range[] out_;
        uint prev = 0;
        bool done = false;
        foreach (i; 0 .. lo.length)
        {
            if (lo[i] > prev)
                out_ ~= Range(prev, lo[i] - 1);
            if (hi[i] >= maxCodePoint)
            {
                done = true;
                break;
            }
            prev = hi[i] + 1;
        }
        if (!done)
            out_ ~= Range(prev, maxCodePoint);
        return fromRanges(out_);
    }

    bool contains(int c) const
    {
        if (c < 128)
            return (ascii[c >> 6] >> (c & 63)) & 1;
        size_t a = 0, b = lo.length;
        while (a < b)
        {
            immutable mid = (a + b) / 2;
            if (c < lo[mid])
                b = mid;
            else if (c > hi[mid])
                a = mid + 1;
            else
                return true;
        }
        return false;
    }
}

private enum RT : ubyte
{
    empty,
    chr,
    cls,
    cat,
    alt,
    rep,
    bol,
    eol,
    wordb,
    nwordb
}

private final class RNode
{
    RT t;
    uint c; // chr: code point; cls: class index
    RNode[] kids;
    int min, max; // rep; max < 0 means unbounded

    this(RT t)
    {
        this.t = t;
    }
}

private Range[] digitRanges()
{
    return [Range('0', '9')];
}

private Range[] wordRanges()
{
    return [Range('0', '9'), Range('A', 'Z'), Range('_', '_'), Range('a', 'z')];
}

private Range[] spaceRanges()
{
    return [
        Range(9, 13), Range(0x20, 0x20), Range(0xA0, 0xA0), Range(0x1680, 0x1680),
        Range(0x2000, 0x200A), Range(0x2028, 0x2029), Range(0x202F, 0x202F),
        Range(0x205F, 0x205F), Range(0x3000, 0x3000), Range(0xFEFF, 0xFEFF)
    ];
}

private Range[] negateRanges(Range[] rs)
{
    auto c = CharClass.fromRanges(rs).negated();
    Range[] r;
    foreach (i; 0 .. c.lo.length)
        r ~= Range(c.lo[i], c.hi[i]);
    return r;
}

private struct ClassAtom
{
    bool isSet;
    uint ch;
    Range[] set;
}

private struct PatternParser
{
    uint[] pat;
    size_t pos;
    CharClass[] classes;

    bool eof() const
    {
        return pos >= pat.length;
    }

    int peek(size_t off = 0) const
    {
        return pos + off < pat.length ? cast(int) pat[pos + off] : -1;
    }

    RNode parseAlt()
    {
        RNode[] alts = [parseCat()];
        while (peek() == '|')
        {
            pos++;
            alts ~= parseCat();
        }
        if (alts.length == 1)
            return alts[0];
        auto n = new RNode(RT.alt);
        n.kids = alts;
        return n;
    }

    RNode parseCat()
    {
        RNode[] items;
        while (!eof && peek() != '|' && peek() != ')')
            items ~= parseTerm();
        if (items.length == 0)
            return new RNode(RT.empty);
        if (items.length == 1)
            return items[0];
        auto n = new RNode(RT.cat);
        n.kids = items;
        return n;
    }

    int addClass(Range[] rs)
    {
        classes ~= CharClass.fromRanges(rs);
        return cast(int)(classes.length - 1);
    }

    RNode parseTerm()
    {
        immutable c = pat[pos++];
        RNode atom;
        switch (c)
        {
        case '^':
            return new RNode(RT.bol);
        case '$':
            return new RNode(RT.eol);
        case '(':
            if (peek() == '?')
            {
                if (peek(1) == ':')
                    pos += 2;
                else
                    throw new RegexException("unsupported group syntax");
            }
            atom = parseAlt();
            if (peek() != ')')
                throw new RegexException("unterminated group");
            pos++;
            break;
        case '.':
            atom = new RNode(RT.cls);
            atom.c = addClass([Range(0, 9), Range(11, 12), Range(14, 0x2027), Range(0x202A, maxCodePoint)]);
            break;
        case '[':
            atom = parseClass();
            break;
        case '\\':
            if (peek() == 'b')
            {
                pos++;
                return new RNode(RT.wordb);
            }
            if (peek() == 'B')
            {
                pos++;
                return new RNode(RT.nwordb);
            }
            atom = fromAtom(parseEscape(false));
            break;
        case '*':
        case '+':
        case '?':
            throw new RegexException("nothing to repeat");
        default:
            atom = new RNode(RT.chr);
            atom.c = c;
        }
        return parseQuantifier(atom);
    }

    RNode fromAtom(ClassAtom a)
    {
        if (!a.isSet)
        {
            auto n = new RNode(RT.chr);
            n.c = a.ch;
            return n;
        }
        auto n = new RNode(RT.cls);
        n.c = addClass(a.set);
        return n;
    }

    RNode parseQuantifier(RNode atom)
    {
        int min, max;
        immutable c = peek();
        if (c == '*')
        {
            pos++;
            min = 0;
            max = -1;
        }
        else if (c == '+')
        {
            pos++;
            min = 1;
            max = -1;
        }
        else if (c == '?')
        {
            pos++;
            min = 0;
            max = 1;
        }
        else if (c == '{')
        {
            immutable save = pos;
            pos++;
            if (!parseBraces(min, max))
            {
                pos = save;
                return atom;
            }
        }
        else
            return atom;
        if (peek() == '?')
            pos++; // lazy: irrelevant for membership
        auto r = new RNode(RT.rep);
        r.kids = [atom];
        r.min = min;
        r.max = max;
        return r;
    }

    bool parseBraces(out int min, out int max)
    {
        long readInt(out bool ok)
        {
            long v = 0;
            size_t n = 0;
            while (peek() >= '0' && peek() <= '9')
            {
                if (v < 100_000_000)
                    v = v * 10 + (peek() - '0');
                pos++;
                n++;
            }
            ok = n > 0;
            return v;
        }

        bool ok;
        immutable lo = readInt(ok);
        if (!ok)
            return false;
        long hi = lo;
        if (peek() == ',')
        {
            pos++;
            bool ok2;
            hi = readInt(ok2);
            if (!ok2)
                hi = -1;
        }
        if (peek() != '}')
            return false;
        pos++;
        if (hi >= 0 && hi < lo)
            throw new RegexException("numbers out of order in quantifier");
        min = cast(int) lo;
        max = cast(int) hi;
        return true;
    }

    static int hexVal(int c)
    {
        if (c >= '0' && c <= '9')
            return c - '0';
        if (c >= 'a' && c <= 'f')
            return c - 'a' + 10;
        if (c >= 'A' && c <= 'F')
            return c - 'A' + 10;
        return -1;
    }

    bool readHex(size_t n, out uint v)
    {
        v = 0;
        foreach (i; 0 .. n)
            if (hexVal(peek(i)) < 0)
                return false;
        foreach (i; 0 .. n)
            v = v * 16 + hexVal(peek(i));
        pos += n;
        return true;
    }

    /// Parses an escape; the backslash has been consumed.
    ClassAtom parseEscape(bool inClass)
    {
        if (eof)
            throw new RegexException("\\ at end of pattern");
        immutable c = pat[pos++];
        ClassAtom ch(uint x)
        {
            return ClassAtom(false, x, null);
        }

        ClassAtom set(Range[] r)
        {
            return ClassAtom(true, 0, r);
        }

        switch (c)
        {
        case 'd':
            return set(digitRanges());
        case 'D':
            return set(negateRanges(digitRanges()));
        case 'w':
            return set(wordRanges());
        case 'W':
            return set(negateRanges(wordRanges()));
        case 's':
            return set(spaceRanges());
        case 'S':
            return set(negateRanges(spaceRanges()));
        case 'n':
            return ch('\n');
        case 'r':
            return ch('\r');
        case 't':
            return ch('\t');
        case 'f':
            return ch('\f');
        case 'v':
            return ch('\v');
        case '0':
            return ch(0);
        case 'b':
            return ch(8); // only reached inside a class
        case 'x':
            {
                uint v;
                if (readHex(2, v))
                    return ch(v);
                return ch('x');
            }
        case 'u':
            {
                uint v;
                if (!readHex(4, v))
                    return ch('u');
                if (v >= 0xD800 && v < 0xDC00 && peek() == '\\' && peek(1) == 'u')
                {
                    immutable save = pos;
                    pos += 2;
                    uint lo;
                    if (readHex(4, lo) && lo >= 0xDC00 && lo < 0xE000)
                        return ch(0x10000 + ((v - 0xD800) << 10) + (lo - 0xDC00));
                    pos = save;
                }
                return ch(v);
            }
        case 'c':
            {
                immutable l = peek();
                if ((l >= 'a' && l <= 'z') || (l >= 'A' && l <= 'Z'))
                {
                    pos++;
                    return ch(cast(uint) l % 32);
                }
                pos--; // treat the backslash as literal; 'c' is re-read next
                return ch('\\');
            }
        default:
            return ch(c);
        }
    }

    RNode parseClass()
    {
        bool negate = false;
        if (peek() == '^')
        {
            negate = true;
            pos++;
        }
        Range[] rs;
        void add(ClassAtom a)
        {
            if (a.isSet)
                rs ~= a.set;
            else
                rs ~= Range(a.ch, a.ch);
        }

        for (;;)
        {
            if (eof)
                throw new RegexException("unterminated character class");
            if (peek() == ']')
            {
                pos++;
                break;
            }
            auto a = parseClassAtom();
            if (peek() == '-' && peek(1) != -1 && peek(1) != ']')
            {
                pos++;
                auto b = parseClassAtom();
                if (!a.isSet && !b.isSet)
                {
                    if (a.ch > b.ch)
                        throw new RegexException("range out of order in character class");
                    rs ~= Range(a.ch, b.ch);
                }
                else
                {
                    add(a);
                    rs ~= Range('-', '-');
                    add(b);
                }
            }
            else
                add(a);
        }
        auto cc = CharClass.fromRanges(rs);
        if (negate)
            cc = cc.negated();
        classes ~= cc;
        auto n = new RNode(RT.cls);
        n.c = cast(uint)(classes.length - 1);
        return n;
    }

    ClassAtom parseClassAtom()
    {
        immutable c = pat[pos++];
        if (c == '\\')
            return parseEscape(true);
        return ClassAtom(false, c, null);
    }
}

private enum Op : ubyte
{
    chr,
    cls,
    split,
    jmp,
    bol,
    eol,
    wordb,
    nwordb,
    match
}

private struct Inst
{
    Op op;
    int x, y;
}

private bool isWordChar(int c)
{
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_';
}

private bool startsAnchored(RNode n)
{
    final switch (n.t)
    {
    case RT.bol:
        return true;
    case RT.cat:
        return startsAnchored(n.kids[0]);
    case RT.alt:
        foreach (k; n.kids)
            if (!startsAnchored(k))
                return false;
        return true;
    case RT.rep:
        return n.min > 0 && startsAnchored(n.kids[0]);
    case RT.empty:
    case RT.chr:
    case RT.cls:
    case RT.eol:
    case RT.wordb:
    case RT.nwordb:
        return false;
    }
}

/// A compiled regular expression.
final class Regex
{
    private Inst[] prog;
    private CharClass[] classes;
    private bool anchored;
    private int[] clist, nlist;
    private uint[] mark;
    private uint gen;
    private string literal;
    private bool isLiteral;

    /// The pattern source.
    string source;

    /// Compiles `pattern`. Throws $(LREF RegexException) if it is outside the supported syntax.
    this(string pattern)
    {
        import std.conv : to;
        import std.utf : UTFException;

        source = pattern;
        uint[] cps;
        try
        {
            foreach (dchar d; pattern)
                cps ~= d;
        }
        catch (UTFException e)
        {
            throw new RegexException("pattern is not valid UTF-8");
        }
        auto parser = PatternParser(cps, 0, null);
        auto tree = parser.parseAlt();
        if (!parser.eof)
            throw new RegexException("unmatched ')'");
        classes = parser.classes;
        anchored = startsAnchored(tree);
        emit(tree);
        prog ~= Inst(Op.match, 0, 0);
        clist = new int[prog.length];
        nlist = new int[prog.length];
        mark = new uint[prog.length];
        detectLiteral(tree);
    }

    private void detectLiteral(RNode tree)
    {
        import std.utf : encode;

        char[] lit;
        void walk(RNode n, ref bool ok)
        {
            if (n.t == RT.chr)
            {
                char[4] buf;
                immutable len = encode(buf, cast(dchar) n.c);
                lit ~= buf[0 .. len];
            }
            else if (n.t == RT.cat)
            {
                foreach (k; n.kids)
                    walk(k, ok);
            }
            else
                ok = false;
        }

        bool ok = true;
        if (tree.t == RT.chr || tree.t == RT.cat)
            walk(tree, ok);
        else
            ok = false;
        if (ok && lit.length > 0 && !(tree.t == RT.chr && tree.c >= 0xD800 && tree.c < 0xE000))
        {
            isLiteral = true;
            literal = lit.idup;
        }
    }

    private int add(Op op, int x = 0, int y = 0)
    {
        if (prog.length > 4_000_000)
            throw new RegexException("pattern too large");
        prog ~= Inst(op, x, y);
        return cast(int)(prog.length - 1);
    }

    private void emit(RNode n)
    {
        final switch (n.t)
        {
        case RT.empty:
            break;
        case RT.chr:
            add(Op.chr, cast(int) n.c);
            break;
        case RT.cls:
            add(Op.cls, cast(int) n.c);
            break;
        case RT.cat:
            foreach (k; n.kids)
                emit(k);
            break;
        case RT.alt:
            int[] jmps;
            foreach (i, k; n.kids)
            {
                if (i + 1 < n.kids.length)
                {
                    immutable s = add(Op.split);
                    prog[s].x = s + 1;
                    emit(k);
                    jmps ~= add(Op.jmp);
                    prog[s].y = cast(int) prog.length;
                }
                else
                    emit(k);
            }
            foreach (j; jmps)
                prog[j].x = cast(int) prog.length;
            break;
        case RT.rep:
            foreach (i; 0 .. n.min)
                emit(n.kids[0]);
            if (n.max < 0)
            {
                immutable s = add(Op.split);
                prog[s].x = s + 1;
                emit(n.kids[0]);
                add(Op.jmp, s);
                prog[s].y = cast(int) prog.length;
            }
            else
            {
                int[] splits;
                foreach (i; n.min .. n.max)
                {
                    immutable s = add(Op.split);
                    prog[s].x = s + 1;
                    splits ~= s;
                    emit(n.kids[0]);
                }
                foreach (s; splits)
                    prog[s].y = cast(int) prog.length;
            }
            break;
        case RT.bol:
            add(Op.bol);
            break;
        case RT.eol:
            add(Op.eol);
            break;
        case RT.wordb:
            add(Op.wordb);
            break;
        case RT.nwordb:
            add(Op.nwordb);
            break;
        }
    }

    /// Adds the epsilon closure of `pc` to `list`; returns true if `match` is reachable.
    private bool addThread(int[] list, ref size_t cnt, int pc, int prev, int cur, bool atStart)
    {
        for (;;)
        {
            if (mark[pc] == gen)
                return false;
            mark[pc] = gen;
            auto ins = &prog[pc];
            final switch (ins.op)
            {
            case Op.jmp:
                pc = ins.x;
                break;
            case Op.split:
                if (addThread(list, cnt, ins.x, prev, cur, atStart))
                    return true;
                pc = ins.y;
                break;
            case Op.bol:
                if (!atStart)
                    return false;
                pc++;
                break;
            case Op.eol:
                if (cur != -1)
                    return false;
                pc++;
                break;
            case Op.wordb:
                if (isWordChar(prev) == isWordChar(cur))
                    return false;
                pc++;
                break;
            case Op.nwordb:
                if (isWordChar(prev) != isWordChar(cur))
                    return false;
                pc++;
                break;
            case Op.match:
                return true;
            case Op.chr:
            case Op.cls:
                list[cnt++] = pc;
                return false;
            }
        }
    }

    private static int decodeAt(const(char)[] s, size_t p, out size_t len)
    {
        if (p >= s.length)
        {
            len = 0;
            return -1;
        }
        immutable b0 = cast(ubyte) s[p];
        if (b0 < 0x80)
        {
            len = 1;
            return b0;
        }
        size_t n;
        uint cp;
        if (b0 >= 0xF0)
        {
            n = 4;
            cp = b0 & 0x07;
        }
        else if (b0 >= 0xE0)
        {
            n = 3;
            cp = b0 & 0x0F;
        }
        else if (b0 >= 0xC0)
        {
            n = 2;
            cp = b0 & 0x1F;
        }
        else
        {
            len = 1;
            return 0xFFFD;
        }
        if (p + n > s.length)
        {
            len = 1;
            return 0xFFFD;
        }
        foreach (i; 1 .. n)
            cp = (cp << 6) | (cast(ubyte) s[p + i] & 0x3F);
        len = n;
        return cast(int) cp;
    }

    private void nextGen()
    {
        gen++;
        if (gen == 0)
        {
            mark[] = 0;
            gen = 1;
        }
    }

    /// True if the pattern matches anywhere in `subject` (an unanchored search).
    bool matches(const(char)[] subject)
    {
        import std.string : indexOf;

        if (isLiteral)
            return subject.indexOf(literal) >= 0;
        size_t p = 0, len;
        int prev = -1;
        int cur = decodeAt(subject, 0, len);
        size_t ccnt = 0, ncnt = 0;
        nextGen();
        if (addThread(clist, ccnt, 0, prev, cur, true))
            return true;
        for (;;)
        {
            if (cur == -1)
                return false;
            if (anchored && ccnt == 0)
                return false;
            immutable nextP = p + len;
            size_t nlen;
            immutable nxt = decodeAt(subject, nextP, nlen);
            nextGen();
            ncnt = 0;
            foreach (i; 0 .. ccnt)
            {
                immutable pc = clist[i];
                auto ins = &prog[pc];
                bool ok = ins.op == Op.chr ? (cur == ins.x) : classes[ins.x].contains(cur);
                if (ok && addThread(nlist, ncnt, pc + 1, cur, nxt, false))
                    return true;
            }
            if (!anchored && addThread(nlist, ncnt, 0, cur, nxt, false))
                return true;
            auto tmp = clist;
            clist = nlist;
            nlist = tmp;
            ccnt = ncnt;
            prev = cur;
            cur = nxt;
            p = nextP;
            len = nlen;
        }
    }
}
