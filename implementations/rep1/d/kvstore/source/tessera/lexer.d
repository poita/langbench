/// Tokeniser for the command language.
module tessera.lexer;

import tessera.errors;

/// Lexical class of a token.
enum TokenKind : ubyte
{
    word,
    integer,
    string_,
    punct,
    op,
}

/// Comparison operators.
enum CmpOp : ubyte
{
    eq,
    ne,
    lt,
    le,
    gt,
    ge,
}

/// One token. Values of integer and string tokens are decoded during lexing,
/// but problems with the *value* (range, surrogates) are only recorded here;
/// the parser reports them when it consumes the token.
struct Token
{
    TokenKind kind;
    /// Spelling of a word, punctuation or operator token.
    string text;
    /// Value of an integer token (valid when `!intOverflow`).
    long intValue;
    /// The integer does not fit in a signed 64-bit integer.
    bool intOverflow;
    /// Decoded value of a string token (UTF-8).
    string strValue;
    /// The string holds an unpaired surrogate escape.
    bool badUtf8;
    /// The operator of an `op` token.
    CmpOp op;

    /// True for the punctuation token `c`.
    bool isPunct(char c) const pure nothrow @nogc @safe
    {
        return kind == TokenKind.punct && text[0] == c;
    }

    /// True for the word token spelled `w`.
    bool isWord(string w) const pure nothrow @nogc @safe
    {
        return kind == TokenKind.word && text == w;
    }
}

private bool isWordStart(char c) pure nothrow @nogc @safe
{
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_';
}

private bool isDigit(char c) pure nothrow @nogc @safe
{
    return c >= '0' && c <= '9';
}

private int hexValue(char c) pure nothrow @nogc @safe
{
    if (c >= '0' && c <= '9')
        return c - '0';
    if (c >= 'a' && c <= 'f')
        return c - 'a' + 10;
    if (c >= 'A' && c <= 'F')
        return c - 'A' + 10;
    return -1;
}

/// Read four hex digits at `s[i .. i+4]`; -1 when they are not all hex digits.
private int hex4(const(char)[] s, size_t i) pure nothrow @nogc @safe
{
    if (i + 4 > s.length)
        return -1;
    int v = 0;
    foreach (k; 0 .. 4)
    {
        immutable h = hexValue(s[i + k]);
        if (h < 0)
            return -1;
        v = v * 16 + h;
    }
    return v;
}

private void encodeUtf8(ref char[] buf, uint cp) pure nothrow @safe
{
    if (cp < 0x80)
        buf ~= cast(char) cp;
    else if (cp < 0x800)
    {
        buf ~= cast(char)(0xC0 | (cp >> 6));
        buf ~= cast(char)(0x80 | (cp & 0x3F));
    }
    else if (cp < 0x10000)
    {
        buf ~= cast(char)(0xE0 | (cp >> 12));
        buf ~= cast(char)(0x80 | ((cp >> 6) & 0x3F));
        buf ~= cast(char)(0x80 | (cp & 0x3F));
    }
    else
    {
        buf ~= cast(char)(0xF0 | (cp >> 18));
        buf ~= cast(char)(0x80 | ((cp >> 12) & 0x3F));
        buf ~= cast(char)(0x80 | ((cp >> 6) & 0x3F));
        buf ~= cast(char)(0x80 | (cp & 0x3F));
    }
}

