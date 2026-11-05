/// Rendering of the normalised text dump (`messages/NNNN.txt`) and the
/// summary line.
module mime.render;

import mime.address;
import mime.buffer;
import mime.charset;
import mime.date;
import mime.header;
import mime.ascii;
import mime.message;

/// Appends `esc(s)`: backslash, LF, CR, TAB and `"` get backslash escapes,
/// other control characters, DEL and U+0080-U+009F become `\xHH`.
void putEscaped(ref ByteBuffer o, scope const(char)[] s) @safe pure nothrow
{
    static immutable hexDigits = "0123456789abcdef";
    size_t run = 0;
    size_t i = 0;
    immutable n = s.length;

    void hexEscape(uint v) @safe pure nothrow
    {
        o.put('\\');
        o.put('x');
        o.put(hexDigits[v >> 4]);
        o.put(hexDigits[v & 15]);
    }

    while (i < n)
    {
        immutable c = cast(ubyte) s[i];
        if (c >= 0x20 && c < 0x7F && c != '\\' && c != '"')
        {
            i++;
            continue;
        }
        if (c >= 0x80)
        {
            if (c == 0xC2 && i + 1 < n && cast(ubyte) s[i + 1] < 0xA0)
            {
                o.put(s[run .. i]);
                hexEscape(cast(ubyte) s[i + 1]);
                i += 2;
                run = i;
            }
            else
                i++;
            continue;
        }
        o.put(s[run .. i]);
        switch (c)
        {
        case '\\':
            o.put("\\\\");
            break;
        case '"':
            o.put("\\\"");
            break;
        case '\n':
            o.put("\\n");
            break;
        case '\r':
            o.put("\\r");
            break;
        case '\t':
            o.put("\\t");
            break;
        default:
            hexEscape(c);
        }
        i++;
        run = i;
    }
    o.put(s[run .. n]);
}

/// Appends `q(s)`: `"` + `esc(s)` + `"`.
void putQuoted(ref ByteBuffer o, scope const(char)[] s) @safe pure nothrow
{
    o.put('"');
    putEscaped(o, s);
    o.put('"');
}

/// Appends the summary line (without the message number prefix handling
/// shown here: `NNNN source=... bytes=... parts=... attachments=... text=... html=...`).
void putSummaryLine(ref ByteBuffer o, size_t number, string sourceId, size_t byteLength, scope ref const Message m) @safe pure nothrow
{
    o.putUint(number, 4);
    o.put(" source=");
    putQuoted(o, sourceId);
    o.put(" bytes=");
    o.putUint(byteLength);
    o.put(" parts=");
    o.putUint(m.parts.length);
    o.put(" attachments=");
    o.putUint(m.attachments.length);
    o.put(" text=");
    putIndexOrDash(o, m.textIndex);
    o.put(" html=");
    putIndexOrDash(o, m.htmlIndex);
    o.put('\n');
}

private void putIndexOrDash(ref ByteBuffer o, size_t idx) @safe pure nothrow
{
    if (idx == noPart)
        o.put('-');
    else
        o.putUint(idx);
}

private static immutable string[] addressHeaders = ["from", "sender", "reply-to", "to", "cc", "bcc"];

private void putBodySection(ref ByteBuffer o, string label, size_t index, scope const(char)[] text) @safe pure nothrow
{
    o.put(label);
    if (index == noPart)
    {
        o.put(" none\n");
        return;
    }
    o.put(' ');
    o.putUint(index);
    o.put(" chars ");
    o.putUint(codePointCount(text));
    o.put('\n');
    size_t pos = 0;
    while (pos < text.length)
    {
        size_t e = pos;
        while (e < text.length && text[e] != '\n')
            e++;
        o.put("| ");
        putEscaped(o, text[pos .. e]);
        o.put('\n');
        pos = e + 1;
    }
}

