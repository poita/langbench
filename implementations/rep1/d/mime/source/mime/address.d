/// Address-list parsing: a tolerant tokeniser, element splitting and a
/// small `[phrase] <addr-spec>` / `addr-spec` matcher.
module mime.address;

import std.array : appender;
import mime.encodedword : decodeDisplay, decodeEncodedWord, matchEncodedWord;
import mime.text;

@safe:

/// One parsed mailbox.
struct Address
{
    string display; /// decoded display name (possibly empty)
    string spec;    /// `local@domain`, or a best-effort rendering of malformed input
}

/// Kinds of token produced by `tokenize`.
enum TokenKind : ubyte { atom, quoted, literal, encoded, special }

/// An address token.
struct Token
{
    TokenKind kind;
    string text;   /// decoded / unescaped text
    size_t start;  /// byte offset of the token in the source value
    size_t end;    /// one past the token's last byte
}

private bool isSpecialChar(char c) pure nothrow @nogc
{
    switch (c)
    {
    case '<', '>', '@', ',', ':', ';', '.':
        return true;
    default:
        return false;
    }
}

private bool isAtomStop(char c) pure nothrow @nogc
{
    if (isBlank(c) || isSpecialChar(c))
        return true;
    switch (c)
    {
    case '(', ')', '[', ']', '"', '\\':
        return true;
    default:
        return false;
    }
}

/// Splits an address-list value into tokens; comments are skipped.
Token[] tokenize(string v) pure nothrow
{
    Token[] toks;
    size_t i = 0;
    const n = v.length;
    while (i < n)
    {
        const c = v[i];
        size_t end;
        if (isBlank(c))
            ++i;
        else if (c == '(')
            i = skipComment(v, i);
        else if (c == '"')
        {
            const text = readQuoted(v, i, end);
            toks ~= Token(TokenKind.quoted, text, i, end);
            i = end;
        }
        else if (c == '[')
        {
            size_t j = i + 1;
            while (j < n && v[j] != ']')
                j += (v[j] == '\\' && j + 1 < n) ? 2 : 1;
            end = j < n ? j + 1 : n;
            toks ~= Token(TokenKind.literal, v[i .. end], i, end);
            i = end;
        }
        else if (c == '=' && matchEncodedWord(v, i, end))
        {
            toks ~= Token(TokenKind.encoded, decodeEncodedWord(v[i .. end]), i, end);
            i = end;
        }
        else if (isSpecialChar(c))
        {
            toks ~= Token(TokenKind.special, v[i .. i + 1], i, i + 1);
            ++i;
        }
        else if (c == ')' || c == ']' || c == '\\')
        {
            toks ~= Token(TokenKind.atom, v[i .. i + 1], i, i + 1);
            ++i;
        }
        else
        {
            size_t j = i + 1;
            while (j < n && !isAtomStop(v[j]))
                ++j;
            toks ~= Token(TokenKind.atom, v[i .. j], i, j);
            i = j;
        }
    }
    return toks;
}

private bool isSpecial(const Token t, char c) pure nothrow @nogc
{
    return t.kind == TokenKind.special && t.text[0] == c;
}

private bool alternates(const(Token)[] t, bool delegate(const Token) pure nothrow @safe isItem)
    pure nothrow @safe
{
    if (t.length == 0 || t.length % 2 == 0)
        return false;
    foreach (i, tok; t)
    {
        if (i % 2 == 0 ? !isItem(tok) : !isSpecial(tok, '.'))
            return false;
    }
    return true;
}

private string joinTexts(const(Token)[] t) pure nothrow
{
    auto app = appender!string();
    foreach (i, tok; t)
    {
        if (i % 2 == 1)
            app.put('.');
        if (i % 2 == 0)
            app.put(tok.text);
    }
    return app.data;
}

