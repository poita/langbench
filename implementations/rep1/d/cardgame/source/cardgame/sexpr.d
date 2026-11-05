/**
 * S-expression reader and printer for the Spiremark card database.
 *
 * The lexical structure follows SPEC section 5.1: parentheses, double-quoted
 * strings without escapes, `;` comments, and atoms that are either 64-bit
 * integers or case-sensitive symbols.
 */
module cardgame.sexpr;

import std.array : appender;
import std.conv : to;

/// The four kinds of node an s-expression can be.
enum NodeKind : ubyte
{
    list,
    symbol,
    integer,
    str,
}

/// Raised for any lexical or structural error while reading s-expressions.
class SExprError : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) @safe pure
    {
        super(msg, file, line);
    }
}

/// A node of the parsed tree.
final class SExpr
{
    NodeKind kind;
    /// Symbol name or string contents.
    string text;
    /// Value of an integer atom.
    long num;
    /// Children of a list.
    SExpr[] items;

    this(NodeKind k) @safe pure nothrow
    {
        kind = k;
    }

    /// Build a symbol node.
    static SExpr symbol(string s) @safe pure nothrow
    {
        auto n = new SExpr(NodeKind.symbol);
        n.text = s;
        return n;
    }

    /// Build an integer node.
    static SExpr integer(long v) @safe pure nothrow
    {
        auto n = new SExpr(NodeKind.integer);
        n.num = v;
        return n;
    }

    /// Build a string node.
    static SExpr str(string s) @safe pure nothrow
    {
        auto n = new SExpr(NodeKind.str);
        n.text = s;
        return n;
    }

    /// Build a list node.
    static SExpr list(SExpr[] children) @safe pure nothrow
    {
        auto n = new SExpr(NodeKind.list);
        n.items = children;
        return n;
    }

    bool isList() const @safe pure nothrow
    {
        return kind == NodeKind.list;
    }

    bool isSymbol() const @safe pure nothrow
    {
        return kind == NodeKind.symbol;
    }

    bool isInt() const @safe pure nothrow
    {
        return kind == NodeKind.integer;
    }

    bool isStr() const @safe pure nothrow
    {
        return kind == NodeKind.str;
    }

    /// True when this node is the symbol `name`.
    bool isSym(string name) const @safe pure nothrow
    {
        return kind == NodeKind.symbol && text == name;
    }

    /// True when this node is a non-empty list whose head is the symbol `name`.
    bool isForm(string name) const @safe pure nothrow
    {
        return kind == NodeKind.list && items.length > 0 && items[0].isSym(name);
    }
}

private bool isSpace(char c) @safe pure nothrow @nogc
{
    return c == ' ' || c == '\t' || c == '\r' || c == '\n' || c == '\f' || c == '\v';
}

private bool isAtomChar(char c) @safe pure nothrow @nogc
{
    return !isSpace(c) && c != '(' && c != ')' && c != ';' && c != '"';
}

/// Parse an integer atom of the form `-?[0-9]+`; returns false if `s` is not one.
/// Throws `SExprError` when it is one but does not fit in 64 bits.
private bool parseIntegerAtom(string s, out long value) @safe pure
{
    size_t i = 0;
    bool neg = false;
    if (s.length > 0 && s[0] == '-')
    {
        neg = true;
        i = 1;
    }
    if (i >= s.length)
        return false;
    foreach (c; s[i .. $])
        if (c < '0' || c > '9')
            return false;
    ulong acc = 0;
    immutable ulong limit = neg ? (cast(ulong) long.max) + 1 : cast(ulong) long.max;
    foreach (c; s[i .. $])
    {
        immutable d = c - '0';
        if (acc > (limit - d) / 10)
            throw new SExprError("integer out of range");
        acc = acc * 10 + d;
    }
    value = neg ? cast(long)(0 - acc) : cast(long) acc;
    return true;
}

/**
 * Read every top-level form of `src`.
 *
 * Throws: `SExprError` on unbalanced parentheses, unterminated strings or
 * out-of-range integers.
 */
SExpr[] readAll(string src) @safe pure
{
    SExpr[] top;
    SExpr[][] stack;
    size_t i = 0;

    void add(SExpr n)
    {
        if (stack.length == 0)
            top ~= n;
        else
            stack[$ - 1] ~= n;
    }

    while (i < src.length)
    {
        immutable c = src[i];
        if (isSpace(c))
        {
            i++;
        }
        else if (c == ';')
        {
            while (i < src.length && src[i] != '\n')
                i++;
        }
        else if (c == '(')
        {
            stack ~= cast(SExpr[])[];
            i++;
        }
        else if (c == ')')
        {
            if (stack.length == 0)
                throw new SExprError("unbalanced ')'");
            auto items = stack[$ - 1];
            stack.length = stack.length - 1;
            add(SExpr.list(items));
            i++;
        }
        else if (c == '"')
        {
            size_t j = i + 1;
            while (j < src.length && src[j] != '"' && src[j] != '\n')
                j++;
            if (j >= src.length || src[j] != '"')
                throw new SExprError("unterminated string");
            add(SExpr.str(src[i + 1 .. j]));
            i = j + 1;
        }
        else
        {
            size_t j = i;
            while (j < src.length && isAtomChar(src[j]))
                j++;
            immutable atom = src[i .. j];
            long v;
            if (parseIntegerAtom(atom, v))
                add(SExpr.integer(v));
            else
                add(SExpr.symbol(atom));
            i = j;
        }
    }
    if (stack.length != 0)
        throw new SExprError("unbalanced '('");
    return top;
}

/// Canonical printing: single spaces, no other whitespace (SPEC 23.4).
string printSExpr(const SExpr n) @safe pure
{
    auto app = appender!string();
    printInto(app, n);
    return app.data;
}

private void printInto(R)(ref R app, const SExpr n) @safe pure
{
    final switch (n.kind)
    {
    case NodeKind.symbol:
        app.put(n.text);
        break;
    case NodeKind.integer:
        app.put(n.num.to!string);
        break;
    case NodeKind.str:
        app.put('"');
        app.put(n.text);
        app.put('"');
        break;
    case NodeKind.list:
        app.put('(');
        foreach (idx, c; n.items)
        {
            if (idx)
                app.put(' ');
            printInto(app, c);
        }
        app.put(')');
        break;
    }
}
