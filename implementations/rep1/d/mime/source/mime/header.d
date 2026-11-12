/// Header block parsing: field lines, continuation lines and unfolding.
module mime.header;

import std.array : appender;
import mime.charset : decodeUtf8;
import mime.lines;
import mime.text;

@safe:

/// A header field after unfolding and UTF-8 decoding.
struct Header
{
    string name;   /// text before the first `:`, as written
    string raw;    /// everything after the first `:` (leading blank kept)

    /// The lower-cased name with SPACE/TAB stripped.
    string key() const pure nothrow { return toLowerAscii(stripBlanks(name)); }
}

private bool isFieldLine(const(ubyte)[] line, out size_t colon) pure nothrow @nogc
{
    foreach (i, c; line)
    {
        if (c == ':')
        {
            colon = i;
            return i > 0;
        }
        if (c < 0x21 || c > 0x7E)
            return false;
    }
    return false;
}

/// Parses the header block at the start of `data`.  `bodyStart` receives the
/// offset of the first body byte: just after the blank separator line, or at
/// the first line that is not a field line, or the end of `data`.
Header[] parseHeaders(const(ubyte)[] data, out size_t bodyStart) pure nothrow
{
    Header[] headers;
    const(ubyte)[][] pieces;   // lines of the field being collected
    size_t colon;

    void flush()
    {
        if (pieces.length == 0)
            return;
        const(ubyte)[] whole;
        if (pieces.length == 1)
            whole = pieces[0];
        else
        {
            auto app = appender!(ubyte[])();
            foreach (p; pieces)
                app.put(p);
            whole = app.data;
        }
        pieces.length = 0;
        size_t c = 0;
        while (whole[c] != ':')
            ++c;
        headers ~= Header(decodeUtf8(whole[0 .. c]), decodeUtf8(whole[c + 1 .. $]));
    }

    size_t pos = 0;
    while (pos < data.length)
    {
        const ln = nextLine(data, pos);
        const content = data[ln.start .. ln.end];
        if (content.length == 0)
        {
            flush();
            bodyStart = ln.next;
            return headers;
        }
        if (pieces.length != 0 && (content[0] == ' ' || content[0] == '\t'))
            pieces ~= content;
        else if (isFieldLine(content, colon))
        {
            flush();
            pieces ~= content;
        }
        else
        {
            flush();
            bodyStart = ln.start;
            return headers;
        }
        pos = ln.next;
    }
    flush();
    bodyStart = data.length;
    return headers;
}

/// The first header whose stripped, lower-cased name equals `key`
/// (which must already be lower-case), or null.
const(Header)* findHeader(const(Header)[] headers, string key) pure nothrow
{
    foreach (i; 0 .. headers.length)
        if (headers[i].key == key)
            return &headers[i];
    return null;
}

pure nothrow unittest
{
    static const(ubyte)[] u(string s) @trusted { return cast(const(ubyte)[]) s; }
    size_t body_;
    auto h = parseHeaders(u("Subject: a\n b\nX:y\n\nbody"), body_);
    assert(h.length == 2);
    assert(h[0].name == "Subject" && h[0].raw == " a b");
    assert(h[1].key == "x" && h[1].raw == "y");
    assert(body_ == 19);
    assert(findHeader(h, "x") !is null);
    assert(findHeader(h, "nope") is null);

    foreach (s; ["Subject :x\nfoo", "no colon here\nfoo", ": novalue\nfoo",
                 "From nobody Mon Sep  1 00:00:00 2025\nfoo", " lead: x\nfoo"])
    {
        h = parseHeaders(u(s), body_);
        assert(h.length == 0 && body_ == 0, s);
    }
    h = parseHeaders(u("A: 1\nnot a field\nbody"), body_);
    assert(h.length == 1 && body_ == 5);
    h = parseHeaders(u("A: 1"), body_);
    assert(h.length == 1 && body_ == 4);
}