/// Matches `local [@ domain]` over exactly the given tokens.
private bool matchAddrSpec(const(Token)[] t, out string spec) pure nothrow
{
    size_t at = t.length;
    foreach (i, tok; t)
        if (isSpecial(tok, '@'))
        {
            at = i;
            break;
        }
    const local = t[0 .. at];
    if (!alternates(local, (const Token x) => x.kind == TokenKind.atom || x.kind == TokenKind.quoted))
        return false;
    if (at == t.length)
    {
        spec = joinTexts(local);
        return true;
    }
    const domain = t[at + 1 .. $];
    if (domain.length == 1 && domain[0].kind == TokenKind.literal)
    {
        spec = joinTexts(local) ~ "@" ~ domain[0].text;
        return true;
    }
    if (!alternates(domain, (const Token x) => x.kind == TokenKind.atom))
        return false;
    spec = joinTexts(local) ~ "@" ~ joinTexts(domain);
    return true;
}

private void parseElement(string v, const(Token)[] t, ref Address[] result) pure nothrow
{
    // Group syntax: drop everything up to a ':' that precedes any '<' or '@'.
    foreach (i, tok; t)
    {
        if (isSpecial(tok, '<') || isSpecial(tok, '@'))
            break;
        if (isSpecial(tok, ':'))
        {
            t = t[i + 1 .. $];
            break;
        }
    }
    if (t.length != 0 && isSpecial(t[$ - 1], ';'))
        t = t[0 .. $ - 1];
    if (t.length == 0)
        return;

    string spec;
    size_t lt = t.length;
    foreach (i, tok; t)
        if (isSpecial(tok, '<'))
        {
            lt = i;
            break;
        }
    if (lt < t.length)
    {
        size_t gt = t.length;
        foreach_reverse (i; lt + 1 .. t.length)
            if (isSpecial(t[i], '>'))
            {
                gt = i;
                break;
            }
        if (gt < t.length && matchAddrSpec(t[lt + 1 .. gt], spec))
        {
            const phrase = decodeDisplay(v[t[0].start .. t[lt].start]);
            result ~= Address(phrase, spec);
            return;
        }
    }
    else if (matchAddrSpec(t, spec))
    {
        result ~= Address("", spec);
        return;
    }
    auto app = appender!string();
    foreach (tok; t)
        app.put(tok.text);
    result ~= Address("", app.data);
}

/// Parses an address-list header value (unfolded, undecoded).
Address[] parseAddressList(string v) pure nothrow
{
    const toks = tokenize(v);
    Address[] result;
    size_t start = 0;
    int depth = 0;
    foreach (i, tok; toks)
    {
        if (isSpecial(tok, '<'))
            ++depth;
        else if (isSpecial(tok, '>'))
        {
            if (depth > 0)
                --depth;
        }
        else if (isSpecial(tok, ',') && depth == 0)
        {
            parseElement(v, toks[start .. i], result);
            start = i + 1;
        }
    }
    parseElement(v, toks[start .. $], result);
    return result;
}

pure nothrow unittest
{
    static string show(string v)
    {
        string r;
        foreach (a; parseAddressList(v))
            r ~= a.display ~ "|" ~ a.spec ~ ";";
        return r;
    }
    assert(show("Real Name <user@example.com>") == "Real Name|user@example.com;");
    assert(show("user@example.com (Real Name)") == "|user@example.com;");
    assert(show(`"Doe, John" <jd@x.com>`) == "Doe, John|jd@x.com;");
    assert(show("a@b.com, (c) d@e.com") == "|a@b.com;|d@e.com;");
    assert(show("Undisclosed recipients:;") == "");
    assert(show("grp: a@b.com, c@d.com;") == "|a@b.com;|c@d.com;");
    assert(show("=?utf-8?B?SsO2cmc=?= <j@x.de>") == "Jörg|j@x.de;");
    assert(show("foo (c (nested)) <a@b>") == "foo|a@b;");
    assert(show("ed <a@[10.0.0.1]>") == "ed|a@[10.0.0.1];");
    assert(show("broken <a@@b>") == "|broken<a@@b>;");
    assert(show("John Q. Public <jqp@example.com>") == "John Q. Public|jqp@example.com;");
    assert(show("Symantec Email Proxy") == "|SymantecEmailProxy;");
    assert(show(`"=?utf-8?Q?x?=" <a@b>`) == "=?utf-8?Q?x?=|a@b;");
    assert(show("a <b <c@d.com> , e@f.com>, g@h.com") == "|a<b<c@d.com>,e@f.com>;|g@h.com;");
    assert(show("John (the third) Public <jqp@x.com>") == "John   Public|jqp@x.com;");
    assert(show("") == "");
}
