/// A small tokenizer and parsers for the `CREATE TABLE` and `CREATE INDEX`
/// statements stored in `sqlite_schema` (SPEC Part 2).
module sqlitefile.ddl;

import sqlitefile.affinity;
import sqlitefile.errors;

@safe:

/// Lexical token classes.
enum TokenKind : ubyte
{
    word, /// run of `[A-Za-z0-9_$]` (and non-ASCII bytes)
    quoted, /// `"…"`, `` `…` `` or `[…]`; `text` is unescaped
    string_, /// `'…'`
    punct, /// one of `( ) , . ;`
    other, /// any other single character
}

/// A lexical token.
struct Token
{
    TokenKind kind;
    string text;

    /// True if this is the unquoted keyword `kw` (given upper-case).
    bool isKeyword(string kw) const pure
    {
        return kind == TokenKind.word && asciiEqualFold(text, kw);
    }

    /// True if this is the punctuation character `c`.
    bool isPunct(char c) const pure nothrow @nogc
    {
        return kind == TokenKind.punct && text.length == 1 && text[0] == c;
    }
}

/// ASCII case-insensitive equality (`b` is expected in upper case).
bool asciiEqualFold(const(char)[] a, const(char)[] b) pure nothrow @nogc
{
    if (a.length != b.length)
        return false;
    foreach (i; 0 .. a.length)
    {
        char x = a[i], y = b[i];
        if (x >= 'a' && x <= 'z')
            x -= 32;
        if (y >= 'a' && y <= 'z')
            y -= 32;
        if (x != y)
            return false;
    }
    return true;
}

private bool isWordChar(char c) pure nothrow @nogc
{
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
        || c == '_' || c == '$' || c >= 0x80;
}

