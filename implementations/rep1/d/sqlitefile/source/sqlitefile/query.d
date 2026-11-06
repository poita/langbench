/// Parser for the five-command query language (SPEC Part 4).
module sqlitefile.query;

import sqlitefile.affinity;
import sqlitefile.errors;
import sqlitefile.value;

@safe:

/// Which command a query line is.
enum QueryKind : ubyte
{
    tables,
    schema,
    count,
    select,
    index,
}

/// Comparison operators allowed in `WHERE`.
enum CmpOp : ubyte
{
    eq,
    ne,
    lt,
    le,
    gt,
    ge,
    is_,
    isNot,
}

/// One `<column> <op> <literal>` condition.
struct Condition
{
    string column;
    CmpOp op;
    Value literal;
}

/// A parsed query line. Which fields are meaningful depends on `kind`.
struct Query
{
    QueryKind kind;
    /// Table name (`schema`, `count`, `select`) or index name (`index`).
    string name;
    /// `select`: `*` was given.
    bool star;
    /// `select`: the column list when `star` is false.
    string[] columns;
    Condition[] where;
    bool hasOrder;
    string orderColumn;
    bool descending;
    bool hasLimit;
    long limit;
    /// `index`: the lookup key.
    Value literal;
}

private bool isWordChar(char c) pure nothrow @nogc
{
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_';
}

private bool isDigit(char c) pure nothrow @nogc
{
    return c >= '0' && c <= '9';
}

private bool equalsCI(const(char)[] a, const(char)[] b) pure nothrow @nogc
{
    if (a.length != b.length)
        return false;
    foreach (i; 0 .. a.length)
    {
        char x = a[i], y = b[i];
        if (x >= 'A' && x <= 'Z')
            x += 32;
        if (y >= 'A' && y <= 'Z')
            y += 32;
        if (x != y)
            return false;
    }
    return true;
}

/// A single-pass scanner over one query line.
private struct Cursor
{
    string s;
    size_t pos;

    static QueryException fail(string why = "malformed query") pure
    {
        return new QueryException(why);
    }

    bool atEnd() const pure nothrow @nogc
    {
        return pos >= s.length;
    }

    char peek() const pure nothrow @nogc
    {
        return pos < s.length ? s[pos] : '\0';
    }

    void skipWs() pure nothrow @nogc
    {
        while (pos < s.length && (s[pos] == ' ' || s[pos] == '\t'))
            pos++;
    }

    /// The maximal run of `[A-Za-z0-9_]` at the cursor (consumed); may be empty.
    string word() pure nothrow @nogc
    {
        immutable b = pos;
        while (pos < s.length && isWordChar(s[pos]))
            pos++;
        return s[b .. pos];
    }

    /// Consumes `kw` (a whole word, ASCII case-insensitive) if it is next.
    bool eatKeyword(string kw) pure nothrow @nogc
    {
        immutable save = pos;
        if (equalsCI(word(), kw))
            return true;
        pos = save;
        return false;
    }

    void expectKeyword(string kw) pure
    {
        if (!eatKeyword(kw))
            throw fail();
    }

    /// An identifier: `[A-Za-z_][A-Za-z0-9_]*`.
    string ident() pure
    {
        auto w = word();
        if (w.length == 0 || isDigit(w[0]))
            throw fail();
        return w;
    }

    bool eatChar(char c) pure nothrow @nogc
    {
        if (peek() == c && !atEnd)
        {
            pos++;
            return true;
        }
        return false;
    }

    void expectEnd() pure
    {
        skipWs();
        if (!atEnd)
            throw fail("trailing text");
    }

    /// A literal: numeral, `'string'`, `X'hex'` or `NULL`.
    Value literal()
    {
        immutable c = peek();
        if (c == '\'')
        {
            pos++;
            ubyte[] text;
            while (true)
            {
                if (atEnd)
                    throw fail("unterminated string");
                immutable ch = s[pos++];
                if (ch == '\'')
                {
                    if (peek() == '\'' && !atEnd)
                    {
                        text ~= cast(ubyte) '\'';
                        pos++;
                        continue;
                    }
                    break;
                }
                text ~= cast(ubyte) ch;
            }
            return Value.makeText(text);
        }
        if ((c == 'x' || c == 'X') && pos + 1 < s.length && s[pos + 1] == '\'')
        {
            pos += 2;
            ubyte[] bytes;
            while (true)
            {
                if (atEnd)
                    throw fail("unterminated blob");
                if (s[pos] == '\'')
                {
                    pos++;
                    break;
                }
                if (pos + 1 >= s.length)
                    throw fail("bad blob");
                immutable hi = hexVal(s[pos]), lo = hexVal(s[pos + 1]);
                if (hi < 0 || lo < 0)
                    throw fail("bad blob");
                bytes ~= cast(ubyte)(hi * 16 + lo);
                pos += 2;
            }
            return Value.makeBlob(bytes);
        }
        if (c == '+' || c == '-' || isDigit(c))
            return numeral();
        auto w = word();
        if (equalsCI(w, "NULL"))
            return Value.makeNull();
        throw fail("bad literal");
    }

