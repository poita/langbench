/// RFC 2047 encoded words and the two header-text decoders built on them.
module mime.encodedword;

import std.array : appender;
import mime.charset : decode;
import mime.text;
import mime.transfer : decodeBase64, hexDigit;

@safe:

/// Tests whether an encoded word (`=?charset?Q|B?text?=`) starts at `v[i]`.
/// On success sets `end` to the index just after it.
bool matchEncodedWord(string v, size_t i, out size_t end) pure nothrow @nogc
{
    const n = v.length;
    if (i + 1 >= n || v[i] != '=' || v[i + 1] != '?')
        return false;
    size_t j = i + 2;
    while (j < n && v[j] != '?')
    {
        if (isBlank(v[j]))
            return false;
        ++j;
    }
    if (j >= n || j == i + 2)
        return false;
    if (j + 2 >= n)
        return false;
    const e = v[j + 1];
    if (e != 'Q' && e != 'q' && e != 'B' && e != 'b')
        return false;
    if (v[j + 2] != '?')
        return false;
    size_t m = j + 3;
    while (m < n && v[m] != '?')
    {
        if (isBlank(v[m]))
            return false;
        ++m;
    }
    if (m + 1 >= n || v[m + 1] != '=')
        return false;
    end = m + 2;
    return true;
}

/// Decodes one encoded word previously recognised by `matchEncodedWord`
/// (`word` is exactly the matched text).
string decodeEncodedWord(string word) pure nothrow
{
    size_t j = 2;
    while (word[j] != '?') ++j;
    string charset = word[2 .. j];
    foreach (k, char c; charset)
        if (c == '*')
        {
            charset = charset[0 .. k];
            break;
        }
    charset = stripBlanks(toLowerAscii(charset));
    if (charset.length == 0)
        charset = "us-ascii";
    const enc = word[j + 1];
    const text = word[j + 3 .. $ - 2];
    const(ubyte)[] bytes = (() @trusted => cast(const(ubyte)[]) text)();
    if (enc == 'B' || enc == 'b')
        return decode(decodeBase64(bytes), charset);
    // Q encoding.
    auto app = appender!(ubyte[])();
    size_t i = 0;
    while (i < bytes.length)
    {
        const c = bytes[i];
        if (c == '_')
        {
            app.put(' ');
            ++i;
        }
        else if (c == '=' && i + 2 < bytes.length && hexDigit(cast(char) bytes[i + 1]) >= 0
                 && hexDigit(cast(char) bytes[i + 2]) >= 0)
        {
            app.put(cast(ubyte)(hexDigit(cast(char) bytes[i + 1]) * 16 + hexDigit(cast(char) bytes[i + 2])));
            i += 3;
        }
        else
        {
            app.put(c);
            ++i;
        }
    }
    return decode(app.data, charset);
}

private enum Kind : ubyte { encoded, space, literal }

private struct Item
{
    Kind kind;
    string text;
}

private string scanAndJoin(string v, bool display) pure nothrow
{
    Item[] items;
    size_t i = 0;
    const n = v.length;
    while (i < n)
    {
        const c = v[i];
        size_t end;
        if (c == '=' && matchEncodedWord(v, i, end))
        {
            items ~= Item(Kind.encoded, decodeEncodedWord(v[i .. end]));
            i = end;
        }
        else if (display && c == '(')
        {
            i = skipComment(v, i);
            items ~= Item(Kind.space, " ");
        }
        else if (display && c == '"')
        {
            items ~= Item(Kind.literal, readQuoted(v, i, end));
            i = end;
        }
        else if (isBlank(c))
        {
            size_t j = i + 1;
            while (j < n && isBlank(v[j])) ++j;
            items ~= Item(Kind.space, v[i .. j]);
            i = j;
        }
        else
        {
            size_t j = i + 1;
            while (j < n && !isBlank(v[j]) && !(display && (v[j] == '(' || v[j] == '"'))
                   && !(v[j] == '=' && matchEncodedWord(v, j, end)))
                ++j;
            items ~= Item(Kind.literal, v[i .. j]);
            i = j;
        }
    }
    auto app = appender!string();
    foreach (k, it; items)
    {
        if (it.kind == Kind.space && k > 0 && k + 1 < items.length
            && items[k - 1].kind == Kind.encoded && items[k + 1].kind == Kind.encoded)
            continue;
        app.put(it.text);
    }
    return stripBlanks(app.data);
}

/// `decode_unstructured`: decodes encoded words; whitespace between two
/// adjacent encoded words is dropped, the result is stripped.
string decodeUnstructured(string v) pure nothrow
{
    return scanAndJoin(v, false);
}

/// `decode_display`: like `decodeUnstructured`, but comments become one
/// space and quoted strings contribute their (undecoded) contents.
string decodeDisplay(string v) pure nothrow
{
    return scanAndJoin(v, true);
}

pure nothrow unittest
{
    assert(decodeUnstructured("=?utf-8?Q?caf=C3=A9?=") == "café");
    assert(decodeUnstructured("=?utf-8?Q?a?=   =?utf-8?Q?b?=") == "ab");
    assert(decodeUnstructured("x =?utf-8?Q?a?= y") == "x a y");
    assert(decodeUnstructured("=?utf-8?Q?a?=b") == "ab");
    assert(decodeUnstructured("=?iso-8859-1?Q?caf=E9?=") == "café");
    assert(decodeUnstructured("=?windows-1252?Q?smart=92quote?=") == "smart’quote");
    assert(decodeUnstructured("=?utf-8?B?SsO2cmc=?=") == "Jörg");
    assert(decodeUnstructured("=?utf-8*en?Q?hi?=") == "hi");
    assert(decodeUnstructured("=?utf-8?X?hi?=") == "=?utf-8?X?hi?=");
    assert(decodeUnstructured("  plain    spaced   text  ") == "plain    spaced   text");
    assert(decodeUnstructured("=?utf-8?Q?a?= \t =?utf-8?Q?b?= \t c") == "ab \t c");
    assert(decodeUnstructured("=?utf-8?Q?a_b=?=") == "a b=");
}

pure nothrow unittest
{
    assert(decodeDisplay("John Q. Public ") == "John Q. Public");
    assert(decodeDisplay(`"Doe, John" `) == "Doe, John");
    assert(decodeDisplay("=?utf-8?B?SsO2cmc=?= ") == "Jörg");
    assert(decodeDisplay("John (the third) Public ") == "John   Public");
    assert(decodeDisplay(`"=?utf-8?Q?x?=" `) == "=?utf-8?Q?x?=");
}

pure nothrow @nogc unittest
{
    size_t end;
    assert(matchEncodedWord("=?a?q??=", 0, end) && end == 8);
    assert(!matchEncodedWord("=??q?x?=", 0, end));
    assert(!matchEncodedWord("=?a b?q?x?=", 0, end));
    assert(!matchEncodedWord("=?a?q?x y?=", 0, end));
    assert(!matchEncodedWord("=?a?q?x?", 0, end));
}
