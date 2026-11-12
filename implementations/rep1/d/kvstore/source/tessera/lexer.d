/// The token stream of the command language (SPEC §6.1).
module tessera.lexer;

import std.array : Appender;

import tessera.errors;

/// Token classes.
enum Tok : ubyte
{
    word,
    int_,
    str,
    punct,
    op,
}

/// A token: its class and the source text it covers. For a `str` token the
/// text is what lies between the quotes, escapes still unresolved.
struct Token
{
    Tok kind;
    string text;

    /// Whether this is the punctuation or operator `s`.
    bool isSym(string s) const @safe pure nothrow @nogc
    {
        return (kind == Tok.punct || kind == Tok.op) && text == s;
    }

    /// Whether this is the word `s`.
    bool isWord(string s) const @safe pure nothrow @nogc
    {
        return kind == Tok.word && text == s;
    }
}

private bool isDigit(char c) @safe pure nothrow @nogc
{
    return c >= '0' && c <= '9';
}

private bool isHex(char c) @safe pure nothrow @nogc
{
    return isDigit(c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
}

private bool isWordStart(char c) @safe pure nothrow @nogc
{
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_';
}

/// Tokenise a whole line. Throws `syntax` for anything that is not a token.
Token[] lex(string line) @safe pure
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
        immutable start = i;
        if (isWordStart(c))
        {
            while (i < n && (isWordStart(line[i]) || isDigit(line[i])))
                i++;
            toks ~= Token(Tok.word, line[start .. i]);
        }
        else if (isDigit(c) || c == '-')
        {
            if (c == '-')
            {
                i++;
                if (i >= n || !isDigit(line[i]))
                    fail(ErrorKind.syntax);
            }
            immutable digits = i;
            while (i < n && isDigit(line[i]))
                i++;
            if (i - digits > 1 && line[digits] == '0')
                fail(ErrorKind.syntax);
            if (c == '-' && line[digits] == '0')
                fail(ErrorKind.syntax);
            toks ~= Token(Tok.int_, line[start .. i]);
        }
        else if (c == '"')
        {
            i++;
            while (true)
            {
                if (i >= n)
                    fail(ErrorKind.syntax);
                immutable d = line[i];
                if (d == '"')
                    break;
                if (d < 0x20)
                    fail(ErrorKind.syntax);
                if (d == '\\')
                {
                    i++;
                    if (i >= n)
                        fail(ErrorKind.syntax);
                    switch (line[i])
                    {
                    case '"', '\\', '/', 'b', 'f', 'n', 'r', 't':
                        break;
                    case 'u':
                        foreach (k; 1 .. 5)
                            if (i + k >= n || !isHex(line[i + k]))
                                fail(ErrorKind.syntax);
                        i += 4;
                        break;
                    default:
                        fail(ErrorKind.syntax);
                    }
                }
                i++;
            }
            toks ~= Token(Tok.str, line[start + 1 .. i]);
            i++;
        }
        else
        {
            switch (c)
            {
            case '{', '}', '[', ']', '(', ')', ',', ':', '.':
                i++;
                toks ~= Token(Tok.punct, line[start .. i]);
                break;
            case '=', '!':
                if (i + 1 >= n || line[i + 1] != '=')
                    fail(ErrorKind.syntax);
                i += 2;
                toks ~= Token(Tok.op, line[start .. i]);
                break;
            case '<', '>':
                i++;
                if (i < n && line[i] == '=')
                    i++;
                toks ~= Token(Tok.op, line[start .. i]);
                break;
            default:
                fail(ErrorKind.syntax);
            }
        }
    }
    return toks;
}

