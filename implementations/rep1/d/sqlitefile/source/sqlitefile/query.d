/// Parser for the five-command query language (SPEC Part 4).
module sqlitefile.query;

import sqlitefile.ddl : asciiEqualFold;
import sqlitefile.errors;
import sqlitefile.numeric;
import sqlitefile.value;

@safe:

/// The command a query line invokes.
enum QueryKind : ubyte
{
    tables, /// `.tables`
    schema, /// `.schema <table>`
    count, /// `COUNT <table>`
    select, /// `SELECT …`
    index, /// `INDEX <name> <literal>`
}

/// Comparison operators usable in `WHERE`.
enum CompareOp : ubyte
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

/// `<column> <op> <literal>`
struct Condition
{
    string column;
    CompareOp op;
    Value literal;
}

/// A parsed query line.
struct Query
{
    QueryKind kind;
    string name; /// table (schema, count, select) or index (index) name
    bool star; /// `SELECT *`
    string[] columns; /// select list when not `star`
    Condition[] where;
    bool hasOrder;
    string orderColumn;
    bool orderDesc;
    bool hasLimit;
    long limit;
    Value literal; /// the key of an `INDEX` query
}

private bool isIdentStart(char c) pure nothrow @nogc
{
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_';
}

private bool isWordChar(char c) pure nothrow @nogc
{
    return isIdentStart(c) || (c >= '0' && c <= '9');
}

private struct Scanner
{
    string s;
    size_t pos;

    bool atEnd() const pure nothrow @nogc
    {
        return pos >= s.length;
    }

    char peek() const pure nothrow @nogc
    {
        return pos < s.length ? s[pos] : '\0';
    }

    void skipBlanks() pure nothrow @nogc
    {
        while (pos < s.length && (s[pos] == ' ' || s[pos] == '\t'))
            pos++;
    }

    /// Reads a maximal run of word characters (possibly empty).
    string word() pure nothrow @nogc
    {
        const b = pos;
        while (pos < s.length && isWordChar(s[pos]))
            pos++;
        return s[b .. pos];
    }

    /// Reads a word that must equal the keyword `kw`.
    bool keyword(string kw) pure nothrow @nogc
    {
        const save = pos;
        if (asciiEqualFold(word(), kw))
            return true;
        pos = save;
        return false;
    }

    /// Reads an identifier (a word beginning with a letter or `_`).
    string identifier() pure
    {
        const w = word();
        if (w.length == 0 || !isIdentStart(w[0]))
            throw new QueryException("expected an identifier");
        return w;
    }
}

private void fail(string why) pure
{
    throw new QueryException(why);
}

/// Parses one query line. Throws `QueryException` if it is malformed.
Query parseQuery(string line)
{
    Query q;
    if (line.length && line[0] == '.')
        return parseDotCommand(line);
    auto sc = Scanner(line, 0);
    sc.skipBlanks();
    if (sc.keyword("SELECT"))
    {
        q.kind = QueryKind.select;
        parseSelect(sc, q);
    }
    else if (sc.keyword("COUNT"))
    {
        q.kind = QueryKind.count;
        sc.skipBlanks();
        q.name = sc.identifier();
    }
    else if (sc.keyword("INDEX"))
    {
        q.kind = QueryKind.index;
        sc.skipBlanks();
        q.name = sc.identifier();
        sc.skipBlanks();
        q.literal = parseLiteral(sc);
    }
    else
        fail("unknown command");
    sc.skipBlanks();
    if (!sc.atEnd())
        fail("trailing text");
    return q;
}

private Query parseDotCommand(string line)
{
    Query q;
    // Split on blanks.
    string[] parts;
    size_t i = 0;
    while (i < line.length)
    {
        while (i < line.length && (line[i] == ' ' || line[i] == '\t'))
            i++;
        const b = i;
        while (i < line.length && line[i] != ' ' && line[i] != '\t')
            i++;
        if (i > b)
            parts ~= line[b .. i];
    }
    if (parts[0] == ".tables" && parts.length == 1)
    {
        q.kind = QueryKind.tables;
    }
    else if (parts[0] == ".schema" && parts.length == 2)
    {
        auto sc = Scanner(parts[1], 0);
        q.name = sc.identifier();
        if (!sc.atEnd())
            fail("argument is not a bare identifier");
        q.kind = QueryKind.schema;
    }
    else
        fail("unknown or malformed dot command");
    return q;
}