/// Lex a string literal starting at the opening quote `line[start]`. Returns
/// the index just past the closing quote. Throws `syntax` on lexical errors.
private size_t lexString(string line, size_t start, ref Token tok) pure @safe
{
    size_t i = start + 1;
    immutable n = line.length;
    // Fast path: no escapes.
    size_t j = i;
    while (j < n && line[j] != '"' && line[j] != '\\' && cast(ubyte) line[j] >= 0x20)
        j++;
    if (j < n && line[j] == '"')
    {
        tok.kind = TokenKind.string_;
        tok.strValue = line[i .. j];
        return j + 1;
    }
    char[] buf = line[i .. j].dup;
    i = j;
    bool bad = false;
    while (true)
    {
        if (i >= n)
            fail(ErrorKind.syntax);
        immutable c = line[i];
        if (c == '"')
        {
            i++;
            break;
        }
        if (cast(ubyte) c < 0x20)
            fail(ErrorKind.syntax);
        if (c != '\\')
        {
            buf ~= c;
            i++;
            continue;
        }
        i++;
        if (i >= n)
            fail(ErrorKind.syntax);
        immutable e = line[i];
        i++;
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
            immutable cp = hex4(line, i);
            if (cp < 0)
                fail(ErrorKind.syntax);
            i += 4;
            if (cp >= 0xD800 && cp <= 0xDBFF)
            {
                // Needs an immediately following \uXXXX low surrogate.
                if (i + 1 < n && line[i] == '\\' && line[i + 1] == 'u')
                {
                    immutable lo = hex4(line, i + 2);
                    if (lo >= 0xDC00 && lo <= 0xDFFF)
                    {
                        i += 6;
                        encodeUtf8(buf, 0x10000 + ((cast(uint) cp - 0xD800) << 10) + (cast(uint) lo - 0xDC00));
                        break;
                    }
                }
                bad = true;
            }
            else if (cp >= 0xDC00 && cp <= 0xDFFF)
                bad = true;
            else
                encodeUtf8(buf, cast(uint) cp);
            break;
        default:
            fail(ErrorKind.syntax);
        }
    }
    tok.kind = TokenKind.string_;
    tok.strValue = (() @trusted => cast(string) buf)();
    tok.badUtf8 = bad;
    return i;
}

/// Split one command line into tokens. Throws `syntax` when any part of the
/// line is not lexically well formed.
Token[] tokenize(string line) pure @safe
{
    Token[] toks;
    size_t i = 0;
    immutable n = line.length;
    while (i < n)
    {
        immutable c = line[i];
        if (c == ' ' || c == '\t')
        {
            i++;
            continue;
        }
        Token t;
        if (isWordStart(c))
        {
            size_t j = i + 1;
            while (j < n && (isWordStart(line[j]) || isDigit(line[j])))
                j++;
            t.kind = TokenKind.word;
            t.text = line[i .. j];
            i = j;
        }
        else if (c == '-' || isDigit(c))
        {
            bool neg = c == '-';
            size_t d0 = neg ? i + 1 : i;
            if (d0 >= n || !isDigit(line[d0]))
                fail(ErrorKind.syntax);
            size_t d1 = d0;
            while (d1 < n && isDigit(line[d1]))
                d1++;
            auto digits = line[d0 .. d1];
            if (digits.length > 1 && digits[0] == '0')
                fail(ErrorKind.syntax);
            if (neg && digits == "0")
                fail(ErrorKind.syntax);
            t.kind = TokenKind.integer;
            t.text = line[i .. d1];
            if (digits.length > 19)
                t.intOverflow = true;
            else
            {
                ulong acc = 0;
                foreach (ch; digits)
                    acc = acc * 10 + (ch - '0');
                if (neg)
                {
                    if (acc > 9_223_372_036_854_775_808UL)
                        t.intOverflow = true;
                    else
                        t.intValue = cast(long)(0UL - acc);
                }
                else
                {
                    if (acc > 9_223_372_036_854_775_807UL)
                        t.intOverflow = true;
                    else
                        t.intValue = cast(long) acc;
                }
            }
            i = d1;
        }
        else if (c == '"')
        {
            i = lexString(line, i, t);
        }
        else if (c == '{' || c == '}' || c == '[' || c == ']' || c == '(' || c == ')'
                || c == ',' || c == ':' || c == '.')
        {
            t.kind = TokenKind.punct;
            t.text = line[i .. i + 1];
            i++;
        }
        else if (c == '<' || c == '>')
        {
            t.kind = TokenKind.op;
            if (i + 1 < n && line[i + 1] == '=')
            {
                t.text = line[i .. i + 2];
                t.op = c == '<' ? CmpOp.le : CmpOp.ge;
                i += 2;
            }
            else
            {
                t.text = line[i .. i + 1];
                t.op = c == '<' ? CmpOp.lt : CmpOp.gt;
                i++;
            }
        }
        else if ((c == '=' || c == '!') && i + 1 < n && line[i + 1] == '=')
        {
            t.kind = TokenKind.op;
            t.text = line[i .. i + 2];
            t.op = c == '=' ? CmpOp.eq : CmpOp.ne;
            i += 2;
        }
        else
            fail(ErrorKind.syntax);
        toks ~= t;
    }
    return toks;
}