private void putPartLine(ref ByteBuffer o, scope ref const Part p) @safe pure nothrow
{
    foreach (_; 0 .. p.depth)
        o.put("  ");
    o.putUint(p.index);
    o.put(' ');
    o.put(p.type);
    o.put('/');
    o.put(p.subtype);
    if (p.isText)
    {
        o.put(" charset=");
        o.put(p.charset);
    }
    o.put(" cte=");
    o.put(p.encoding);
    if (p.hasDisposition)
    {
        o.put(" disposition=");
        o.put(p.disposition);
    }
    if (p.hasFilename)
    {
        o.put(" filename=");
        putQuoted(o, p.filename);
    }
    if (p.kind == PartKind.multipart)
    {
        o.put(" boundary=");
        putQuoted(o, p.boundary);
    }
    if (p.kind != PartKind.leaf)
    {
        o.put(" parts=");
        o.putUint(p.childCount);
    }
    if (p.kind == PartKind.multipart)
    {
        o.put(" preamble=");
        o.putUint(p.preambleLength);
        o.put(" epilogue=");
        if (p.hasEpilogue)
            o.putUint(p.epilogueLength);
        else
            o.put("none");
    }
    if (p.kind == PartKind.leaf)
    {
        o.put(" size=");
        o.putUint(p.content.length);
        o.put(" adler32=");
        o.putHex32(p.checksum);
        o.put(" role=");
        final switch (p.role)
        {
        case Role.none:
        case Role.attachment:
            o.put("attachment");
            break;
        case Role.text:
            o.put("text");
            break;
        case Role.html:
            o.put("html");
            break;
        }
    }
    o.put('\n');
}

/// Path of an attachment's file relative to the output directory.
string attachmentPath(size_t number, size_t partIndex) @safe pure nothrow
{
    auto o = ByteBuffer(32);
    o.put("parts/");
    o.putUint(number, 4);
    o.put('/');
    o.putUint(partIndex, 3);
    o.put(".bin");
    return o.toString();
}

/// Renders the dump of message number `number` (1-based) into `o`.
void renderMessage(ref ByteBuffer o, size_t number, string sourceId, scope ref const Message m) @safe pure nothrow
{
    o.put("[message]\nid ");
    o.putUint(number, 4);
    o.put("\nsource ");
    putQuoted(o, sourceId);

    o.put("\n\n[headers]\n");
    foreach (ref f; m.headers)
    {
        o.put(f.name);
        o.put(": ");
        putQuoted(o, f.displayValue());
        o.put('\n');
    }

    o.put("\n[addresses]\n");
    foreach (hname; addressHeaders)
    {
        size_t k = 0;
        foreach (ref f; m.headers)
        {
            if (f.name != hname)
                continue;
            foreach (ref a; parseAddressList(f.rawValue))
            {
                o.put(hname);
                o.put(' ');
                o.putUint(k++);
                o.put(" display=");
                putQuoted(o, a.display);
                o.put(" spec=");
                putQuoted(o, a.spec);
                o.put('\n');
            }
        }
    }

    o.put("\n[date]\n");
    if (auto f = findHeader(m.headers, "date"))
    {
        o.put("raw ");
        putQuoted(o, f.rawValue);
        ParsedDate d;
        if (parseDate(f.rawValue, d))
        {
            o.put("\nvalid yes\nutc ");
            putUtc(o, d.epoch);
            o.put("\noffset ");
            putOffset(o, d.offsetMinutes);
            o.put("\nepoch ");
            o.putInt(d.epoch);
            o.put('\n');
        }
        else
            o.put("\nvalid no\n");
    }
    else
        o.put("none\n");

    o.put("\n[structure]\n");
    foreach (ref p; m.parts)
        putPartLine(o, p);

    o.put("\n[body]\n");
    putBodySection(o, "text", m.textIndex, m.text);
    putBodySection(o, "html", m.htmlIndex, m.html);

    o.put("\n[attachments]\n");
    foreach (idx; m.attachments)
    {
        ref const p = m.parts[idx];
        o.putUint(idx);
        o.put(" type=");
        o.put(p.type);
        o.put('/');
        o.put(p.subtype);
        o.put(" filename=");
        if (p.hasFilename)
            putQuoted(o, p.filename);
        else
            o.put('-');
        o.put(" size=");
        o.putUint(p.content.length);
        o.put(" adler32=");
        o.putHex32(p.checksum);
        o.put(" file=");
        o.put(attachmentPath(number, idx));
        o.put('\n');
    }
}
