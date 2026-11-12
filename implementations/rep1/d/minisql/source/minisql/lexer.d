/**
 * Tokenizer and statement splitter.
 *
 * The whole script is tokenized up front and cut into statements at `;`
 * tokens. Lexical problems (an invalid character, an oversized integer, an
 * unterminated string) do not abort lexing: they become tokens that no
 * grammar rule accepts, so only the statement containing them fails.
 */
module minisql.lexer;

/// Reserved words of the dialect.
enum Keyword : ubyte
{
    none,
    select, from, where, and, or, not, null_, is_, like, as, insert, into,
    values, delete_, update, set, create, table, integer, text, inner, join,
    on, group, by, having, order, asc, desc, limit, offset, left, right, full,
    outer, cross, natural,
}

/// The kind of a $(LREF Token).
enum TokenKind : ubyte
{
    ident,       /// identifier or keyword (see `Token.keyword`)
    integer,     /// non-negative integer literal
    string_,     /// string literal (quotes removed, `''` decoded)
    plus, minus, star, slash, percent,
    eq, ne, lt, le, gt, ge,
    lparen, rparen, comma, dot,
    invalid,     /// a character or literal that is not valid in the dialect
    unterminated,/// a string literal that is never closed
}

/// A lexical token.
struct Token
{
    TokenKind kind;
    /// For identifiers, the lower-cased name; for strings, the decoded text.
    string text;
    /// For integer literals, the value.
    long value;
    /// For identifiers, the keyword it spells (`Keyword.none` if it is a plain name).
    Keyword keyword;
}

/// The tokens of one statement, without its terminating `;`.
alias Statement = Token[];

private immutable Keyword[string] keywordTable;

shared static this()
{
    Keyword[string] t;
    foreach (name; __traits(allMembers, Keyword))
    {
        if (name == "none")
            continue;
        // Members with a trailing underscore (null_, is_, delete_) are spelled without it.
        string spelled = name[$ - 1] == '_' ? name[0 .. $ - 1] : name;
        t[spelled] = __traits(getMember, Keyword, name);
    }
    keywordTable = cast(immutable) t;
}

/// Looks up the keyword spelled by the lower-case word `lower`.
Keyword keywordOf(string lower) @safe nothrow
{
    if (auto p = lower in keywordTable)
        return *p;
    return Keyword.none;
}

private bool isIdentStart(char c) @safe pure nothrow @nogc
{
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_';
}

private bool isDigit(char c) @safe pure nothrow @nogc
{
    return c >= '0' && c <= '9';
}

private bool isSpace(char c) @safe pure nothrow @nogc
{
    return c == ' ' || c == '\t' || c == '\r' || c == '\n' || c == '\f' || c == '\v';
}

/**
 * Splits `src` into statements of tokens.
 *
 * Empty statements are dropped. If a string literal is never closed, the
 * statement that contains it is the last one returned (it ends with an
 * `unterminated` token), since nothing after it can be lexed.
 */