private void parseSelect(ref Scanner sc, ref Query q)
{
    sc.skipBlanks();
    if (sc.peek() == '*')
    {
        sc.pos++;
        q.star = true;
    }
    else
    {
        while (true)
        {
            sc.skipBlanks();
            q.columns ~= sc.identifier();
            sc.skipBlanks();
            if (sc.peek() == ',')
            {
                sc.pos++;
                continue;
            }
            break;
        }
    }
    sc.skipBlanks();
    if (!sc.keyword("FROM"))
        fail("expected FROM");
    sc.skipBlanks();
    q.name = sc.identifier();
    sc.skipBlanks();

    if (sc.keyword("WHERE"))
    {
        while (true)
        {
            sc.skipBlanks();
            q.where ~= parseCondition(sc);
            sc.skipBlanks();
            if (sc.keyword("AND"))
                continue;
            break;
        }
        sc.skipBlanks();
    }
    if (sc.keyword("ORDER"))
    {
        sc.skipBlanks();
        if (!sc.keyword("BY"))
            fail("expected BY");
        sc.skipBlanks();
        q.hasOrder = true;
        q.orderColumn = sc.identifier();
        sc.skipBlanks();
        if (sc.keyword("DESC"))
            q.orderDesc = true;
        else
            sc.keyword("ASC");
        sc.skipBlanks();
    }
    if (sc.keyword("LIMIT"))
    {
        sc.skipBlanks();
        const w = sc.word();
        if (w.length == 0)
            fail("expected a number after LIMIT");
        long n = 0;
        foreach (c; w)
        {
            if (c < '0' || c > '9')
                fail("LIMIT must be an unsigned integer");
            const d = c - '0';
            if (n > (long.max - d) / 10)
                fail("LIMIT out of range");
            n = n * 10 + d;
        }
        q.hasLimit = true;
        q.limit = n;
    }
}

private Condition parseCondition(ref Scanner sc)
{
    Condition c;
    c.column = sc.identifier();
    sc.skipBlanks();
    const ch = sc.peek();
    const next = sc.pos + 1 < sc.s.length ? sc.s[sc.pos + 1] : '\0';
    if (ch == '=')
    {
        c.op = CompareOp.eq;
        sc.pos++;
    }
    else if (ch == '!' && next == '=')
    {
        c.op = CompareOp.ne;
        sc.pos += 2;
    }
    else if (ch == '<' && next == '=')
    {
        c.op = CompareOp.le;
        sc.pos += 2;
    }
    else if (ch == '>' && next == '=')
    {
        c.op = CompareOp.ge;
        sc.pos += 2;
    }
    else if (ch == '<')
    {
        c.op = CompareOp.lt;
        sc.pos++;
    }
    else if (ch == '>')
    {
        c.op = CompareOp.gt;
        sc.pos++;
    }
    else if (sc.keyword("IS"))
    {
        c.op = CompareOp.is_;
        // `IS NOT` only if NOT is a whole word followed by a literal.
        const save = sc.pos;
        sc.skipBlanks();
        if (sc.keyword("NOT"))
            c.op = CompareOp.isNot;
        else
            sc.pos = save;
    }
    else
        fail("unsupported operator");
    sc.skipBlanks();
    c.literal = parseLiteral(sc);
    return c;
}

/// Parses a numeral, string, blob or NULL literal at the scanner position.
private Value parseLiteral(ref Scanner sc)
{
    const ch = sc.peek();
    if (ch == '\'')
    {
        return Value.fromText(parseQuoted(sc));
    }
    if ((ch == 'x' || ch == 'X') && sc.pos + 1 < sc.s.length && sc.s[sc.pos + 1] == '\'')
    {
        sc.pos++;
        const hex = parseQuoted(sc);
        if (hex.length % 2 != 0)
            fail("odd number of hex digits");
        auto bytes = new ubyte[hex.length / 2];
        static int nibble(char c) pure nothrow @nogc
        {
            if (c >= '0' && c <= '9')
                return c - '0';
            if (c >= 'a' && c <= 'f')
                return c - 'a' + 10;
            if (c >= 'A' && c <= 'F')
                return c - 'A' + 10;
            return -1;
        }

        foreach (i; 0 .. bytes.length)
        {
            const hi = nibble(hex[2 * i]), lo = nibble(hex[2 * i + 1]);
            if (hi < 0 || lo < 0)
                fail("non-hex character in blob literal");
            bytes[i] = cast(ubyte)(hi * 16 + lo);
        }
        return Value.fromBlob(bytes);
    }
    if (isWordChar(ch) && !(ch >= '0' && ch <= '9'))
    {
        if (sc.keyword("NULL"))
            return Value.makeNull();
        fail("malformed literal");
    }
    bool isReal;
    const end = matchNumber(sc.s, sc.pos, false, isReal);
    if (end == sc.pos)
        fail("malformed literal");
    const text = sc.s[sc.pos .. end];
    // A numeral ending in a digit must not run into another word character.
    const last = text[$ - 1];
    if (last != '.' && end < sc.s.length && isWordChar(sc.s[end]))
        fail("malformed numeral");
    sc.pos = end;
    return numberFromText(text, isReal);
}

