/// RFC 2047 encoded words and the two text decoders built on them:
/// `decode_unstructured` and `decode_display`.
module mime.encodedword;

import mime.ascii;
import mime.buffer;
import mime.charset;
import mime.syntax;
import mime.transfer;

/// A recognised encoded word.
struct EncodedWord
{
    size_t end; /// index just past the closing `=`
    string text; /// the decoded text
}

/// Tries to read an encoded word starting at `v[i]`. Returns false when none
/// starts there.
bool matchEncodedWord(const(char)[] v, size_t i, out EncodedWord word) @safe pure nothrow
{
    immutable n = v.length;
    if (i + 1 >= n || v[i] != '=' || v[i + 1] != '?')
        return false;
    // charset field: up to the first '?' at or after i+2
    size_t j = i + 2;
    while (j < n && v[j] != '?')
    {
        if (isBlank(v[j]))
            return false;
        j++;
    }
    if (j >= n || j == i + 2)
        return false;
    if (j + 2 >= n)
        return false;
    immutable enc = v[j + 1];
    if (!(enc == 'Q' || enc == 'q' || enc == 'B' || enc == 'b') || v[j + 2] != '?')
        return false;
    size_t m = j + 3;
    while (m < n && v[m] != '?')
    {
        if (isBlank(v[m]))
            return false;
        m++;
    }
    if (m + 1 >= n || v[m + 1] != '=')
        return false;

    auto text = v[j + 3 .. m];
    const(ubyte)[] bytes;
    if (enc == 'Q' || enc == 'q')
        bytes = decodeQ(text);
    else
        bytes = decodeBase64(cast(const(ubyte)[]) text);

    auto cs = v[i + 2 .. j];
    foreach (k, c; cs)
        if (c == '*')
        {
            cs = cs[0 .. k];
            break;
        }
    auto name = normalizeCharsetName(cs);
    if (name.length == 0)
        name = "us-ascii";
    word = EncodedWord(m + 2, decode(bytes, name));
    return true;
}

private ubyte[] decodeQ(const(char)[] t) @safe pure nothrow
{
    auto o = new ubyte[](t.length);
    size_t n = 0;
    for (size_t i = 0; i < t.length;)
    {
        immutable c = t[i];
        if (c == '_')
        {
            o[n++] = ' ';
            i++;
        }
        else if (c == '=' && i + 2 < t.length && hexValue(t[i + 1]) >= 0 && hexValue(t[i + 2]) >= 0)
        {
            o[n++] = cast(ubyte)(hexValue(t[i + 1]) * 16 + hexValue(t[i + 2]));
            i += 3;
        }
        else
        {
            o[n++] = c;
            i++;
        }
    }
    return o[0 .. n];
}

private enum ItemKind : ubyte
{
    encoded,
    space,
    literal,
}

private struct Item
{
    ItemKind kind;
    const(char)[] text;
}

private string joinItems(scope const(Item)[] items) @safe pure nothrow
{
    auto o = ByteBuffer(64);
    foreach (i, it; items)
    {
        if (it.kind == ItemKind.space && i > 0 && i + 1 < items.length
            && items[i - 1].kind == ItemKind.encoded && items[i + 1].kind == ItemKind.encoded)
            continue;
        o.put(it.text);
    }
    auto r = o.data;
    // strip leading and trailing SPACE / TAB
    size_t a = 0, b = r.length;
    while (a < b && (r[a] == ' ' || r[a] == '\t'))
        a++;
    while (b > a && (r[b - 1] == ' ' || r[b - 1] == '\t'))
        b--;
    return (() @trusted => cast(string) r[a .. b].idup)();
}

private string decodeItems(string v, bool display) @safe pure nothrow
{
    Item[] items;
    items.reserve(8);
    size_t i = 0;
    immutable n = v.length;
    size_t runStart = 0;
    ItemKind runKind = ItemKind.literal;
    bool inRun = false;

    void flush(size_t end) @safe pure nothrow
    {
        if (inRun && end > runStart)
            items ~= Item(runKind, v[runStart .. end]);
        inRun = false;
    }

    while (i < n)
    {
        immutable c = v[i];
        if (c == '=')
        {
            EncodedWord w;
            if (matchEncodedWord(v, i, w))
            {
                flush(i);
                items ~= Item(ItemKind.encoded, w.text);
                i = w.end;
                continue;
            }
        }
        else if (display && c == '(')
        {
            flush(i);
            i = skipComment(v, i);
            items ~= Item(ItemKind.space, " ");
            continue;
        }
        else if (display && c == '"')
        {
            flush(i);
            auto q = scanQuoted(v, i);
            items ~= Item(ItemKind.literal, q.text);
            i = q.end;
            continue;
        }
        immutable kind = isBlank(c) ? ItemKind.space : ItemKind.literal;
        if (!inRun || runKind != kind)
        {
            flush(i);
            inRun = true;
            runKind = kind;
            runStart = i;
        }
        i++;
    }
    flush(n);
    return joinItems(items);
}

/// `decode_unstructured(v)`: decodes the encoded words in `v`; blanks
/// between two adjacent encoded words vanish, all other text is kept, and
/// leading/trailing blanks are stripped.
string decodeUnstructured(string v) @safe pure nothrow
{
    return decodeItems(v, false);
}

/// `decode_display(s)`: like `decodeUnstructured`, but a parenthesised
/// comment becomes one space and a quoted string contributes its unescaped
/// contents verbatim (encoded words inside it are not decoded).
string decodeDisplay(string s) @safe pure nothrow
{
    return decodeItems(s, true);
}