Statement[] splitStatements(string src) @safe
{
    import std.array : appender;
    import std.ascii : toLower;

    Statement[] result;
    auto cur = appender!(Token[]);

    void endStatement()
    {
        if (cur[].length)
            result ~= cur[].dup;
        cur.clear();
    }

    size_t i = 0;
    immutable n = src.length;
    while (i < n)
    {
        immutable c = src[i];
        if (isSpace(c))
        {
            ++i;
            continue;
        }
        if (c == '-' && i + 1 < n && src[i + 1] == '-')
        {
            i += 2;
            while (i < n && src[i] != '\n')
                ++i;
            continue;
        }
        if (c == ';')
        {
            ++i;
            endStatement();
            continue;
        }
        Token t;
        if (isIdentStart(c))
        {
            immutable start = i;
            while (i < n && (isIdentStart(src[i]) || isDigit(src[i])))
                ++i;
            auto lowered = new char[i - start];
            foreach (k, ch; src[start .. i])
                lowered[k] = toLower(ch);
            t.kind = TokenKind.ident;
            t.text = (() @trusted => cast(string) lowered)();
            t.keyword = keywordOf(t.text);
        }
        else if (isDigit(c))
        {
            long v = 0;
            bool overflow = false;
            while (i < n && isDigit(src[i]))
            {
                immutable d = src[i] - '0';
                if (v > (long.max - d) / 10)
                    overflow = true;
                else
                    v = v * 10 + d;
                ++i;
            }
            t.kind = overflow ? TokenKind.invalid : TokenKind.integer;
            t.value = v;
        }
        else if (c == '\'')
        {
            ++i;
            auto buf = appender!string;
            bool closed = false;
            while (i < n)
            {
                if (src[i] == '\'')
                {
                    if (i + 1 < n && src[i + 1] == '\'')
                    {
                        buf.put('\'');
                        i += 2;
                        continue;
                    }
                    closed = true;
                    ++i;
                    break;
                }
                buf.put(src[i]);
                ++i;
            }
            if (!closed)
            {
                t.kind = TokenKind.unterminated;
                cur.put(t);
                endStatement();
                return result;
            }
            t.kind = TokenKind.string_;
            t.text = buf[];
        }
        else
        {
            ++i;
            immutable next = i < n ? src[i] : '\0';
            switch (c)
            {
            case '+': t.kind = TokenKind.plus; break;
            case '-': t.kind = TokenKind.minus; break;
            case '*': t.kind = TokenKind.star; break;
            case '/': t.kind = TokenKind.slash; break;
            case '%': t.kind = TokenKind.percent; break;
            case '(': t.kind = TokenKind.lparen; break;
            case ')': t.kind = TokenKind.rparen; break;
            case ',': t.kind = TokenKind.comma; break;
            case '.': t.kind = TokenKind.dot; break;
            case '=':
                t.kind = TokenKind.eq;
                if (next == '=')
                    ++i;
                break;
            case '!':
                if (next == '=')
                {
                    t.kind = TokenKind.ne;
                    ++i;
                }
                else
                    t.kind = TokenKind.invalid;
                break;
            case '<':
                if (next == '=')
                {
                    t.kind = TokenKind.le;
                    ++i;
                }
                else if (next == '>')
                {
                    t.kind = TokenKind.ne;
                    ++i;
                }
                else
                    t.kind = TokenKind.lt;
                break;
            case '>':
                if (next == '=')
                {
                    t.kind = TokenKind.ge;
                    ++i;
                }
                else
                    t.kind = TokenKind.gt;
                break;
            default:
                t.kind = TokenKind.invalid;
                break;
            }
        }
        cur.put(t);
    }
    endStatement();
    return result;
}

@("statements are split on semicolons only")
unittest
{
    auto s = splitStatements("select 1; ;; select ';' -- a ; comment\n, 2;\n-- tail");
    assert(s.length == 2);
    assert(s[0].length == 2);
    assert(s[1].length == 4);
    assert(s[1][1].kind == TokenKind.string_ && s[1][1].text == ";");
}

@("a final statement without semicolon is kept")
unittest
{
    assert(splitStatements("select 1").length == 1);
    assert(splitStatements("  -- nothing\n ;; ").length == 0);
    assert(splitStatements("").length == 0);
}

@("keywords and identifiers are case-insensitive")
unittest
{
    auto s = splitStatements("SeLeCt Foo");
    assert(s[0][0].keyword == Keyword.select);
    assert(s[0][1].keyword == Keyword.none && s[0][1].text == "foo");
    assert(splitStatements("NULL IS")[0][0].keyword == Keyword.null_);
    assert(splitStatements("count")[0][0].keyword == Keyword.none);
}

@("operators use longest match; -- is always a comment")
unittest
{
    auto s = splitStatements("a<=b<>c!=d==e<f=g --5\n");
    TokenKind[] kinds;
    foreach (t; s[0])
        kinds ~= t.kind;
    assert(kinds == [TokenKind.ident, TokenKind.le, TokenKind.ident, TokenKind.ne,
            TokenKind.ident, TokenKind.ne, TokenKind.ident, TokenKind.eq,
            TokenKind.ident, TokenKind.lt, TokenKind.ident, TokenKind.eq, TokenKind.ident]);
}

@("string escapes and unterminated strings")
unittest
{
    auto s = splitStatements("select 'it''s'; select 'oops; select 2;");
    assert(s.length == 2);
    assert(s[0][1].text == "it's");
    assert(s[1][$ - 1].kind == TokenKind.unterminated);
}

@("invalid characters become invalid tokens")
unittest
{
    auto s = splitStatements("select \"x\", 1.5, @, é;");
    bool sawInvalid = false;
    foreach (t; s[0])
        sawInvalid |= t.kind == TokenKind.invalid;
    assert(sawInvalid);
}