/// Parses `'…'` (with `''` as an escaped quote) at the scanner position.
private string parseQuoted(ref Scanner sc) pure
{
    assert(sc.peek() == '\'');
    sc.pos++;
    char[] buf;
    while (true)
    {
        if (sc.atEnd())
            fail("unterminated string");
        const c = sc.s[sc.pos++];
        if (c == '\'')
        {
            if (sc.peek() == '\'')
            {
                buf ~= '\'';
                sc.pos++;
                continue;
            }
            break;
        }
        buf ~= c;
    }
    return cast(string) buf.idup;
}

unittest
{
    import std.exception : assertThrown;

    auto q = parseQuery("SELECT*FROM t");
    assert(q.kind == QueryKind.select && q.star && q.name == "t");
    q = parseQuery("select a ,\tb  FROM  people where a>=1 AND b IS NOT NULL and c is 'x' order by a desc limit 5");
    assert(q.columns == ["a", "b"] && q.where.length == 3);
    assert(q.where[0].op == CompareOp.ge && q.where[0].literal.i == 1);
    assert(q.where[1].op == CompareOp.isNot && q.where[1].literal.isNull);
    assert(q.where[2].op == CompareOp.is_ && q.where[2].literal.type == ValueType.text);
    assert(q.hasOrder && q.orderDesc && q.orderColumn == "a" && q.hasLimit && q.limit == 5);
    q = parseQuery("SELECT a FROM t WHERE a='it''s'AND b<-2.5e-3");
    assert(q.where[0].literal.bytes == cast(const(ubyte)[]) "it's");
    assert(q.where[1].op == CompareOp.lt && q.where[1].literal.type == ValueType.real_);
    q = parseQuery("SELECT a FROM t WHERE a=X'00ff' AND b=x''");
    assert(q.where[0].literal.bytes == [cast(ubyte) 0, 0xff]);
    q = parseQuery("SELECT a FROM t WHERE a>1.AND b=1");
    assert(q.where.length == 2);
    q = parseQuery("COUNT people");
    assert(q.kind == QueryKind.count && q.name == "people");
    q = parseQuery("INDEX idx 'abc'");
    assert(q.kind == QueryKind.index && q.literal.bytes == cast(const(ubyte)[]) "abc");
    q = parseQuery("INDEX idx-5");
    assert(q.literal.i == -5);
    assert(parseQuery(".tables").kind == QueryKind.tables);
    q = parseQuery(".schema people");
    assert(q.kind == QueryKind.schema && q.name == "people");

    foreach (bad; [
            "SELECTa FROM t", "SELECT * FROM", "SELECT FROM t", "SELECT * FROM t ORDERBY a",
            "SELECT * FROM t LIMIT3", "SELECT * FROM t LIMIT -1", "SELECT * FROM t LIMIT x",
            "SELECT * FROM t ORDER BY a ASC DESC", "SELECT * FROM t WHERE a == 1",
            "SELECT * FROM t WHERE a <> 1", "SELECT * FROM t WHERE a = .5",
            "SELECT * FROM t WHERE a = 1e", "SELECT * FROM t WHERE a = 'x",
            "SELECT * FROM t WHERE a = x'0'", "SELECT * FROM t WHERE a = x'zz'",
            "SELECT * FROM t WHERE a = 5AND b = 1", "SELECT * FROM t WHERE a IS", "SELECT * FROM t WHERE a",
            "SELECT * FROM t WHERE a = 1 b", "SELECT * FROM t WHERE a ISNOT NULL",
            "SELECT 1 FROM t", "COUNT", "COUNT a b", "COUNT 9a", "INDEX idx", "INDEX idx5",
            ".SCHEMA t", ".schema", ".schema a b", ".schema people;", ".schema 9bad", ".tables x",
            ".dump", "DROP TABLE t", "select * from t;"
    ])
        assertThrown!QueryException(parseQuery(bad), bad);
}
