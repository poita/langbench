/// Tokeniser for Datalog source text.
module datalog.lexer;

import datalog.errors;

/// Kinds of token.
enum TokenKind : ubyte
{
    identifier, /// `[a-z][a-z0-9_]*` other than `not`
    variable, /// `[A-Z][A-Za-z0-9_]*`
    anonymous, /// `_`
    integer, /// `-?[0-9]+`
    not, /// the keyword `not`
    lparen, /// `(`
    rparen, /// `)`
    comma, /// `,`
    dot, /// `.`
    implies, /// `:-`
    queryMark, /// `?-`
    lt, /// `<`
    le, /// `<=`
    gt, /// `>`
    ge, /// `>=`
    eq, /// `=`
    ne, /// `!=`
    eof, /// end of input
}

/// A token with its text, numeric value (for integers) and line number.
struct Token
{
    TokenKind kind;
    string text;
    long value;
    size_t line;
}

private bool isLower(char c) @safe pure nothrow @nogc { return c >= 'a' && c <= 'z'; }
private bool isUpper(char c) @safe pure nothrow @nogc { return c >= 'A' && c <= 'Z'; }
private bool isDigit(char c) @safe pure nothrow @nogc { return c >= '0' && c <= '9'; }
private bool isWordChar(char c) @safe pure nothrow @nogc
{
    return isLower(c) || isUpper(c) || isDigit(c) || c == '_';
}

/// Splits `source` into tokens, ending with an `eof` token. `%` comments and
/// whitespace are skipped. Throws `ParseException` on an illegal character.
Token[] tokenize(string source) @safe pure
{
    Token[] tokens;
    tokens.reserve(source.length / 3 + 1);
    size_t i = 0;
    size_t line = 1;
    immutable n = source.length;

    void add(TokenKind k, size_t from, size_t to, long v = 0)
    {
        tokens ~= Token(k, source[from .. to], v, line);
    }

    while (i < n)
    {
        immutable c = source[i];
        if (c == '\n')
        {
            ++line;
            ++i;
        }
        else if (c == ' ' || c == '\t' || c == '\r')
            ++i;
        else if (c == '%')
        {
            while (i < n && source[i] != '\n')
                ++i;
        }
        else if (isLower(c))
        {
            immutable start = i;
            while (i < n && isWordChar(source[i]))
                ++i;
            add(source[start .. i] == "not" ? TokenKind.not : TokenKind.identifier, start, i);
        }
        else if (isUpper(c) || c == '_')
        {
            immutable start = i;
            while (i < n && isWordChar(source[i]))
                ++i;
            add(i - start == 1 && c == '_' ? TokenKind.anonymous : TokenKind.variable, start, i);
        }
        else if (isDigit(c) || (c == '-' && i + 1 < n && isDigit(source[i + 1])))
        {
            immutable start = i;
            immutable negative = c == '-';
            if (negative)
                ++i;
            long v = 0;
            while (i < n && isDigit(source[i]))
            {
                v = v * 10 + (source[i] - '0');
                if (v > 4_000_000_000_000_000_000L)
                    throw new ParseException("integer too large", line);
                ++i;
            }
            add(TokenKind.integer, start, i, negative ? -v : v);
        }
        else
        {
            immutable next = i + 1 < n ? source[i + 1] : '\0';
            switch (c)
            {
            case '(': add(TokenKind.lparen, i, i + 1); ++i; break;
            case ')': add(TokenKind.rparen, i, i + 1); ++i; break;
            case ',': add(TokenKind.comma, i, i + 1); ++i; break;
            case '.': add(TokenKind.dot, i, i + 1); ++i; break;
            case '=': add(TokenKind.eq, i, i + 1); ++i; break;
            case ':':
                if (next != '-')
                    throw new ParseException("expected '-' after ':'", line);
                add(TokenKind.implies, i, i + 2);
                i += 2;
                break;
            case '?':
                if (next != '-')
                    throw new ParseException("expected '-' after '?'", line);
                add(TokenKind.queryMark, i, i + 2);
                i += 2;
                break;
            case '<':
                if (next == '=') { add(TokenKind.le, i, i + 2); i += 2; }
                else { add(TokenKind.lt, i, i + 1); ++i; }
                break;
            case '>':
                if (next == '=') { add(TokenKind.ge, i, i + 2); i += 2; }
                else { add(TokenKind.gt, i, i + 1); ++i; }
                break;
            case '!':
                if (next != '=')
                    throw new ParseException("expected '=' after '!'", line);
                add(TokenKind.ne, i, i + 2);
                i += 2;
                break;
            default:
                throw new ParseException("unexpected character", line);
            }
        }
    }
    tokens ~= Token(TokenKind.eof, "", 0, line);
    return tokens;
}

@safe pure unittest
{
    import std.algorithm : map;
    import std.array : array;

    auto kinds(string s) { return tokenize(s).map!(t => t.kind).array; }

    with (TokenKind)
    {
        assert(kinds("") == [eof]);
        assert(kinds("% only a comment\n  ") == [eof]);
        assert(kinds("p(X, _, a1, -5).") == [identifier, lparen, variable, comma, anonymous,
                comma, identifier, comma, integer, rparen, dot, eof]);
        assert(kinds("a :- not b.") == [identifier, implies, not, identifier, dot, eof]);
        assert(kinds("?- q(1).") == [queryMark, identifier, lparen, integer, rparen, dot, eof]);
        assert(kinds("X<=1 X>=2 X<3 X>4 X=5 X!=6") == [variable, le, integer, variable, ge,
                integer, variable, lt, integer, variable, gt, integer, variable, eq, integer,
                variable, ne, integer, eof]);
    }
}

@safe pure unittest
{
    // Longest match: `X<-1` is X, <, -1.
    auto t = tokenize("X<-1");
    assert(t[1].kind == TokenKind.lt);
    assert(t[2].kind == TokenKind.integer && t[2].value == -1);
    // `not` is a keyword, `nothing` and `not_x` are identifiers.
    assert(tokenize("not")[0].kind == TokenKind.not);
    assert(tokenize("nothing")[0].kind == TokenKind.identifier);
    assert(tokenize("not_x")[0].kind == TokenKind.identifier);
    // Line numbers are tracked.
    assert(tokenize("a\n\nb")[1].line == 3);
}

@safe pure unittest
{
    import std.exception : assertThrown;

    assertThrown!ParseException(tokenize("p(a) # x"));
    assertThrown!ParseException(tokenize("p(a) : q"));
}