/// Resolve the escapes of a `str` token into UTF-8 text (SPEC §6.1).
/// Throws `badUtf8` for an unpaired surrogate.
string unescape(string raw) @safe pure
{
    // fast path: nothing to resolve
    bool plain = true;
    foreach (char c; raw)
        if (c == '\\')
        {
            plain = false;
            break;
        }
    if (plain)
        return raw;

    Appender!string o;
    size_t i = 0;
    uint hex4(size_t at)
    {
        uint v = 0;
        foreach (k; 0 .. 4)
        {
            immutable c = raw[at + k];
            v = v * 16 + (isDigit(c) ? c - '0' : (c | 0x20) - 'a' + 10);
        }
        return v;
    }

    while (i < raw.length)
    {
        immutable c = raw[i];
        if (c != '\\')
        {
            o.put(c);
            i++;
            continue;
        }
        immutable e = raw[i + 1];
        i += 2;
        switch (e)
        {
        case '"':
            o.put('"');
            break;
        case '\\':
            o.put('\\');
            break;
        case '/':
            o.put('/');
            break;
        case 'b':
            o.put('\b');
            break;
        case 'f':
            o.put('\f');
            break;
        case 'n':
            o.put('\n');
            break;
        case 'r':
            o.put('\r');
            break;
        case 't':
            o.put('\t');
            break;
        default: // 'u'
            uint cp = hex4(i);
            i += 4;
            if (cp >= 0xD800 && cp <= 0xDBFF)
            {
                if (i + 5 < raw.length && raw[i] == '\\' && raw[i + 1] == 'u')
                {
                    immutable lo = hex4(i + 2);
                    if (lo < 0xDC00 || lo > 0xDFFF)
                        fail(ErrorKind.badUtf8);
                    i += 6;
                    cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                }
                else
                    fail(ErrorKind.badUtf8);
            }
            else if (cp >= 0xDC00 && cp <= 0xDFFF)
                fail(ErrorKind.badUtf8);
            putUtf8(o, cp);
        }
    }
    return o[];
}

private void putUtf8(ref Appender!string o, uint cp) @safe pure
{
    if (cp < 0x80)
        o.put(cast(char) cp);
    else if (cp < 0x800)
    {
        o.put(cast(char)(0xC0 | (cp >> 6)));
        o.put(cast(char)(0x80 | (cp & 0x3F)));
    }
    else if (cp < 0x10000)
    {
        o.put(cast(char)(0xE0 | (cp >> 12)));
        o.put(cast(char)(0x80 | ((cp >> 6) & 0x3F)));
        o.put(cast(char)(0x80 | (cp & 0x3F)));
    }
    else
    {
        o.put(cast(char)(0xF0 | (cp >> 18)));
        o.put(cast(char)(0x80 | ((cp >> 12) & 0x3F)));
        o.put(cast(char)(0x80 | ((cp >> 6) & 0x3F)));
        o.put(cast(char)(0x80 | (cp & 0x3F)));
    }
}

/// Resolve an `int_` token. Throws `intRange` when it does not fit 64 bits.
long resolveInt(string text) @safe pure
{
    bool neg = text[0] == '-';
    ulong v = 0;
    foreach (char c; neg ? text[1 .. $] : text)
    {
        immutable d = c - '0';
        if (v > (ulong.max - d) / 10)
            fail(ErrorKind.intRange);
        v = v * 10 + d;
    }
    if (neg)
    {
        if (v > 0x8000_0000_0000_0000UL)
            fail(ErrorKind.intRange);
        return cast(long)(0UL - v);
    }
    if (v > long.max)
        fail(ErrorKind.intRange);
    return cast(long) v;
}

@safe pure unittest
{
    auto t = lex(`put "a" {x:-1}  <=`);
    assert(t.length == 8);
    assert(t[1].kind == Tok.str && t[1].text == "a");
    assert(t[5].kind == Tok.int_ && t[5].text == "-1");
    assert(lex(`a<=b`).length == 3);
    assert(lex(`a<=b`)[1].text == "<=");
    assert(lex("  \t ").length == 0);
    foreach (bad; [`007`, `-0`, `-`, `+1`, `=`, `!`, `"abc`, `"\x"`, `"\u00zz"`, `#`, "\"a\tb\""])
    {
        bool threw;
        try
            lex(bad);
        catch (TesseraError e)
            threw = e.kind == ErrorKind.syntax;
        assert(threw, bad);
    }
    assert(lex(`0`)[0].text == "0");
    assert(lex(`-5`)[0].kind == Tok.int_);
}

@safe pure unittest
{
    assert(unescape(`a\"b\\c\/d\n`) == "a\"b\\c/d\n");
    assert(unescape(`é`) == "é");
    assert(unescape(`😀`) == "😀");
    assert(unescape(`\u0000`) == "\0");
    foreach (bad; [`\ud800`, `\ud800x`, `\udc00`, `\ud800A`, `\ud800\ud800`])
    {
        bool threw;
        try
            unescape(bad);
        catch (TesseraError e)
            threw = e.kind == ErrorKind.badUtf8;
        assert(threw, bad);
    }
    assert(resolveInt("-9223372036854775808") == long.min);
    assert(resolveInt("9223372036854775807") == long.max);
    bool threw;
    try
        resolveInt("9223372036854775808");
    catch (TesseraError e)
        threw = e.kind == ErrorKind.intRange;
    assert(threw);
    threw = false;
    try
        resolveInt("99999999999999999999999");
    catch (TesseraError e)
        threw = e.kind == ErrorKind.intRange;
    assert(threw);
}
