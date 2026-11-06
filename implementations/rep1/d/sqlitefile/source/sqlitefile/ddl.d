/// Parser for the `CREATE TABLE` and `CREATE INDEX` statements stored in
/// `sqlite_schema` (SPEC Part 2).
module sqlitefile.ddl;

import sqlitefile.affinity;
import sqlitefile.errors;

@safe:

/// Lexical class of a DDL token.
enum TokenKind : ubyte
{
    word, /// bare run of `[A-Za-z0-9_$]` (or non-ASCII bytes)
    quoted, /// "name", `name` or [name]; `text` is the unescaped content
    str, /// 'string literal'
    punct, /// any other single character
}

/// A DDL token.
struct Token
{
    TokenKind kind;
    string text;
}

private bool isWordChar(char c) pure nothrow @nogc
{
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
        || c == '_' || c == '$' || c >= 0x80;
}

/// Splits DDL text into tokens, dropping whitespace and `--` / `/* */` comments.
Token[] tokenize(string s) pure
{
    Token[] toks;
    size_t i = 0;
    while (i < s.length)
    {
        immutable c = s[i];
        if (c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' || c == '\v')
        {
            i++;
        }
        else if (c == '-' && i + 1 < s.length && s[i + 1] == '-')
        {
            while (i < s.length && s[i] != '\n')
                i++;
        }
        else if (c == '/' && i + 1 < s.length && s[i + 1] == '*')
        {
            i += 2;
            while (i < s.length && !(s[i] == '*' && i + 1 < s.length && s[i + 1] == '/'))
                i++;
            i += 2;
        }
        else if (isWordChar(c))
        {
            immutable b = i;
            while (i < s.length && isWordChar(s[i]))
                i++;
            toks ~= Token(TokenKind.word, s[b .. i]);
        }
        else if (c == '"' || c == '`' || c == '\'')
        {
            string text;
            i++;
            while (i < s.length)
            {
                if (s[i] == c)
                {
                    if (i + 1 < s.length && s[i + 1] == c)
                    {
                        text ~= c;
                        i += 2;
                        continue;
                    }
                    break;
                }
                text ~= s[i++];
            }
            i++; // closing quote
            toks ~= Token(c == '\'' ? TokenKind.str : TokenKind.quoted, text);
        }
        else if (c == '[')
        {
            immutable b = ++i;
            while (i < s.length && s[i] != ']')
                i++;
            toks ~= Token(TokenKind.quoted, s[b .. i]);
            i++;
        }
        else
        {
            toks ~= Token(TokenKind.punct, s[i .. i + 1]);
            i++;
        }
    }
    return toks;
}

/// ASCII case-insensitive string equality.
bool equalsCI(const(char)[] a, const(char)[] b) pure nothrow @nogc
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

private bool isKw(in Token t, string kw) pure nothrow @nogc
{
    return t.kind == TokenKind.word && equalsCI(t.text, kw);
}

private bool isPunct(in Token t, char c) pure nothrow @nogc
{
    return t.kind == TokenKind.punct && t.text[0] == c;
}

/// A column as declared in `CREATE TABLE`.
struct Column
{
    string name;
    string declaredType; /// tokens of the type joined by single spaces; may be empty
    Affinity affinity;
}

/// The result of parsing a `CREATE TABLE` statement.
struct TableDef
{
    string name;
    Column[] columns;
    /// Index of the column that aliases the rowid, or -1.
    int rowidAlias = -1;
}

/// The result of parsing a `CREATE INDEX` statement.
struct IndexDef
{
    string name;
    string table;
    string[] columns;
}

private immutable string[] typeStoppers = [
    "CONSTRAINT", "PRIMARY", "NOT", "NULL", "UNIQUE", "CHECK", "DEFAULT",
    "COLLATE", "REFERENCES", "GENERATED", "AS", "AUTOINCREMENT"
];

private bool endsType(in Token t) pure nothrow @nogc
{
    if (t.kind != TokenKind.word)
        return false;
    foreach (k; typeStoppers)
        if (equalsCI(t.text, k))
            return true;
    return false;
}

/// Position cursor over a token array with the little helpers both parsers need.
private struct TokenCursor
{
    Token[] toks;
    size_t pos;

    bool atEnd() const pure nothrow @nogc
    {
        return pos >= toks.length;
    }

    bool eatKw(string kw) pure nothrow @nogc
    {
        if (!atEnd && isKw(toks[pos], kw))
        {
            pos++;
            return true;
        }
        return false;
    }

    bool eatPunct(char c) pure nothrow @nogc
    {
        if (!atEnd && isPunct(toks[pos], c))
        {
            pos++;
            return true;
        }
        return false;
    }

    string name()
    {
        if (atEnd || (toks[pos].kind != TokenKind.word && toks[pos].kind != TokenKind.quoted))
            throw new FormatException("expected a name in schema SQL");
        return toks[pos++].text;
    }

    /// Reads `[schema.]name` and returns the final name.
    string qualifiedName()
    {
        auto n = name();
        if (eatPunct('.'))
            n = name();
        return n;
    }

    /// Reads the parenthesised body and splits it at depth-0 commas. The
    /// opening parenthesis must be the next token.
    Token[][] parenItems()
    {
        if (!eatPunct('('))
            throw new FormatException("expected '(' in schema SQL");
        Token[][] items;
        size_t depth = 0, start = pos;
        while (!atEnd)
        {
            auto t = toks[pos];
            if (isPunct(t, '('))
                depth++;
            else if (isPunct(t, ')'))
            {
                if (depth == 0)
                {
                    items ~= toks[start .. pos];
                    pos++;
                    return items;
                }
                depth--;
            }
            else if (isPunct(t, ',') && depth == 0)
            {
                items ~= toks[start .. pos];
                start = pos + 1;
            }
            pos++;
        }
        throw new FormatException("unbalanced parentheses in schema SQL");
    }
}

private bool isExactInteger(in Column c) pure nothrow @nogc
{
    return equalsCI(c.declaredType, "INTEGER");
}

/// Parses a `CREATE TABLE` statement: column names, declared types, affinities
/// and the rowid alias (SPEC §2.1–2.3).
TableDef parseCreateTable(string sql)
{
    auto c = TokenCursor(tokenize(sql));
    if (!c.eatKw("CREATE"))
        throw new FormatException("not a CREATE statement");
    if (!c.eatKw("TEMP"))
        c.eatKw("TEMPORARY");
    if (!c.eatKw("TABLE"))
        throw new FormatException("not a CREATE TABLE statement");
    if (c.eatKw("IF"))
    {
        c.eatKw("NOT");
        c.eatKw("EXISTS");
    }
    TableDef def;
    def.name = c.qualifiedName();
    auto items = c.parenItems();

    int tableLevelPk = -1; // set by a table-level PRIMARY KEY (<one column>)
    string tablePkName;
    bool hasTablePk = false;
    int columnPk = -1; // column-level PRIMARY KEY not followed by DESC
    foreach (item; items)
    {
        if (item.length == 0)
            continue;
        auto first = item[0];
        if (isKw(first, "CONSTRAINT") || isKw(first, "PRIMARY") || isKw(first, "UNIQUE")
            || isKw(first, "CHECK") || isKw(first, "FOREIGN"))
        {
            size_t k = 0;
            if (isKw(first, "CONSTRAINT"))
                k = 2;
            if (k + 2 < item.length && isKw(item[k], "PRIMARY") && isKw(item[k + 1], "KEY")
                && isPunct(item[k + 2], '('))
            {
                auto sub = TokenCursor(item, k + 2);
                auto cols = sub.parenItems();
                if (cols.length == 1 && cols[0].length > 0)
                {
                    hasTablePk = true;
                    tablePkName = cols[0][0].text;
                }
            }
            continue;
        }
        Column col;
        col.name = first.text;
        size_t k = 1;
        string type;
        while (k < item.length && !endsType(item[k]))
        {
            if (type.length)
                type ~= ' ';
            type ~= item[k].text;
            k++;
        }
        col.declaredType = type;
        col.affinity = affinityOf(type);
        for (size_t j = k; j + 1 < item.length; j++)
            if (isKw(item[j], "PRIMARY") && isKw(item[j + 1], "KEY"))
            {
                immutable desc = j + 2 < item.length && isKw(item[j + 2], "DESC");
                if (!desc && columnPk < 0)
                    columnPk = cast(int) def.columns.length;
                break;
            }
        def.columns ~= col;
    }
    if (columnPk >= 0 && isExactInteger(def.columns[columnPk]))
        def.rowidAlias = columnPk;
    else if (hasTablePk)
        foreach (i, ref col; def.columns)
            if (equalsCI(col.name, tablePkName))
            {
                if (isExactInteger(col))
                    def.rowidAlias = cast(int) i;
                break;
            }
    return def;
}

/// Parses a `CREATE INDEX` statement: index name, table and indexed column names.
IndexDef parseCreateIndex(string sql)
{
    auto c = TokenCursor(tokenize(sql));
    if (!c.eatKw("CREATE"))
        throw new FormatException("not a CREATE statement");
    c.eatKw("UNIQUE");
    if (!c.eatKw("INDEX"))
        throw new FormatException("not a CREATE INDEX statement");
    if (c.eatKw("IF"))
    {
        c.eatKw("NOT");
        c.eatKw("EXISTS");
    }
    IndexDef def;
    def.name = c.qualifiedName();
    if (!c.eatKw("ON"))
        throw new FormatException("expected ON in CREATE INDEX");
    def.table = c.name();
    foreach (item; c.parenItems())
        if (item.length > 0)
            def.columns ~= item[0].text;
    return def;
}
