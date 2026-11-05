/**
 * Tokeniser for Datalog source text.
 *
 * The lexer walks the input once, producing one token per call to `next`.
 * Tokenisation is longest-match; `%` starts a comment running to end of line.
 */
module datalog.lexer;

import std.exception : basicExceptionCtors;

/// Thrown for malformed input (the language leaves its behaviour unspecified).
class ParseException : Exception
{
    /// 1-based line on which the problem was detected.
    uint line;

    this(string msg, uint line, string file = __FILE__, size_t ln = __LINE__) @safe pure
    {
        import std.conv : to;
        super("line " ~ line.to!string ~ ": " ~ msg, file, ln);
        this.line = line;
    }
}

/// Token kinds.
enum TokenKind : ubyte
{
    eof,
    identifier, /// `[a-z][a-z0-9_]*` other than `not`
    variable,   /// `[A-Z][A-Za-z0-9_]*`
    anonymous,  /// `_`
    integer,    /// `-?[0-9]+`
    kwNot,      /// `not`
    lparen, rparen, comma, dot,
    ruleArrow,  /// `:-`
    queryArrow, /// `?-`
    lt, le, gt, ge, eq, ne,
}

/// A token; `text` slices the source.
struct Token
{
    TokenKind kind;
    string text;
    long value; /// for integers
    uint line;
}

/// Streaming tokeniser.
struct Lexer
{
    private string src;
    private size_t pos;
    private uint line = 1;

    this(string source) @safe pure nothrow @nogc
    {
        src = source;
    }

    /// Returns the next token (`TokenKind.eof` at the end, repeatedly).
    Token next() @safe pure
    {
        skipTrivia();
        if (pos >= src.length)
            return Token(TokenKind.eof, "", 0, line);
        const start = pos;
        const c = src[pos];
        Token tok(TokenKind k) { return Token(k, src[start .. pos], 0, line); }

        if (c >= 'a' && c <= 'z')
        {
            scanWord();
            auto t = tok(TokenKind.identifier);
            if (t.text == "not") t.kind = TokenKind.kwNot;
            return t;
        }
        if (c >= 'A' && c <= 'Z')
        {
            scanWord();
            return tok(TokenKind.variable);
        }
        if (c == '_')
        {
            scanWord();
            if (pos - start != 1)
                throw new ParseException("unexpected token starting with '_'", line);
            return tok(TokenKind.anonymous);
        }
        if (isDigit(c) || (c == '-' && pos + 1 < src.length && isDigit(src[pos + 1])))
            return scanInteger();
        pos++;
        switch (c)
        {
        case '(': return tok(TokenKind.lparen);
        case ')': return tok(TokenKind.rparen);
        case ',': return tok(TokenKind.comma);
        case '.': return tok(TokenKind.dot);
        case '=': return tok(TokenKind.eq);
        case ':':
            if (peekIs('-')) { pos++; return tok(TokenKind.ruleArrow); }
            break;
        case '?':
            if (peekIs('-')) { pos++; return tok(TokenKind.queryArrow); }
            break;
        case '<':
            if (peekIs('=')) { pos++; return tok(TokenKind.le); }
            return tok(TokenKind.lt);
        case '>':
            if (peekIs('=')) { pos++; return tok(TokenKind.ge); }
            return tok(TokenKind.gt);
        case '!':
            if (peekIs('=')) { pos++; return tok(TokenKind.ne); }
            break;
        default:
            break;
        }
        throw new ParseException("unexpected character '" ~ c ~ "'", line);
    }

private:
    static bool isDigit(char c) @safe pure nothrow @nogc { return c >= '0' && c <= '9'; }

    bool peekIs(char c) const @safe pure nothrow @nogc
    {
        return pos < src.length && src[pos] == c;
    }

    void scanWord() @safe pure nothrow @nogc
    {
        pos++;
        while (pos < src.length)
        {
            const c = src[pos];
            if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || isDigit(c) || c == '_')
                pos++;
            else
                break;
        }
    }

    Token scanInteger() @safe pure
    {
        const start = pos;
        bool neg = false;
        if (src[pos] == '-') { neg = true; pos++; }
        long v = 0;
        while (pos < src.length && isDigit(src[pos]))
        {
            v = v * 10 + (src[pos] - '0');
            if (v > 4_000_000_000_000L)
                throw new ParseException("integer too large", line);
            pos++;
        }
        return Token(TokenKind.integer, src[start .. pos], neg ? -v : v, line);
    }

    void skipTrivia() @safe pure nothrow @nogc
    {
        while (pos < src.length)
        {
            const c = src[pos];
            if (c == '\n') { line++; pos++; }
            else if (c == ' ' || c == '\t' || c == '\r') pos++;
            else if (c == '%')
            {
                while (pos < src.length && src[pos] != '\n') pos++;
            }
            else break;
        }
    }
}