    private static int hexVal(char c) pure nothrow @nogc
    {
        if (c >= '0' && c <= '9')
            return c - '0';
        if (c >= 'a' && c <= 'f')
            return c - 'a' + 10;
        if (c >= 'A' && c <= 'F')
            return c - 'A' + 10;
        return -1;
    }

    private Value numeral()
    {
        immutable b = pos;
        if (peek() == '+' || peek() == '-')
            pos++;
        immutable ds = pos;
        while (isDigit(peek()))
            pos++;
        if (pos == ds)
            throw fail("bad numeral");
        if (peek() == '.')
        {
            pos++;
            while (isDigit(peek()))
                pos++;
        }
        if (peek() == 'e' || peek() == 'E')
        {
            pos++;
            if (peek() == '+' || peek() == '-')
                pos++;
            immutable es = pos;
            while (isDigit(peek()))
                pos++;
            if (pos == es)
                throw fail("bad exponent");
        }
        if (isWordChar(peek()))
            throw fail("bad numeral");
        Value v;
        if (!(() @trusted => parseNumericConstant(s[b .. pos], v))())
            throw fail("bad numeral");
        return v;
    }

    /// `<column> <op> <literal>`
    Condition condition()
    {
        Condition cond;
        cond.column = ident();
        skipWs();
        immutable c = peek();
        if (c == '=')
        {
            pos++;
            cond.op = CmpOp.eq;
        }
        else if (c == '!')
        {
            pos++;
            if (!eatChar('='))
                throw fail();
            cond.op = CmpOp.ne;
        }
        else if (c == '<')
        {
            pos++;
            cond.op = eatChar('=') ? CmpOp.le : CmpOp.lt;
        }
        else if (c == '>')
        {
            pos++;
            cond.op = eatChar('=') ? CmpOp.ge : CmpOp.gt;
        }
        else if (eatKeyword("IS"))
        {
            skipWs();
            cond.op = eatKeyword("NOT") ? CmpOp.isNot : CmpOp.is_;
        }
        else
            throw fail("unknown operator");
        skipWs();
        cond.literal = literal();
        return cond;
    }
}

/// Parses one query line; throws `QueryException` if it is not a valid command.
Query parseQuery(string line)
{
    Query q;
    if (line.length > 0 && line[0] == '.')
    {
        if (line == ".tables")
        {
            q.kind = QueryKind.tables;
            return q;
        }
        if (line.length > 8 && line[0 .. 8] == ".schema ")
        {
            auto c = Cursor(line, 8);
            q.kind = QueryKind.schema;
            q.name = c.ident();
            if (!c.atEnd)
                throw Cursor.fail();
            return q;
        }
        throw Cursor.fail("unknown dot command");
    }
    auto c = Cursor(line, 0);
    auto cmd = c.word();
    if (equalsCI(cmd, "COUNT"))
    {
        q.kind = QueryKind.count;
        c.skipWs();
        q.name = c.ident();
        c.expectEnd();
    }
    else if (equalsCI(cmd, "INDEX"))
    {
        q.kind = QueryKind.index;
        c.skipWs();
        q.name = c.ident();
        c.skipWs();
        q.literal = c.literal();
        c.expectEnd();
    }
    else if (equalsCI(cmd, "SELECT"))
    {
        q.kind = QueryKind.select;
        c.skipWs();
        if (c.eatChar('*'))
            q.star = true;
        else
        {
            while (true)
            {
                q.columns ~= c.ident();
                c.skipWs();
                if (!c.eatChar(','))
                    break;
                c.skipWs();
            }
        }
        c.skipWs();
        c.expectKeyword("FROM");
        c.skipWs();
        q.name = c.ident();
        c.skipWs();
        if (c.eatKeyword("WHERE"))
        {
            c.skipWs();
            while (true)
            {
                q.where ~= c.condition();
                c.skipWs();
                if (!c.eatKeyword("AND"))
                    break;
                c.skipWs();
            }
        }
        if (c.eatKeyword("ORDER"))
        {
            c.skipWs();
            c.expectKeyword("BY");
            c.skipWs();
            q.hasOrder = true;
            q.orderColumn = c.ident();
            c.skipWs();
            if (c.eatKeyword("DESC"))
                q.descending = true;
            else
                c.eatKeyword("ASC");
            c.skipWs();
        }
        if (c.eatKeyword("LIMIT"))
        {
            c.skipWs();
            auto w = c.word();
            if (w.length == 0)
                throw Cursor.fail();
            ulong n = 0;
            foreach (ch; w)
            {
                if (!isDigit(ch))
                    throw Cursor.fail();
                immutable d = ch - '0';
                if (n > (cast(ulong) long.max - d) / 10)
                    throw Cursor.fail("limit too large");
                n = n * 10 + d;
            }
            q.hasLimit = true;
            q.limit = cast(long) n;
        }
        c.expectEnd();
    }
    else
        throw Cursor.fail("unknown command");
    return q;
}
