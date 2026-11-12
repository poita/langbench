/**
 * S-expression reader and canonical printer for the card database format
 * (SPEC.md section 5.1).
 */
module cardgame.sexpr;

import std.array : appender, Appender;
import std.conv : to;

/// Raised when the text cannot be tokenised or parsed.
class SExprException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(msg, file, line);
    }
}

/// A node of the parsed tree: a symbol, an integer, a string or a list.
struct SExpr
{
    /// Kind of node.
    enum Kind : ubyte { symbol, integer, str, list }

    Kind kind;
    /// Symbol name or string contents (without quotes).
    string text;
    /// Value of an integer atom.
    long num;
    /// Children of a list.
    SExpr[] items;

    bool isSymbol() const pure nothrow @safe @nogc { return kind == Kind.symbol; }
    bool isInt() const pure nothrow @safe @nogc { return kind == Kind.integer; }
    bool isString() const pure nothrow @safe @nogc { return kind == Kind.str; }
    bool isList() const pure nothrow @safe @nogc { return kind == Kind.list; }

    /// True for the symbol `s`.
    bool isSym(string s) const pure nothrow @safe @nogc
    {
        return kind == Kind.symbol && text == s;
    }

    /// The head symbol of a non-empty list whose first element is a symbol, else null.
    string head() const pure nothrow @safe @nogc
    {
        if (kind == Kind.list && items.length > 0 && items[0].kind == Kind.symbol)
            return items[0].text;
        return null;
    }

    static SExpr symbol(string s) { SExpr e; e.kind = Kind.symbol; e.text = s; return e; }
    static SExpr integer(long v) { SExpr e; e.kind = Kind.integer; e.num = v; return e; }
    static SExpr list(SExpr[] items) { SExpr e; e.kind = Kind.list; e.items = items; return e; }
}

private bool isSpace(char c) pure nothrow @safe @nogc
{
    return c == ' ' || c == '\t' || c == '\r' || c == '\n' || c == '\f' || c == '\v';
}

private bool isAtomChar(char c) pure nothrow @safe @nogc
{
    return !isSpace(c) && c != '(' && c != ')' && c != ';' && c != '"';
}

/// Parse a decimal integer atom `-?[0-9]+` into a signed 64-bit value.
/// Returns false when `s` is not an integer atom; throws when it does not fit.
bool parseIntegerAtom(string s, out long value) pure @safe
{
    size_t i = 0;
    bool neg = false;
    if (s.length > 0 && s[0] == '-') { neg = true; i = 1; }
    if (i >= s.length) return false;
    foreach (c; s[i .. $])
        if (c < '0' || c > '9') return false;
    ulong acc = 0;
    immutable limit = neg ? (cast(ulong) long.max) + 1 : cast(ulong) long.max;
    foreach (c; s[i .. $])
    {
        immutable d = c - '0';
        if (acc > (limit - d) / 10) throw new SExprException("integer out of range");
        acc = acc * 10 + d;
    }
    value = neg ? cast(long)(0 - acc) : cast(long) acc;
    return true;
}

/// Parse a whole file into its top-level forms.
SExpr[] parseSExprs(string src)
{
    size_t pos = 0;
    SExpr[] top;

    void skip()
    {
        while (pos < src.length)
        {
            immutable c = src[pos];
            if (isSpace(c)) ++pos;
            else if (c == ';')
            {
                while (pos < src.length && src[pos] != '\n') ++pos;
            }
            else break;
        }
    }

    SExpr readOne(int depth)
    {
        if (depth > 10_000) throw new SExprException("nesting too deep");
        skip();
        if (pos >= src.length) throw new SExprException("unexpected end of input");
        immutable c = src[pos];
        if (c == '(')
        {
            ++pos;
            SExpr[] items;
            for (;;)
            {
                skip();
                if (pos >= src.length) throw new SExprException("unbalanced parenthesis");
                if (src[pos] == ')') { ++pos; break; }
                items ~= readOne(depth + 1);
            }
            return SExpr.list(items);
        }
        if (c == ')') throw new SExprException("unexpected ')'");
        if (c == '"')
        {
            immutable start = ++pos;
            while (pos < src.length && src[pos] != '"' && src[pos] != '\n') ++pos;
            if (pos >= src.length || src[pos] != '"')
                throw new SExprException("unterminated string");
            SExpr e;
            e.kind = SExpr.Kind.str;
            e.text = src[start .. pos];
            ++pos;
            return e;
        }
        immutable start = pos;
        while (pos < src.length && isAtomChar(src[pos])) ++pos;
        immutable atom = src[start .. pos];
        long v;
        if (parseIntegerAtom(atom, v)) return SExpr.integer(v);
        return SExpr.symbol(atom);
    }

    for (;;)
    {
        skip();
        if (pos >= src.length) break;
        top ~= readOne(0);
    }
    return top;
}

/// Canonical printing: lists in parentheses joined by single spaces,
/// strings re-quoted, integers in minimal decimal.
void printSExpr(ref Appender!string o, in SExpr e)
{
    final switch (e.kind)
    {
    case SExpr.Kind.symbol: o ~= e.text; break;
    case SExpr.Kind.integer: o ~= e.num.to!string; break;
    case SExpr.Kind.str: o ~= '"'; o ~= e.text; o ~= '"'; break;
    case SExpr.Kind.list:
        o ~= '(';
        foreach (i, ref it; e.items)
        {
            if (i) o ~= ' ';
            printSExpr(o, it);
        }
        o ~= ')';
        break;
    }
}

/// ditto
string printSExpr(in SExpr e)
{
    auto o = appender!string();
    printSExpr(o, e);
    return o.data;
}

unittest
{
    auto forms = parseSExprs(`(card X (name "a b") ; c
        (n -12 foo))`);
    assert(forms.length == 1);
    assert(printSExpr(forms[0]) == `(card X (name "a b") (n -12 foo))`);
}

unittest
{
    import std.exception : assertThrown;
    assertThrown!SExprException(parseSExprs("(a"));
    assertThrown!SExprException(parseSExprs("a)"));
    assertThrown!SExprException(parseSExprs("(a \"b\nc\")"));
    assertThrown!SExprException(parseSExprs("(a 99999999999999999999)"));
    assert(parseSExprs("(a -9223372036854775808)")[0].items[1].num == long.min);
    assert(parseSExprs("(a +5 -)")[0].items[1].isSymbol);
}
