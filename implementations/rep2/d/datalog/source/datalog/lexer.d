/// Tokeniser for Datalog source text.
module datalog.lexer;

import datalog.errors : SyntaxException;
import std.conv : to;

/// Kinds of token.
enum TokenKind : ubyte
{
    identifier, variable, anonymous, integer, kwNot,
    lparen, rparen, comma, dot, neck, queryMark,
    lt, le, gt, ge, eq, ne, eof
}

/// A token with its source text, numeric value (integers) and line number.
struct Token
{
    TokenKind kind;
    string text;
    long value;
    uint line;
}

private bool isLower(char c) @safe pure nothrow @nogc { return c >= 'a' && c <= 'z'; }
private bool isUpper(char c) @safe pure nothrow @nogc { return c >= 'A' && c <= 'Z'; }
private bool isDigit(char c) @safe pure nothrow @nogc { return c >= '0' && c <= '9'; }
private bool isWordChar(char c) @safe pure nothrow @nogc
{
    return isLower(c) || isUpper(c) || isDigit(c) || c == '_';
}

/// Splits `src` into tokens (the last one is always `TokenKind.eof`).
///
/// Throws: `SyntaxException` on a character that starts no token.
Token[] tokenize(string src) @safe pure
{
    Token[] toks;
    toks.reserve(src.length / 3 + 1);
    size_t i = 0;
    uint line = 1;
    immutable n = src.length;

    void emit(TokenKind k, size_t from, size_t to_)
    {
        toks ~= Token(k, src[from .. to_], 0, line);
    }

    while (i < n)
    {
        immutable c = src[i];
        if (c == '\n')
        {
            ++line;
            ++i;
        }
        else if (c == ' ' || c == '\t' || c == '\r')
            ++i;
        else if (c == '%')
        {
            while (i < n && src[i] != '\n')
                ++i;
        }
        else if (isLower(c))
        {
            auto s = i;
            while (i < n && isWordChar(src[i]))
                ++i;
            emit(src[s .. i] == "not" ? TokenKind.kwNot : TokenKind.identifier, s, i);
        }
        else if (isUpper(c) || c == '_')
        {
            auto s = i;
            while (i < n && isWordChar(src[i]))
                ++i;
            emit(src[s .. i] == "_" ? TokenKind.anonymous : TokenKind.variable, s, i);
        }
        else if (isDigit(c) || (c == '-' && i + 1 < n && isDigit(src[i + 1])))
        {
            auto s = i;
            ++i;
            while (i < n && isDigit(src[i]))
                ++i;
            toks ~= Token(TokenKind.integer, src[s .. i], src[s .. i].to!long, line);
        }
        else
        {
            auto s = i;
            auto next = i + 1 < n ? src[i + 1] : '\0';
            TokenKind k;
            size_t len = 1;
            switch (c)
            {
            case '(': k = TokenKind.lparen; break;
            case ')': k = TokenKind.rparen; break;
            case ',': k = TokenKind.comma; break;
            case '.': k = TokenKind.dot; break;
            case '=': k = TokenKind.eq; break;
            case ':':
                if (next != '-') goto default;
                k = TokenKind.neck; len = 2; break;
            case '?':
                if (next != '-') goto default;
                k = TokenKind.queryMark; len = 2; break;
            case '<':
                if (next == '=') { k = TokenKind.le; len = 2; }
                else k = TokenKind.lt;
                break;
            case '>':
                if (next == '=') { k = TokenKind.ge; len = 2; }
                else k = TokenKind.gt;
                break;
            case '!':
                if (next != '=') goto default;
                k = TokenKind.ne; len = 2; break;
            default:
                throw new SyntaxException("line " ~ line.to!string ~ ": unexpected character '"
                        ~ c.to!string ~ "'");
            }
            i += len;
            emit(k, s, i);
        }
    }
    toks ~= Token(TokenKind.eof, "", 0, line);
    return toks;
}

@("lexer: token kinds and longest match")
@safe pure unittest
{
    auto t = tokenize("p(X, _, -3) :- X<=a, not q(b), X<-1. ?- p(1). % c\n x != y >= <");
    TokenKind[] kinds;
    foreach (tok; t)
        kinds ~= tok.kind;
    with (TokenKind)
        assert(kinds == [identifier, lparen, variable, comma, anonymous, comma, integer, rparen,
            neck, variable, le, identifier, comma, kwNot, identifier, lparen, identifier, rparen,
            comma, variable, lt, integer, dot, queryMark, identifier, lparen, integer, rparen, dot,
            identifier, ne, identifier, ge, lt, eof]);
    assert(t[6].value == -3);
}

@("lexer: not is only a keyword on its own")
@safe pure unittest
{
    auto t = tokenize("not nothing not_x");
    assert(t[0].kind == TokenKind.kwNot);
    assert(t[1].kind == TokenKind.identifier);
    assert(t[2].kind == TokenKind.identifier);
}

@("lexer: comments and line numbers")
@safe pure unittest
{
    auto t = tokenize("% only\n\n a. % x");
    assert(t[0].line == 3);
    assert(t.length == 3);
}

@("lexer: unknown character is a syntax error")
@safe pure unittest
{
    import std.exception : assertThrown;

    assertThrown!SyntaxException(tokenize("p(a) @"));
}
