/// Header-block parsing: line splitting, unfolding, field extraction.
module mime.header;

import mime.ascii;
import mime.charset;
import mime.encodedword;

/// One header field.
struct HeaderField
{
    string name; /// lower-cased name with surrounding blanks stripped
    string rawValue; /// unfolded text after the first `:` (decoded as UTF-8)

    /// The value as shown in the dump: `collapse(rawValue)` for the
    /// date-like fields, `decode_unstructured(rawValue)` otherwise.
    string displayValue() const @safe pure nothrow
    {
        switch (name)
        {
        case "content-disposition", "content-id", "content-transfer-encoding",
                "content-type", "date", "in-reply-to", "message-id",
                "mime-version", "received", "references", "return-path":
                return collapse(rawValue);
        default:
            return decodeUnstructured(rawValue);
        }
    }
}

/// The result of splitting a message into header block and body.
struct HeaderBlock
{
    HeaderField[] fields;
    size_t bodyStart; /// offset of the first body byte
}

/// Is `line` a field line: a `:` preceded by one or more bytes in
/// 0x21-0x39 or 0x3B-0x7E?
private bool isFieldLine(scope const(ubyte)[] line) @safe pure nothrow @nogc
{
    foreach (i, c; line)
    {
        if (c == ':')
            return i > 0;
        if (c < 0x21 || c > 0x7E)
            return false;
    }
    return false;
}

/// Parses the header block at the start of `data`, which must already have
/// LF-only line endings.
HeaderBlock parseHeaders(const(ubyte)[] data) @safe pure nothrow
{
    HeaderBlock hb;
    size_t pos = 0;
    immutable n = data.length;

    // current field under construction
    size_t fieldStart = 0; // offset of the first line's start
    size_t fieldLineEnd = 0; // end (exclusive, no LF) of the first line
    ubyte[] extra; // continuation text (without terminators)
    bool open = false;

    void closeField() @safe pure nothrow
    {
        if (!open)
            return;
        open = false;
        auto first = data[fieldStart .. fieldLineEnd];
        size_t colon = 0;
        while (first[colon] != ':')
            colon++;
        string name = toLowerAscii(stripBlanks(cast(string)(() @trusted => first[0 .. colon].idup)()));
        const(ubyte)[] valueBytes;
        if (extra.length == 0)
            valueBytes = first[colon + 1 .. $];
        else
            valueBytes = first[colon + 1 .. $] ~ extra;
        hb.fields ~= HeaderField(name, decodeUtf8(valueBytes));
        extra = null;
    }

    while (pos < n)
    {
        size_t e = pos;
        while (e < n && data[e] != '\n')
            e++;
        auto line = data[pos .. e];
        immutable next = e < n ? e + 1 : n;
        if (line.length == 0)
        {
            closeField();
            hb.bodyStart = next;
            return hb;
        }
        if (open && (line[0] == ' ' || line[0] == '\t'))
        {
            extra ~= line;
            pos = next;
            continue;
        }
        if (!isFieldLine(line))
        {
            closeField();
            hb.bodyStart = pos;
            return hb;
        }
        closeField();
        open = true;
        fieldStart = pos;
        fieldLineEnd = e;
        pos = next;
    }
    closeField();
    hb.bodyStart = n;
    return hb;
}

/// The first field called `name` (already lower-case), or null.
const(HeaderField)* findHeader(const(HeaderField)[] fields, string name) @safe pure nothrow @nogc
{
    foreach (i; 0 .. fields.length)
        if (fields[i].name == name)
            return &fields[i];
    return null;
}