/// Splits SQL text into tokens, skipping whitespace and comments.
Token[] tokenize(string sql) pure
{
    Token[] toks;
    size_t i = 0;
    const n = sql.length;
    while (i < n)
    {
        const c = sql[i];
        if (c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' || c == '\v')
        {
            i++;
        }
        else if (c == '-' && i + 1 < n && sql[i + 1] == '-')
        {
            while (i < n && sql[i] != '\n')
                i++;
        }
        else if (c == '/' && i + 1 < n && sql[i + 1] == '*')
        {
            i += 2;
            while (i < n && !(sql[i] == '*' && i + 1 < n && sql[i + 1] == '/'))
                i++;
            i = i + 2 > n ? n : i + 2;
        }
        else if (isWordChar(c))
        {
            const s = i;
            while (i < n && isWordChar(sql[i]))
                i++;
            toks ~= Token(TokenKind.word, sql[s .. i]);
        }
        else if (c == '"' || c == '`' || c == '\'')
        {
            const kind = c == '\'' ? TokenKind.string_ : TokenKind.quoted;
            i++;
            char[] buf;
            while (i < n)
            {
                if (sql[i] == c)
                {
                    if (i + 1 < n && sql[i + 1] == c)
                    {
                        buf ~= c;
                        i += 2;
                        continue;
                    }
                    break;
                }
                buf ~= sql[i++];
            }
            i++; // closing quote
            toks ~= Token(kind, buf.idup);
        }
        else if (c == '[')
        {
            const s = ++i;
            while (i < n && sql[i] != ']')
                i++;
            toks ~= Token(TokenKind.quoted, sql[s .. i]);
            i++;
        }
        else if (c == '(' || c == ')' || c == ',' || c == '.' || c == ';')
        {
            toks ~= Token(TokenKind.punct, sql[i .. i + 1]);
            i++;
        }
        else
        {
            toks ~= Token(TokenKind.other, sql[i .. i + 1]);
            i++;
        }
    }
    return toks;
}

/// One column of a table definition.
struct ColumnDef
{
    string name;
    string declaredType; /// e.g. `NVARCHAR(160)`; empty if none
    Affinity affinity;
    bool isRowidAlias; /// an `INTEGER PRIMARY KEY` alias for the rowid
}

/// A parsed `CREATE TABLE`.
struct TableDef
{
    string name;
    ColumnDef[] columns;
}

/// A parsed `CREATE INDEX`.
struct IndexDef
{
    string name;
    string table;
    string[] columns;
}

private immutable columnTypeStoppers = [
    "CONSTRAINT", "PRIMARY", "NOT", "NULL", "UNIQUE", "CHECK", "DEFAULT",
    "COLLATE", "REFERENCES", "GENERATED", "AS", "AUTOINCREMENT"
];

private bool isTypeStopper(in Token t) pure
{
    if (t.kind != TokenKind.word)
        return false;
    foreach (k; columnTypeStoppers)
        if (asciiEqualFold(t.text, k))
            return true;
    return false;
}

/// Skips `[schema .] name` at `toks[p]`, returning the (last) name.
private string readQualifiedName(const Token[] toks, ref size_t p)
{
    if (p >= toks.length || (toks[p].kind != TokenKind.word && toks[p].kind != TokenKind.quoted))
        throw new SchemaException("expected a name");
    string name = toks[p++].text;
    if (p + 1 < toks.length && toks[p].isPunct('.'))
    {
        p++;
        if (toks[p].kind != TokenKind.word && toks[p].kind != TokenKind.quoted)
            throw new SchemaException("expected a name after '.'");
        name = toks[p++].text;
    }
    return name;
}

/// Splits the tokens after `toks[p]` (which must be `(`) into the items
/// separated by depth-0 commas, up to the matching `)`. `p` is left after it.
private const(Token)[][] splitParenthesised(const Token[] toks, ref size_t p)
{
    if (p >= toks.length || !toks[p].isPunct('('))
        throw new SchemaException("expected '('");
    p++;
    const(Token)[][] items;
    size_t start = p;
    int depth = 0;
    for (; p < toks.length; p++)
    {
        const t = toks[p];
        if (t.isPunct('('))
            depth++;
        else if (t.isPunct(')'))
        {
            if (depth == 0)
            {
                items ~= toks[start .. p];
                p++;
                return items;
            }
            depth--;
        }
        else if (t.isPunct(',') && depth == 0)
        {
            items ~= toks[start .. p];
            start = p + 1;
        }
    }
    throw new SchemaException("unbalanced parentheses");
}

/// Parses a `CREATE TABLE` statement.
TableDef parseCreateTable(string sql)
{
    const toks = tokenize(sql);
    size_t p = 0;
    if (p >= toks.length || !toks[p++].isKeyword("CREATE"))
        throw new SchemaException("expected CREATE");
    if (p < toks.length && (toks[p].isKeyword("TEMP") || toks[p].isKeyword("TEMPORARY")))
        p++;
    if (p >= toks.length || !toks[p++].isKeyword("TABLE"))
        throw new SchemaException("expected TABLE");
    if (p + 2 < toks.length && toks[p].isKeyword("IF") && toks[p + 1].isKeyword("NOT")
            && toks[p + 2].isKeyword("EXISTS"))
        p += 3;
    TableDef def;
    def.name = readQualifiedName(toks, p);
    const items = splitParenthesised(toks, p);

    // Names of columns that a table-level PRIMARY KEY(...) of exactly one
    // column designates.
    string tablePk;
    foreach (item; items)
    {
        if (item.length == 0)
            throw new SchemaException("empty item in table definition");
        const first = item[0];
        const isConstraint = first.isKeyword("CONSTRAINT") || first.isKeyword("PRIMARY")
            || first.isKeyword("UNIQUE") || first.isKeyword("CHECK") || first.isKeyword("FOREIGN");
        if (isConstraint)
        {
            string pk;
            if (tableConstraintPrimaryKey(item, pk))
                tablePk = pk;
            continue;
        }
        def.columns ~= parseColumnDef(item);
    }
    if (tablePk.length)
        foreach (ref c; def.columns)
            if (asciiEqualFold(c.name, tablePk) && isExactlyInteger(c))
                c.isRowidAlias = true;
    return def;
}

private bool isExactlyInteger(in ColumnDef c) pure
{
    return asciiEqualFold(c.declaredType, "INTEGER");
}

/// If the table constraint `item` is `[CONSTRAINT n] PRIMARY KEY (<one column>
/// …)`, stores that column's name in `column`.
private bool tableConstraintPrimaryKey(const(Token)[] item, out string column)
{
    int depth = 0;
    foreach (k, t; item)
    {
        if (t.isPunct('('))
            depth++;
        else if (t.isPunct(')'))
            depth--;
        else if (depth == 0 && t.isKeyword("PRIMARY") && k + 2 < item.length
                && item[k + 1].isKeyword("KEY") && item[k + 2].isPunct('('))
        {
            size_t q = k + 2;
            const cols = splitParenthesised(item, q);
            if (cols.length == 1 && cols[0].length >= 1
                    && (cols[0][0].kind == TokenKind.word || cols[0][0].kind == TokenKind.quoted))
            {
                column = cols[0][0].text;
                return true;
            }
            return false;
        }
    }
    return false;
}

private ColumnDef parseColumnDef(const(Token)[] item)
{
    ColumnDef c;
    if (item[0].kind != TokenKind.word && item[0].kind != TokenKind.quoted)
        throw new SchemaException("expected a column name");
    c.name = item[0].text;

    // declared type: tokens up to the first unquoted constraint keyword
    size_t k = 1;
    string type;
    int depth = 0;
    for (; k < item.length; k++)
    {
        const t = item[k];
        if (depth == 0 && isTypeStopper(t))
            break;
        if (t.isPunct('('))
            depth++;
        else if (t.isPunct(')'))
            depth--;
        if (t.kind == TokenKind.word || t.kind == TokenKind.quoted || t.kind == TokenKind.string_
                || t.kind == TokenKind.other)
        {
            if (type.length && type[$ - 1] != '(' && type[$ - 1] != ',' && type[$ - 1] != '.')
                type ~= ' ';
            type ~= t.text;
        }
        else
            type ~= t.text;
    }
    c.declaredType = type;
    c.affinity = affinityOf(type);

    // column-level PRIMARY KEY [DESC]
    depth = 0;
    for (size_t j = k; j < item.length; j++)
    {
        const t = item[j];
        if (t.isPunct('('))
            depth++;
        else if (t.isPunct(')'))
            depth--;
        else if (depth == 0 && t.isKeyword("PRIMARY") && j + 1 < item.length
                && item[j + 1].isKeyword("KEY"))
        {
            const desc = j + 2 < item.length && item[j + 2].isKeyword("DESC");
            if (!desc && isExactlyInteger(c))
                c.isRowidAlias = true;
            break;
        }
    }
    return c;
}

/// Parses a `CREATE [UNIQUE] INDEX` statement.
IndexDef parseCreateIndex(string sql)
{
    const toks = tokenize(sql);
    size_t p = 0;
    if (p >= toks.length || !toks[p++].isKeyword("CREATE"))
        throw new SchemaException("expected CREATE");
    if (p < toks.length && toks[p].isKeyword("UNIQUE"))
        p++;
    if (p >= toks.length || !toks[p++].isKeyword("INDEX"))
        throw new SchemaException("expected INDEX");
    if (p + 2 < toks.length && toks[p].isKeyword("IF") && toks[p + 1].isKeyword("NOT")
            && toks[p + 2].isKeyword("EXISTS"))
        p += 3;
    IndexDef def;
    def.name = readQualifiedName(toks, p);
    if (p >= toks.length || !toks[p++].isKeyword("ON"))
        throw new SchemaException("expected ON");
    def.table = readQualifiedName(toks, p);
    foreach (item; splitParenthesised(toks, p))
    {
        if (item.length == 0 || (item[0].kind != TokenKind.word && item[0].kind != TokenKind.quoted))
            throw new SchemaException("unsupported index column");
        def.columns ~= item[0].text;
    }
    return def;
}

unittest
{
    auto t = tokenize("CREATE TABLE \"a\"\"b\"([x y], `z`) -- c\n/* d */ 'it''s'");
    assert(t[2].kind == TokenKind.quoted && t[2].text == `a"b`);
    assert(t[4].text == "x y");
    assert(t[6].text == "z");
    assert(t[$ - 1].kind == TokenKind.string_ && t[$ - 1].text == "it's");
}

unittest
{
    auto d = parseCreateTable(`CREATE TABLE people(
        id INTEGER PRIMARY KEY,
        name TEXT NOT NULL,
        price NUMERIC(10,2) DEFAULT 'a,b',
        photo BLOB, untyped)`);
    assert(d.name == "people");
    assert(d.columns.length == 5);
    assert(d.columns[0].isRowidAlias && d.columns[0].affinity == Affinity.integer);
    assert(d.columns[1].declaredType == "TEXT" && d.columns[1].affinity == Affinity.text);
    assert(d.columns[2].declaredType == "NUMERIC(10,2)" && d.columns[2].affinity == Affinity.numeric);
    assert(d.columns[4].declaredType == "" && d.columns[4].affinity == Affinity.blob);
}

unittest
{
    // rowid-alias shapes (SPEC §2.2)
    bool alias_(string sql, size_t col = 0)
    {
        return parseCreateTable(sql).columns[col].isRowidAlias;
    }

    assert(alias_("CREATE TABLE t(x INTEGER PRIMARY KEY)"));
    assert(alias_("CREATE TABLE t(x integer primary key asc)"));
    assert(alias_("CREATE TABLE t(x INTEGER PRIMARY KEY AUTOINCREMENT)"));
    assert(!alias_("CREATE TABLE t(x INTEGER PRIMARY KEY DESC)"));
    assert(alias_("CREATE TABLE t(x INTEGER, PRIMARY KEY(x DESC))"));
    assert(alias_("CREATE TABLE t([A] INTEGER NOT NULL, CONSTRAINT [PK] PRIMARY KEY ([a]))"));
    assert(!alias_("CREATE TABLE t(x INT PRIMARY KEY)"));
    assert(!alias_("CREATE TABLE t(x INTEGER(4) PRIMARY KEY)"));
    assert(!alias_("CREATE TABLE t(x INTEGER, y INTEGER, PRIMARY KEY(x, y))"));
    assert(!alias_("CREATE TABLE t(x TEXT PRIMARY KEY)"));
    assert(!alias_("CREATE TABLE t(x INTEGER CHECK(x > 0 AND y PRIMARY KEY))"));
    assert(alias_("CREATE TABLE t(a TEXT, b INTEGER, PRIMARY KEY(b))", 1));
    assert(!alias_("CREATE TABLE t(a TEXT, b INTEGER, PRIMARY KEY(b))", 0));
    assert(alias_("CREATE TEMP TABLE IF NOT EXISTS main.t(x INTEGER PRIMARY KEY)"));
}

unittest
{
    auto d = parseCreateIndex(`CREATE UNIQUE INDEX IF NOT EXISTS "main"."ix" ON t ( a COLLATE BINARY DESC, [b c] )`);
    assert(d.name == "ix" && d.table == "t");
    assert(d.columns == ["a", "b c"]);
    import std.exception : assertThrown;

    assertThrown!SchemaException(parseCreateIndex("CREATE TABLE x(a)"));
    assertThrown!SchemaException(parseCreateTable("CREATE VIEW v AS SELECT 1"));
}
