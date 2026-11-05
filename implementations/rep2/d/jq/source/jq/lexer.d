/**
 * Tokeniser for jq filters.
 */
module jq.lexer;

import jq.json : readJsonString, scanNumber, JsonException;

/// Thrown when a filter cannot be parsed.
class ParseException : Exception
{
    ///
    this(string msg, size_t offset = 0, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(msg, file, line);
        this.offset = offset;
    }

    /// Byte offset in the filter text.
    size_t offset;
}

/// Token kinds.
enum Tok : ubyte
{
    eof,
    dot, /// `.` not directly followed by an identifier
    field, /// `.name`
    ident, /// identifiers and keywords
    num,
    str,
    var, /// `$name`
    lparen,
    rparen,
    lbracket,
    rbracket,
    lbrace,
    rbrace,
    comma,
    pipe,
    colon,
    semi,
    question,
    plus,
    minus,
    star,
    slash,
    percent,
    eq,
    ne,
    lt,
    le,
    gt,
    ge,
}

/// A lexical token.
struct Token
{
    Tok kind;
    /// Identifier, field or variable name, or the decoded string literal.
    string text;
    double num;
    size_t pos;
}

private bool isIdentStart(char c) pure nothrow @nogc @safe
{
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_';
}

private bool isDigit(char c) pure nothrow @nogc @safe
{
    return c >= '0' && c <= '9';
}

/// Split `src` into tokens (the last one is always `Tok.eof`).
Token[] tokenize(string src) @trusted
{
    Token[] toks;
    size_t i = 0;
    immutable n = src.length;

    string readIdent()
    {
        immutable st = i;
        while (i < n && (isIdentStart(src[i]) || isDigit(src[i])))
            ++i;
        return src[st .. i];
    }

    while (true)
    {
        while (i < n && (src[i] == ' ' || src[i] == '\t' || src[i] == '\r' || src[i] == '\n'))
            ++i;
        if (i >= n)
            break;
        immutable c = src[i];
        immutable start = i;
        void simple(Tok k, size_t len = 1)
        {
            toks ~= Token(k, null, 0, start);
            i += len;
        }

        immutable c2 = i + 1 < n ? src[i + 1] : '\0';
        if (c == '.')
        {
            if (isIdentStart(c2))
            {
                ++i;
                toks ~= Token(Tok.field, readIdent(), 0, start);
            }
            else
                simple(Tok.dot);
        }
        else if (isIdentStart(c))
            toks ~= Token(Tok.ident, readIdent(), 0, start);
        else if (isDigit(c))
        {
            double d;
            if (!scanNumber(src, i, d))
                throw new ParseException("bad number", start);
            toks ~= Token(Tok.num, null, d, start);
        }
        else if (c == '"')
        {
            try
                toks ~= Token(Tok.str, readJsonString(src, i), 0, start);
            catch (JsonException e)
                throw new ParseException(e.msg, start);
        }
        else if (c == '$')
        {
            ++i;
            if (i >= n || !isIdentStart(src[i]))
                throw new ParseException("bad variable name", start);
            toks ~= Token(Tok.var, readIdent(), 0, start);
        }
        else
            switch (c)
            {
            case '(':
                simple(Tok.lparen);
                break;
            case ')':
                simple(Tok.rparen);
                break;
            case '[':
                simple(Tok.lbracket);
                break;
            case ']':
                simple(Tok.rbracket);
                break;
            case '{':
                simple(Tok.lbrace);
                break;
            case '}':
                simple(Tok.rbrace);
                break;
            case ',':
                simple(Tok.comma);
                break;
            case '|':
                simple(Tok.pipe);
                break;
            case ':':
                simple(Tok.colon);
                break;
            case ';':
                simple(Tok.semi);
                break;
            case '?':
                simple(Tok.question);
                break;
            case '+':
                simple(Tok.plus);
                break;
            case '-':
                simple(Tok.minus);
                break;
            case '*':
                simple(Tok.star);
                break;
            case '/':
                simple(Tok.slash);
                break;
            case '%':
                simple(Tok.percent);
                break;
            case '=':
                if (c2 != '=')
                    throw new ParseException("unexpected '='", start);
                simple(Tok.eq, 2);
                break;
            case '!':
                if (c2 != '=')
                    throw new ParseException("unexpected '!'", start);
                simple(Tok.ne, 2);
                break;
            case '<':
                if (c2 == '=')
                    simple(Tok.le, 2);
                else
                    simple(Tok.lt);
                break;
            case '>':
                if (c2 == '=')
                    simple(Tok.ge, 2);
                else
                    simple(Tok.gt);
                break;
            default:
                throw new ParseException("unexpected character", start);
            }
    }
    toks ~= Token(Tok.eof, null, 0, n);
    return toks;
}
