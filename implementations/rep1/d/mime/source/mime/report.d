/// Rendering of parsed messages to the normalised text dump, and writing the
/// dump (plus attachment payloads) into an output directory.
module mime.report;

import std.array : Appender, appender;
import std.conv : to;
import std.file : mkdirRecurse, write;
import std.format : format;
import std.path : buildPath;
import mime.address;
import mime.date;
import mime.escape;
import mime.header;
import mime.mailbox : RawMessage;
import mime.part;
import mime.text : collapse;
import mime.encodedword : decodeUnstructured;

@safe:

private string number4(size_t n) pure { return format("%04d", n); }
private string number3(size_t n) pure { return format("%03d", n); }

private bool isCollapsedHeader(string key) pure nothrow @nogc
{
    switch (key)
    {
    case "content-disposition", "content-id", "content-transfer-encoding", "content-type",
         "date", "in-reply-to", "message-id", "mime-version", "received", "references",
         "return-path":
        return true;
    default:
        return false;
    }
}

/// The dumped value of a header field.
string headerValue(const Header h) pure nothrow
{
    return isCollapsedHeader(h.key) ? collapse(h.raw) : decodeUnstructured(h.raw);
}

private void putLine(ref Appender!string app, string line) pure nothrow
{
    app.put(line);
    app.put('\n');
}

/// Renders one `summary.txt` line.
string summaryLine(size_t number, const Message m) pure
{
    return format("%s source=%s bytes=%d parts=%d attachments=%d text=%s html=%s",
        number4(number), q(m.sourceId), m.byteLength, m.parts.length, m.attachments.length,
        m.textBody is null ? "-" : m.textBody.index.to!string,
        m.htmlBody is null ? "-" : m.htmlBody.index.to!string);
}

/// Renders the whole `summary.txt`.
string renderSummary(const(Message)[] messages) pure
{
    auto app = appender!string();
    putLine(app, "messages " ~ messages.length.to!string);
    foreach (i, m; messages)
        putLine(app, summaryLine(i + 1, m));
    return app.data;
}

private void renderAddresses(ref Appender!string app, const Message m)
{
    foreach (name; ["from", "sender", "reply-to", "to", "cc", "bcc"])
    {
        size_t k = 0;
        foreach (ref h; m.root.headers)
        {
            if (h.key != name)
                continue;
            foreach (a; parseAddressList(h.raw))
                putLine(app, format("%s %d display=%s spec=%s", name, k++, q(a.display), q(a.spec)));
        }
    }
}

private void renderDate(ref Appender!string app, const Message m)
{
    const h = m.header("date");
    if (h is null)
    {
        putLine(app, "none");
        return;
    }
    putLine(app, "raw " ~ q(h.raw));
    const d = parseDate(h.raw);
    putLine(app, "valid " ~ (d.valid ? "yes" : "no"));
    if (d.valid)
    {
        putLine(app, "utc " ~ d.utc);
        putLine(app, "offset " ~ d.offset);
        putLine(app, "epoch " ~ d.epoch.to!string);
    }
}

private string roleName(Role r) pure nothrow @nogc
{
    final switch (r)
    {
    case Role.none: return "";
    case Role.text: return "text";
    case Role.html: return "html";
    case Role.attachment: return "attachment";
    }
}

private void renderStructure(ref Appender!string app, const Message m)
{
    // Depth of each part, from the tree.
    size_t[] depth = new size_t[m.parts.length];
    void mark(const Part p, size_t d)
    {
        depth[p.index] = d;
        foreach (c; p.children)
            mark(c, d + 1);
    }
    mark(m.root, 0);

    foreach (p; m.parts)
    {
        auto line = appender!string();
        foreach (_; 0 .. depth[p.index])
            line.put("  ");
        line.put(p.index.to!string);
        line.put(' ');
        line.put(p.mediaType);
        if (p.type == "text")
            line.put(" charset=" ~ p.charset);
        line.put(" cte=" ~ p.encoding);
        if (p.hasDisposition)
            line.put(" disposition=" ~ p.disposition);
        if (p.hasFilename)
            line.put(" filename=" ~ q(p.filename));
        if (p.kind == PartKind.multipart)
            line.put(" boundary=" ~ q(p.boundary));
        if (p.kind != PartKind.leaf)
            line.put(" parts=" ~ p.children.length.to!string);
        if (p.kind == PartKind.multipart)
        {
            line.put(" preamble=" ~ p.preambleLength.to!string);
            line.put(" epilogue=" ~ (p.hasEpilogue ? p.epilogueLength.to!string : "none"));
        }
        if (p.kind == PartKind.leaf)
        {
            line.put(" size=" ~ p.content.length.to!string);
            line.put(" adler32=" ~ hex8(p.checksum));
            line.put(" role=" ~ roleName(p.role));
        }
        putLine(app, line.data);
    }
}

private void renderBody(ref Appender!string app, string label, const Part p)
{
    if (p is null)
    {
        putLine(app, label ~ " none");
        return;
    }
    size_t chars = 0;
    foreach (dchar _; p.text)
        ++chars;
    putLine(app, format("%s %d chars %d", label, p.index, chars));
    string rest = p.text;
    while (rest.length != 0)
    {
        size_t nl = rest.length;
        foreach (i, char c; rest)
            if (c == '\n')
            {
                nl = i;
                break;
            }
        putLine(app, "| " ~ esc(rest[0 .. nl]));
        rest = nl < rest.length ? rest[nl + 1 .. $] : "";
    }
}

/// Path of an attachment's payload relative to the output directory.
string attachmentPath(size_t messageNumber, const Part p) pure
{
    return "parts/" ~ number4(messageNumber) ~ "/" ~ number3(p.index) ~ ".bin";
}

