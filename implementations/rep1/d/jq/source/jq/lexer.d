/**
 * Tokeniser for the filter language.
 */
module jq.lexer;

import core.stdc.stdlib : strtod;

import jq.json : encodeUtf8;

/// Thrown for malformed filters.
class FilterException : Exception
{
    /// Byte offset in the filter source.
    size_t offset;
    this(string msg, size_t offset, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(msg, file, line);
        this.offset = offset;
    }
}

/// Token kinds.
enum Tok : ubyte
{
    eof, dot, ident, number, str, variable,
    lparen, rparen, lbrack, rbrack, lbrace, rbrace,
    comma, pipe, colon, semi, question,
    plus, minus, star, slash, percent,
    eq, ne, lt, le, gt, ge,
}

/// A lexical token.
struct Token
{
    Tok kind;
    /// Identifier name, variable name or decoded string contents.
    string text;
    /// Value of a number token.
    double num;
    /// Byte range in the source.
    size_t start, end;
}

private bool isIdentStart(char c) pure nothrow @safe @nogc
{
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_';
}

private bool isDigit(char c) pure nothrow @safe @nogc
{
    return c >= '0' && c <= '9';
}

/// Split a filter into tokens (the last one is `Tok.eof`).
Token[] tokenize(string src)
{
    Token[] toks;
    size_t i = 0;
    const n = src.length;
    while (true)
    {
        while (i < n && (src[i] == ' ' || src[i] == '\t' || src[i] == '\r' || src[i] == '\n'))
            ++i;
        if (i >= n)
        {
            toks ~= Token(Tok.eof, "", 0, n, n);
            return toks;
        }
        const start = i;
        const c = src[i];
        if (isIdentStart(c))
        {
            while (i < n && (isIdentStart(src[i]) || isDigit(src[i])))
                ++i;
            toks ~= Token(Tok.ident, src[start .. i], 0, start, i);
        }
        else if (isDigit(c))
        {
            while (i < n && isDigit(src[i]))
                ++i;
            if (i + 1 < n && src[i] == '.' && isDigit(src[i + 1]))
            {
                ++i;
                while (i < n && isDigit(src[i]))
                    ++i;
            }
            auto z = src[start .. i].idup ~ '\0';
            toks ~= Token(Tok.number, src[start .. i], strtod(z.ptr, null), start, i);
        }
        else if (c == '"')
        {
            toks ~= lexString(src, i);
            i = toks[$ - 1].end;
        }
        else if (c == '$')
        {
            ++i;
            const ns = i;
            while (i < n && (isIdentStart(src[i]) || isDigit(src[i])))
                ++i;
            if (ns == i)
                throw new FilterException("expected variable name", start);
            toks ~= Token(Tok.variable, src[ns .. i], 0, start, i);
        }
        else
        {
            Tok k;
            size_t len = 1;
            const d = i + 1 < n ? src[i + 1] : '\0';
            switch (c)
            {
            case '.': k = Tok.dot; break;
            case '(': k = Tok.lparen; break;
            case ')': k = Tok.rparen; break;
            case '[': k = Tok.lbrack; break;
            case ']': k = Tok.rbrack; break;
            case '{': k = Tok.lbrace; break;
            case '}': k = Tok.rbrace; break;
            case ',': k = Tok.comma; break;
            case '|': k = Tok.pipe; break;
            case ':': k = Tok.colon; break;
            case ';': k = Tok.semi; break;
            case '?': k = Tok.question; break;
            case '+': k = Tok.plus; break;
            case '-': k = Tok.minus; break;
            case '*': k = Tok.star; break;
            case '/': k = Tok.slash; break;
            case '%': k = Tok.percent; break;
            case '=':
                if (d != '=')
                    throw new FilterException("unexpected '='", i);
                k = Tok.eq;
                len = 2;
                break;
            case '!':
                if (d != '=')
                    throw new FilterException("unexpected '!'", i);
                k = Tok.ne;
                len = 2;
                break;
            case '<':
                if (d == '=') { k = Tok.le; len = 2; }
                else k = Tok.lt;
                break;
            case '>':
                if (d == '=') { k = Tok.ge; len = 2; }
                else k = Tok.gt;
                break;
            default:
                throw new FilterException("unexpected character", i);
            }
            i += len;
            toks ~= Token(k, src[start .. i], 0, start, i);
        }
    }
}

private uint hex4(string s, ref size_t i)
{
    uint v = 0;
    foreach (_; 0 .. 4)
    {
        if (i >= s.length)
            throw new FilterException("bad \\u escape", i);
        const c = s[i++];
        uint d;
        if (c >= '0' && c <= '9') d = c - '0';
        else if (c >= 'a' && c <= 'f') d = c - 'a' + 10;
        else if (c >= 'A' && c <= 'F') d = c - 'A' + 10;
        else throw new FilterException("bad \\u escape", i);
        v = v * 16 + d;
    }
    return v;
}

private Token lexString(string src, size_t start)
{
    size_t i = start + 1;
    char[] buf;
    while (true)
    {
        if (i >= src.length)
            throw new FilterException("unterminated string", start);
        const c = src[i++];
        if (c == '"')
            break;
        if (c != '\\')
        {
            buf ~= c;
            continue;
        }
        if (i >= src.length)
            throw new FilterException("unterminated string", start);
        const e = src[i++];
        switch (e)
        {
        case '"': buf ~= '"'; break;
        case '\\': buf ~= '\\'; break;
        case '/': buf ~= '/'; break;
        case 'b': buf ~= '\b'; break;
        case 'f': buf ~= '\f'; break;
        case 'n': buf ~= '\n'; break;
        case 'r': buf ~= '\r'; break;
        case 't': buf ~= '\t'; break;
        case 'u':
            {
                uint cp = hex4(src, i);
                if (cp >= 0xD800 && cp < 0xDC00 && i + 1 < src.length && src[i] == '\\' && src[i + 1] == 'u')
                {
                    size_t j = i + 2;
                    const lo = hex4(src, j);
                    if (lo >= 0xDC00 && lo < 0xE000)
                    {
                        cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                        i = j;
                    }
                }
                encodeUtf8(buf, cp);
                break;
            }
        default:
            throw new FilterException("invalid escape in string", i);
        }
    }
    return Token(Tok.str, cast(string) buf, 0, start, i);
}
