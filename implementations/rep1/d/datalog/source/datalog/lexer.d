/// Tokeniser for Datalog source text.
module datalog.lexer;

import datalog.errors : ParseException;

/// Kinds of token.
enum TokenKind : ubyte
{
    eof,
    identifier, /// `[a-z][a-z0-9_]*` (predicate names and constants)
    variable, /// `[A-Z][A-Za-z0-9_]*`
    anonymous, /// `_`
    integer, /// `-?[0-9]+`
    not, /// the keyword `not`
    lparen, /// `(`
    rparen, /// `)`
    comma, /// `,`
    dot, /// `.`
    neck, /// `:-`
    queryMark, /// `?-`
    lt, /// `<`
    le, /// `<=`
    gt, /// `>`
    ge, /// `>=`
    eq, /// `=`
    ne, /// `!=`
}

/// A token. `text` is a slice of the source; `value` is set for integers.
struct Token
{
    TokenKind kind;
    string text;
    long value;
    size_t line;
}

/// Largest absolute value accepted for an integer constant.
enum long maxIntegerMagnitude = 1_000_000_000;

private bool isLower(char c) pure nothrow @nogc @safe
{
    return c >= 'a' && c <= 'z';
}

private bool isUpper(char c) pure nothrow @nogc @safe
{
    return c >= 'A' && c <= 'Z';
}

private bool isDigit(char c) pure nothrow @nogc @safe
{
    return c >= '0' && c <= '9';
}

private bool isIdentChar(char c) pure nothrow @nogc @safe
{
    return isLower(c) || isUpper(c) || isDigit(c) || c == '_';
}

/// Pull-style lexer: call `next` repeatedly until it returns an `eof` token.
struct Lexer
{
    private string src;
    private size_t pos;
    private size_t line = 1;

    this(string source) pure nothrow @nogc @safe
    {
        src = source;
    }

    /// Return the next token, throwing `ParseException` on an illegal character.
    Token next() @safe
    {
        skipTrivia();
        if (pos >= src.length)
            return Token(TokenKind.eof, "", 0, line);

        immutable start = pos;
        immutable c = src[pos];

        Token simple(TokenKind k, size_t len)
        {
            pos += len;
            return Token(k, src[start .. pos], 0, line);
        }

        if (isLower(c))
        {
            while (pos < src.length && (isLower(src[pos]) || isDigit(src[pos]) || src[pos] == '_'))
                ++pos;
            auto text = src[start .. pos];
            return Token(text == "not" ? TokenKind.not : TokenKind.identifier, text, 0, line);
        }
        if (isUpper(c))
        {
            while (pos < src.length && isIdentChar(src[pos]))
                ++pos;
            return Token(TokenKind.variable, src[start .. pos], 0, line);
        }
        if (c == '_')
        {
            ++pos;
            if (pos < src.length && isIdentChar(src[pos]))
                throw new ParseException("identifiers may not start with '_'", line);
            return Token(TokenKind.anonymous, "_", 0, line);
        }
        if (isDigit(c) || (c == '-' && pos + 1 < src.length && isDigit(src[pos + 1])))
            return lexInteger();

        switch (c)
        {
        case '(':
            return simple(TokenKind.lparen, 1);
        case ')':
            return simple(TokenKind.rparen, 1);
        case ',':
            return simple(TokenKind.comma, 1);
        case '.':
            return simple(TokenKind.dot, 1);
        case ':':
            if (peekChar(1) == '-')
                return simple(TokenKind.neck, 2);
            break;
        case '?':
            if (peekChar(1) == '-')
                return simple(TokenKind.queryMark, 2);
            break;
        case '<':
            return peekChar(1) == '=' ? simple(TokenKind.le, 2) : simple(TokenKind.lt, 1);
        case '>':
            return peekChar(1) == '=' ? simple(TokenKind.ge, 2) : simple(TokenKind.gt, 1);
        case '=':
            return simple(TokenKind.eq, 1);
        case '!':
            if (peekChar(1) == '=')
                return simple(TokenKind.ne, 2);
            break;
        default:
            break;
        }
        throw new ParseException("unexpected character '" ~ c ~ "'", line);
    }

private:
    char peekChar(size_t ahead) const pure nothrow @nogc @safe
    {
        return pos + ahead < src.length ? src[pos + ahead] : '\0';
    }

    void skipTrivia() pure nothrow @nogc @safe
    {
        while (pos < src.length)
        {
            immutable c = src[pos];
            if (c == '\n')
            {
                ++line;
                ++pos;
            }
            else if (c == ' ' || c == '\t' || c == '\r')
                ++pos;
            else if (c == '%')
            {
                while (pos < src.length && src[pos] != '\n')
                    ++pos;
            }
            else
                break;
        }
    }

    Token lexInteger() @safe
    {
        immutable start = pos;
        bool negative = false;
        if (src[pos] == '-')
        {
            negative = true;
            ++pos;
        }
        long v = 0;
        while (pos < src.length && isDigit(src[pos]))
        {
            v = v * 10 + (src[pos] - '0');
            if (v > maxIntegerMagnitude)
                throw new ParseException("integer constant out of range", line);
            ++pos;
        }
        return Token(TokenKind.integer, src[start .. pos], negative ? -v : v, line);
    }
}
