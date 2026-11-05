/// Address-list parsing (`From`, `To`, `Cc`, ...): a tokeniser, an element
/// splitter and a mailbox/group matcher following the specification's
/// forgiving grammar.
module mime.address;

import mime.ascii;
import mime.buffer;
import mime.encodedword;
import mime.syntax;

/// One parsed address.
struct Address
{
    string display; /// decoded display name, possibly empty
    string spec; /// `local@domain`, or the best-effort rendering
}

/// Token classes of the address tokeniser.
enum TokenKind : ubyte
{
    atom,
    quoted,
    literal,
    encoded,
    special,
}

/// A lexical token with the offset of its first character in the value.
struct Token
{
    TokenKind kind;
    string text;
    size_t start;
}

private bool isStop(char c) @safe pure nothrow @nogc
{
    switch (c)
    {
    case ' ', '\t', '(', ')', '<', '>', '[', ']', '@', ',', ':', ';', '.', '"', '\\':
        return true;
    default:
        return false;
    }
}

/// Splits an address-list value into tokens.
Token[] tokenize(string v) @safe pure nothrow
{
    Token[] toks;
    size_t i = 0;
    immutable n = v.length;
    while (i < n)
    {
        immutable c = v[i];
        if (isBlank(c))
        {
            i++;
            continue;
        }
        if (c == '(')
        {
            i = skipComment(v, i);
            continue;
        }
        if (c == '"')
        {
            auto q = scanQuoted(v, i);
            toks ~= Token(TokenKind.quoted, q.text, i);
            i = q.end;
            continue;
        }
        if (c == '[')
        {
            size_t j = i + 1;
            while (j < n && v[j] != ']')
                j += v[j] == '\\' ? 2 : 1;
            if (j > n)
                j = n;
            immutable end = j < n ? j + 1 : n;
            toks ~= Token(TokenKind.literal, v[i .. end], i);
            i = end;
            continue;
        }
        if (c == '=')
        {
            EncodedWord w;
            if (matchEncodedWord(v, i, w))
            {
                toks ~= Token(TokenKind.encoded, w.text, i);
                i = w.end;
                continue;
            }
        }
        switch (c)
        {
        case '<', '>', '@', ',', ':', ';', '.':
            toks ~= Token(TokenKind.special, v[i .. i + 1], i);
            i++;
            continue;
        case ')', ']', '\\':
            toks ~= Token(TokenKind.atom, v[i .. i + 1], i);
            i++;
            continue;
        default:
            break;
        }
        size_t j = i + 1;
        while (j < n && !isStop(v[j]))
            j++;
        toks ~= Token(TokenKind.atom, v[i .. j], i);
        i = j;
    }
    return toks;
}

private bool isSpecial(in Token t, char c) @safe pure nothrow @nogc
{
    return t.kind == TokenKind.special && t.text[0] == c;
}

/// Tries to match `toks` as an addr-spec; on success stores its rendering.
private bool matchAddrSpec(const(Token)[] toks, out string rendered) @safe pure nothrow
{
    if (toks.length == 0)
        return false;
    auto o = ByteBuffer(64);
    size_t i = 0;
    // local part
    bool expectWord = true;
    while (i < toks.length && !isSpecial(toks[i], '@'))
    {
        immutable t = toks[i];
        if (expectWord)
        {
            if (t.kind != TokenKind.atom && t.kind != TokenKind.quoted)
                return false;
            o.put(t.text);
        }
        else
        {
            if (!isSpecial(t, '.'))
                return false;
            o.put('.');
        }
        expectWord = !expectWord;
        i++;
    }
    if (expectWord) // empty local part, or it ended with a '.'
        return false;
    if (i == toks.length)
    {
        rendered = o.toString();
        return true;
    }
    // toks[i] is '@'
    i++;
    o.put('@');
    if (i >= toks.length)
        return false;
    if (toks[i].kind == TokenKind.literal)
    {
        if (i + 1 != toks.length)
            return false;
        o.put(toks[i].text);
        rendered = o.toString();
        return true;
    }
    expectWord = true;
    for (; i < toks.length; i++)
    {
        immutable t = toks[i];
        if (expectWord)
        {
            if (t.kind != TokenKind.atom)
                return false;
            o.put(t.text);
        }
        else
        {
            if (!isSpecial(t, '.'))
                return false;
            o.put('.');
        }
        expectWord = !expectWord;
    }
    if (expectWord)
        return false;
    rendered = o.toString();
    return true;
}

private void parseElement(string v, const(Token)[] toks, ref Address[] result) @safe pure nothrow
{
    // group syntax: a ':' before any '<' or '@'
    foreach (k, t; toks)
    {
        if (isSpecial(t, '<') || isSpecial(t, '@'))
            break;
        if (isSpecial(t, ':'))
        {
            toks = toks[k + 1 .. $];
            break;
        }
    }
    if (toks.length > 0 && isSpecial(toks[$ - 1], ';'))
        toks = toks[0 .. $ - 1];
    if (toks.length == 0)
        return;

    // alternative 1: [phrase] < addr-spec >
    size_t lt = size_t.max;
    foreach (k, t; toks)
        if (isSpecial(t, '<'))
        {
            lt = k;
            break;
        }
    if (lt != size_t.max)
    {
        size_t gt = size_t.max;
        foreach_reverse (k; lt + 1 .. toks.length)
            if (isSpecial(toks[k], '>'))
            {
                gt = k;
                break;
            }
        string spec;
        if (gt != size_t.max && matchAddrSpec(toks[lt + 1 .. gt], spec))
        {
            string display;
            if (lt > 0)
                display = decodeDisplay(v[toks[0].start .. toks[lt].start]);
            result ~= Address(display, spec);
            return;
        }
    }
    else
    {
        // alternative 2: addr-spec
        string spec;
        if (matchAddrSpec(toks, spec))
        {
            result ~= Address("", spec);
            return;
        }
    }
    auto o = ByteBuffer(64);
    foreach (t; toks)
        o.put(t.text);
    result ~= Address("", o.toString());
}

/// Parses an address-list header value (the unfolded raw text after the
/// colon) into addresses.
Address[] parseAddressList(string v) @safe pure nothrow
{
    auto toks = tokenize(v);
    Address[] result;
    size_t start = 0;
    size_t depth = 0;
    foreach (i, t; toks)
    {
        if (isSpecial(t, '<'))
            depth++;
        else if (isSpecial(t, '>'))
        {
            if (depth > 0)
                depth--;
        }
        else if (isSpecial(t, ',') && depth == 0)
        {
            parseElement(v, toks[start .. i], result);
            start = i + 1;
        }
    }
    parseElement(v, toks[start .. $], result);
    return result;
}