/// Renders `messages/NNNN.txt`.
string renderMessage(size_t number, const Message m)
{
    auto app = appender!string();
    putLine(app, "[message]");
    putLine(app, "id " ~ number4(number));
    putLine(app, "source " ~ q(m.sourceId));
    putLine(app, "");
    putLine(app, "[headers]");
    foreach (ref h; m.root.headers)
        putLine(app, h.key ~ ": " ~ q(headerValue(h)));
    putLine(app, "");
    putLine(app, "[addresses]");
    renderAddresses(app, m);
    putLine(app, "");
    putLine(app, "[date]");
    renderDate(app, m);
    putLine(app, "");
    putLine(app, "[structure]");
    renderStructure(app, m);
    putLine(app, "");
    putLine(app, "[body]");
    renderBody(app, "text", m.textBody);
    renderBody(app, "html", m.htmlBody);
    putLine(app, "");
    putLine(app, "[attachments]");
    foreach (p; m.attachments)
        putLine(app, format("%d type=%s filename=%s size=%d adler32=%s file=%s", p.index,
            p.mediaType, p.hasFilename ? q(p.filename) : "-", p.content.length,
            hex8(p.checksum), attachmentPath(number, p)));
    return app.data;
}

/// Parses every raw message and writes `summary.txt`, `messages/NNNN.txt` and
/// `parts/NNNN/PPP.bin` under `outDir` (created if missing).
void writeReport(RawMessage[] raws, string outDir) @trusted
{
    mkdirRecurse(outDir);
    mkdirRecurse(buildPath(outDir, "messages"));
    Message[] messages;
    foreach (i, raw; raws)
    {
        auto m = parseMessage(raw.bytes, raw.sourceId);
        messages ~= m;
        write(buildPath(outDir, "messages", number4(i + 1) ~ ".txt"), renderMessage(i + 1, m));
        if (m.attachments.length != 0)
        {
            mkdirRecurse(buildPath(outDir, "parts", number4(i + 1)));
            foreach (p; m.attachments)
                write(buildPath(outDir, attachmentPath(i + 1, p)), p.content);
        }
    }
    write(buildPath(outDir, "summary.txt"), renderSummary(messages));
}

/// The specification's worked example, as raw mbox bytes.
version (unittest) private immutable string workedExample =
    "From nobody Mon Sep  1 00:00:00 2025\n"
    ~ "Subject: =?utf-8?Q?Caf=C3=A9?= report\n"
    ~ "From: Ann Example <ann@example.com>\n"
    ~ "To: bob@example.org, Carl <carl@example.org>\n"
    ~ "Date: Mon, 1 Sep 2025 12:30:00 +0200\n"
    ~ "MIME-Version: 1.0\n"
    ~ "Content-Type: multipart/mixed; boundary=\"X\"\n"
    ~ "\n"
    ~ "ignore me\n"
    ~ "--X\n"
    ~ "Content-Type: text/plain; charset=iso-8859-1\n"
    ~ "\n"
    ~ "caf\xe9\n"
    ~ "--X\n"
    ~ "Content-Type: application/octet-stream\n"
    ~ "Content-Disposition: attachment; filename=\"a.bin\"\n"
    ~ "Content-Transfer-Encoding: base64\n"
    ~ "\n"
    ~ "AAECAw==\n"
    ~ "--X--\n"
    ~ "\n";

@system unittest
{
    import mime.mailbox : splitMbox;
    auto raws = splitMbox(cast(const(ubyte)[]) workedExample);
    assert(raws.length == 1 && raws[0].bytes.length == 427);
    auto m = parseMessage(raws[0].bytes, raws[0].sourceId);
    assert(renderSummary([m]) == "messages 1\n"
        ~ "0001 source=\"mbox:1\" bytes=427 parts=3 attachments=1 text=1 html=-\n");
    const expected =
`[message]
id 0001
source "mbox:1"

[headers]
subject: "Café report"
from: "Ann Example <ann@example.com>"
to: "bob@example.org, Carl <carl@example.org>"
date: "Mon, 1 Sep 2025 12:30:00 +0200"
mime-version: "1.0"
content-type: "multipart/mixed; boundary=\"X\""

[addresses]
from 0 display="Ann Example" spec="ann@example.com"
to 0 display="" spec="bob@example.org"
to 1 display="Carl" spec="carl@example.org"

[date]
raw " Mon, 1 Sep 2025 12:30:00 +0200"
valid yes
utc 2025-09-01T10:30:00Z
offset +0200
epoch 1756722600

[structure]
0 multipart/mixed cte=7bit boundary="X" parts=2 preamble=9 epilogue=0
  1 text/plain charset=iso-8859-1 cte=7bit size=4 adler32=04680214 role=text
  2 application/octet-stream cte=base64 disposition=attachment filename="a.bin" size=4 adler32=000e0007 role=attachment

[body]
text 1 chars 4
| café
html none

[attachments]
2 type=application/octet-stream filename="a.bin" size=4 adler32=000e0007 file=parts/0001/002.bin
`;
    assert(renderMessage(1, m) == expected);
}

@system unittest
{
    // Body line splitting and escaping.
    auto m = parseMessage(cast(const(ubyte)[]) "Content-Type: text/plain\n\na\\\n\n", "t");
    auto s = renderMessage(1, m);
    assert(s.length > 0);
    import std.algorithm : canFind;
    assert(s.canFind("text 0 chars 4\n| a\\\\\n| \n"));
    m = parseMessage(cast(const(ubyte)[]) "", "t");
    assert(renderMessage(1, m).canFind("[headers]\n\n[addresses]\n\n[date]\nnone\n"));
}
