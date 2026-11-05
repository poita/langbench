/// Recursive-descent parser for the supported pattern syntax.
module regexvm.parser;

import regexvm.ast;
import regexvm.charset;
import regexvm.errors;

/// Largest counted-quantifier bound accepted by the parser.
enum int maxRepeatBound = 10_000;

/// Parses `pattern` into a syntax tree.
///
/// Grammar (see the README for the full description):
/// ---
/// regex      := branch ( '|' branch )*
/// branch     := piece*
/// piece      := atom quantifier?
/// atom       := literal | '.' | '^' | '$' | class | escape | '(' regex ')'
/// quantifier := '*' | '+' | '?' | '{' n '}' | '{' n ',' '}' | '{' n ',' m '}'
/// ---
/// Throws: `RegexException` on a syntax error.
Ast parse(const(char)[] pattern)
{
    auto p = Parser(pattern);
    auto root = p.parseAlternation();
    if (p.pos != pattern.length)
        throw p.error("unmatched ')'");
    return Ast(root, p.groups);
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

    this(const(char)[] src) { this.src = src; }

    RegexException error(string msg)
    {
        return new RegexException(msg, pos);
    }

    bool atEnd() const { return pos >= src.length; }

    Node parseAlternation()
    {
        Node[] branches = [parseBranch()];
        while (!atEnd && src[pos] == '|')
        {
            ++pos;
            branches ~= parseBranch();
        }
        return branches.length == 1 ? branches[0] : Node.of(NodeKind.alt, branches);
    }

    Node parseBranch()
    {
        Node[] items;
        while (!atEnd && src[pos] != '|' && src[pos] != ')')
            items ~= parsePiece();
        return Node.of(NodeKind.seq, items);
    }

    Node parsePiece()
    {
        const anchor = src[pos] == '^' || src[pos] == '$';
        Node atom = parseAtom();
        if (atEnd)
            return atom;
        int min, max;
        switch (src[pos])
        {
        case '*': ++pos; min = 0; max = unbounded; break;
        case '+': ++pos; min = 1; max = unbounded; break;
        case '?': ++pos; min = 0; max = 1; break;
        case '{': parseBraces(min, max); break;
        default: return atom;
        }
        if (anchor)
            throw error("quantifier after an anchor");
        return Node.repetition(atom, min, max);
    }

    /// Parses `{n}`, `{n,}` or `{n,m}` at `pos`.
    void parseBraces(out int min, out int max)
    {
        ++pos; // '{'
        min = parseNumber();
        max = min;
        if (!atEnd && src[pos] == ',')
        {
            ++pos;
            max = (!atEnd && src[pos] == '}') ? unbounded : parseNumber();
        }
        if (atEnd || src[pos] != '}')
            throw error("malformed counted quantifier");
        ++pos;
        if (max != unbounded && max < min)
            throw error("quantifier maximum is below its minimum");
    }

    int parseNumber()
    {
        if (atEnd || src[pos] < '0' || src[pos] > '9')
            throw error("expected a number in counted quantifier");
        long v;
        while (!atEnd && src[pos] >= '0' && src[pos] <= '9')
        {
            v = v * 10 + (src[pos] - '0');
            if (v > maxRepeatBound)
                throw error("counted quantifier bound too large");
            ++pos;
        }
        return cast(int) v;
    }

    Node parseAtom()
    {
        const c = src[pos];
        switch (c)
        {
        case '.': ++pos; return new Node(NodeKind.any);
        case '^': ++pos; return new Node(NodeKind.bol);
        case '$': ++pos; return new Node(NodeKind.eol);
        case '(':
        {
            ++pos;
            const index = ++groups;
            auto body_ = parseAlternation();
            if (atEnd || src[pos] != ')')
                throw error("missing ')'");
            ++pos;
            return Node.capture(index, body_);
        }
        case '[': return parseClass();
        case '\\': return parseEscape();
        case '*', '+', '?':
            throw error("quantifier without an operand");
        case '{', '}', ']':
            throw error("unexpected brace or bracket");
        default:
            ++pos;
            return Node.literal(cast(ubyte) c);
        }
    }

    /// Escape outside a class; `pos` is at the backslash.
    Node parseEscape()
    {
        ++pos;
        if (atEnd)
            throw error("trailing backslash");
        const c = src[pos++];
        CharSet s;
        if (CharSet.forEscape(c, s))
            return Node.classOf(s);
        if (isAlnum(c))
            throw error("unknown escape");
        return Node.literal(cast(ubyte) c);
    }

    /// Bracket expression; `pos` is at the '['.
    Node parseClass()
    {
        ++pos;
        bool negated;
        if (!atEnd && src[pos] == '^')
        {
            negated = true;
            ++pos;
        }
        CharSet set;
        bool first = true;
        for (;;)
        {
            if (atEnd)
                throw error("unterminated character class");
            if (src[pos] == ']' && !first)
            {
                ++pos;
                break;
            }
            first = false;
            // A set escape stands alone (it cannot start a range).
            CharSet esc;
            if (src[pos] == '\\' && pos + 1 < src.length && CharSet.forEscape(src[pos + 1], esc))
            {
                set.addSet(esc);
                pos += 2;
                continue;
            }
            const lo = parseClassChar();
            // `x-y` is a range unless the '-' is the last character before ']'.
            if (pos + 1 < src.length && src[pos] == '-' && src[pos + 1] != ']')
            {
                ++pos;
                const hi = parseClassChar();
                if (hi < lo)
                    throw error("reversed range in character class");
                set.addRange(lo, hi);
            }
            else
                set.add(lo);
        }
        if (negated)
            set.negate();
        return Node.classOf(set);
    }

    /// One single character inside a class (possibly escaped).
    ubyte parseClassChar()
    {
        char c = src[pos++];
        if (c == '\\')
        {
            if (atEnd)
                throw error("trailing backslash");
            c = src[pos++];
            if (isAlnum(c))
                throw error("unknown escape in character class");
        }
        return cast(ubyte) c;
    }
}
