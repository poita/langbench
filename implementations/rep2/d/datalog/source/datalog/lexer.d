/// Tokeniser for Datalog source text.
module datalog.lexer;

import datalog.errors : ParseException;

/// Kinds of token.
enum TokenKind : ubyte
{
    eof,
    identifier, /// `[a-z][a-z0-9_]*` (predicate names and constants)
    variable,   /// `[A-Z][A-Za-z0-9_]*`
    anonymous,  /// `_`
    integer,    /// `-?[0-9]+`
    kwNot,      /// the reserved word `not`
    lparen, rparen, comma, dot,
    implies,    /// `:-`
    queryMark,  /// `?-`
    lt, le, gt, ge, eq, ne
}

/// A token: kind plus the slice of source text it covers.
struct Token
{
    TokenKind kind;
    string text;
    size_t offset;
}

/// Pulls tokens one at a time from a source string. Whitespace and `%` comments
/// are skipped. Matching is longest-match (`<=` is one token).
struct Lexer
{
    private string src;
    private size_t pos;

    ///
    this(string source) @safe pure nothrow @nogc { src = source; }

    /// Return the next token; `TokenKind.eof` at the end of input.
    Token next() @safe pure
    {
        skipTrivia();
        if (pos >= src.length)
            return Token(TokenKind.eof, "", pos);
        immutable start = pos;
        immutable c = src[pos];

        Token make(TokenKind k, size_t len)
        {
            pos = start + len;
            return Token(k, src[start .. pos], start);
        }

        if (c >= 'a' && c <= 'z')
        {
            size_t e = pos + 1;
            while (e < src.length && isLowerIdChar(src[e])) ++e;
            pos = e;
            auto text = src[start .. e];
            return Token(text == "not" ? TokenKind.kwNot : TokenKind.identifier, text, start);
        }
        if (c >= 'A' && c <= 'Z')
        {
            size_t e = pos + 1;
            while (e < src.length && (isLowerIdChar(src[e]) || (src[e] >= 'A' && src[e] <= 'Z'))) ++e;
            return make(TokenKind.variable, e - start);
        }
        if (isDigit(c) || (c == '-' && pos + 1 < src.length && isDigit(src[pos + 1])))
        {
            size_t e = pos + 1;
            while (e < src.length && isDigit(src[e])) ++e;
            return make(TokenKind.integer, e - start);
        }
        immutable n = pos + 1 < src.length ? src[pos + 1] : '\0';
        switch (c)
        {
        case '_': return make(TokenKind.anonymous, 1);
        case '(': return make(TokenKind.lparen, 1);
        case ')': return make(TokenKind.rparen, 1);
        case ',': return make(TokenKind.comma, 1);
        case '.': return make(TokenKind.dot, 1);
        case ':':
            if (n == '-') return make(TokenKind.implies, 2);
            break;
        case '?':
            if (n == '-') return make(TokenKind.queryMark, 2);
            break;
        case '<': return n == '=' ? make(TokenKind.le, 2) : make(TokenKind.lt, 1);
        case '>': return n == '=' ? make(TokenKind.ge, 2) : make(TokenKind.gt, 1);
        case '=': return make(TokenKind.eq, 1);
        case '!':
            if (n == '=') return make(TokenKind.ne, 2);
            break;
        default:
            break;
        }
        throw new ParseException("unexpected character", start);
    }

    private void skipTrivia() @safe pure nothrow @nogc
    {
        while (pos < src.length)
        {
            immutable c = src[pos];
            if (c == ' ' || c == '\t' || c == '\r' || c == '\n')
                ++pos;
            else if (c == '%')
            {
                while (pos < src.length && src[pos] != '\n') ++pos;
            }
            else
                break;
        }
    }
}

private bool isDigit(char c) @safe pure nothrow @nogc { return c >= '0' && c <= '9'; }

private bool isLowerIdChar(char c) @safe pure nothrow @nogc
{
    return (c >= 'a' && c <= 'z') || isDigit(c) || c == '_';
}
