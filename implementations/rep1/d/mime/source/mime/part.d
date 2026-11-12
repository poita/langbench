/// The MIME part tree and message-level analysis (bodies, attachments).
module mime.part;

import mime.charset : decode, normalizeCharset;
import mime.header;
import mime.multipart;
import mime.params;
import mime.text;
import mime.transfer : adler32, decodeBody;

@safe:

/// How a part is structured.
enum PartKind
{
    leaf,       /// carries content
    multipart,  /// `multipart/*` with a usable boundary
    message,    /// `message/rfc822`: exactly one child
}

/// What a leaf is used for in the message.
enum Role { none, text, html, attachment }

/// One node of the MIME tree.
final class Part
{
    size_t index;               /// pre-order number (the message is part 0)
    Header[] headers;
    string type, subtype;       /// effective, lower-case
    string charset;             /// normalised; meaningful for `text/*` only
    string encoding;            /// Content-Transfer-Encoding token
    bool hasDisposition;
    string disposition;         /// disposition type (`inline` when empty)
    bool hasFilename;
    string filename;
    PartKind kind;
    string boundary;            /// multipart containers
    size_t preambleLength;
    bool hasEpilogue;
    size_t epilogueLength;
    Part[] children;
    const(ubyte)[] content;     /// leaves: decoded bytes
    string text;                /// `text/*` leaves: decoded text
    uint checksum;              /// Adler-32 of `content`
    Role role;

    /// `type/subtype`
    string mediaType() const pure nothrow { return type ~ "/" ~ subtype; }
    /// Whether this is a `text/*` leaf.
    bool isText() const pure nothrow { return kind == PartKind.leaf && type == "text"; }
}

/// A fully parsed message.
final class Message
{
    string sourceId;
    size_t byteLength;          /// size before line-ending normalisation
    Part root;
    Part[] parts;               /// all parts in pre-order
    Part textBody;              /// first `text/plain` body candidate, or null
    Part htmlBody;              /// first `text/html` body candidate, or null
    Part[] attachments;         /// the remaining leaves, in part order

    /// The first top-level header named `key` (lower-case), or null.
    const(Header)* header(string key) const pure nothrow
    {
        return findHeader(root.headers, key);
    }
}

private struct Builder
{
    Part[] parts;

    Part parse(const(ubyte)[] bytes, bool parentIsDigest)
    {
        auto p = new Part;
        p.index = parts.length;
        parts ~= p;

        size_t bodyStart;
        p.headers = parseHeaders(bytes, bodyStart);
        const body_ = bytes[bodyStart .. $];

        Structured ct;
        const ctHeader = findHeader(p.headers, "content-type");
        string type, subtype;
        if (ctHeader !is null)
        {
            ct = parseStructured(ctHeader.raw);
            splitMediaType(toLowerAscii(ct.value), type, subtype);
        }
        if (type.length == 0)
        {
            if (parentIsDigest)
            {
                type = "message";
                subtype = "rfc822";
            }
            else
            {
                type = "text";
                subtype = "plain";
            }
        }
        p.type = type;
        p.subtype = subtype;

        const cteHeader = findHeader(p.headers, "content-transfer-encoding");
        p.encoding = cteHeader is null ? "7bit"
            : toLowerAscii(parseStructured(cteHeader.raw).value);

        Structured disp;
        const dispHeader = findHeader(p.headers, "content-disposition");
        if (dispHeader !is null)
        {
            disp = parseStructured(dispHeader.raw);
            p.hasDisposition = true;
            p.disposition = toLowerAscii(disp.value);
            if (p.disposition.length == 0)
                p.disposition = "inline";
        }
        if (disp.has("filename"))
        {
            p.hasFilename = true;
            p.filename = disp.get("filename");
        }
        else if (ct.has("name"))
        {
            p.hasFilename = true;
            p.filename = ct.get("name");
        }

        if (type == "text")
            p.charset = ct.has("charset") ? normalizeCharset(ct.get("charset")) : "us-ascii";

        if (type == "multipart" && ct.get("boundary").length != 0)
        {
            p.kind = PartKind.multipart;
            p.boundary = ct.get("boundary");
            const lay = splitMultipart(body_, (() @trusted => cast(const(ubyte)[]) p.boundary)());
            p.preambleLength = lay.preambleLength;
            p.hasEpilogue = lay.hasEpilogue;
            p.epilogueLength = lay.epilogueLength;
            const digest = subtype == "digest";
            foreach (child; lay.children)
                p.children ~= parse(child, digest);
        }
        else if (type == "message" && subtype == "rfc822")
        {
            p.kind = PartKind.message;
            p.children ~= parse(decodeBody(body_, p.encoding), false);
        }
        else
        {
            p.kind = PartKind.leaf;
            p.content = decodeBody(body_, p.encoding);
            p.checksum = adler32(p.content);
            if (type == "text")
                p.text = decode(p.content, p.charset);
        }
        return p;
    }
}

/// Parses one message.  `raw` is the message exactly as extracted from the
/// mailbox; line endings are normalised internally.
Message parseMessage(const(ubyte)[] raw, string sourceId)
{
    import mime.lines : normalizeLineEndings;

    auto m = new Message;
    m.sourceId = sourceId;
    m.byteLength = raw.length;
    Builder b;
    m.root = b.parse(normalizeLineEndings(raw), false);
    m.parts = b.parts;
    selectBodies(m);
    return m;
}

private void selectBodies(Message m)
{
    void walk(Part p)
    {
        if (p.kind == PartKind.leaf)
        {
            const candidate = !p.hasDisposition || p.disposition != "attachment";
            if (candidate && m.textBody is null && p.type == "text" && p.subtype == "plain")
                m.textBody = p;
            else if (candidate && m.htmlBody is null && p.type == "text" && p.subtype == "html")
                m.htmlBody = p;
        }
        if (p.kind == PartKind.multipart)
            foreach (c; p.children)
                walk(c);
    }
    walk(m.root);
    foreach (p; m.parts)
    {
        if (p.kind != PartKind.leaf)
            continue;
        if (p is m.textBody)
            p.role = Role.text;
        else if (p is m.htmlBody)
            p.role = Role.html;
        else
        {
            p.role = Role.attachment;
            m.attachments ~= p;
        }
    }
}

@system unittest
{
    static const(ubyte)[] u(string s) @trusted { return cast(const(ubyte)[]) s; }
    auto m = parseMessage(u("Content-Type: multipart/mixed; boundary=\"X\"\r\n\r\n"
        ~ "--X\r\nContent-Type: text/plain; charset=iso-8859-1\r\n\r\ncaf\xe9\r\n"
        ~ "--X\r\nContent-Type: application/octet-stream\r\nContent-Transfer-Encoding: base64\r\n"
        ~ "Content-Disposition: attachment; filename=a.bin\r\n\r\nAAECAw==\r\n--X--\r\n"), "t");
    assert(m.parts.length == 3);
    assert(m.textBody is m.parts[1] && m.htmlBody is null);
    assert(m.parts[1].text == "café");
    assert(m.attachments.length == 1 && m.attachments[0].filename == "a.bin");
    assert(m.attachments[0].content == [0, 1, 2, 3]);
    assert(m.root.kind == PartKind.multipart && m.root.children.length == 2);
}

@system unittest
{
    static const(ubyte)[] u(string s) @trusted { return cast(const(ubyte)[]) s; }
    // Digest children default to message/rfc822; nested leaves are attachments.
    auto m = parseMessage(u("Content-Type: multipart/digest; boundary=d\n\n--d\n\nSubject: s\n\nbody\n--d--\n"), "t");
    assert(m.parts.length == 3);
    assert(m.parts[1].kind == PartKind.message && m.parts[2].type == "text");
    assert(m.textBody is null && m.attachments.length == 1);
    // Boundary-less multipart is a leaf; bad content type falls back to text/plain.
    m = parseMessage(u("Content-Type: multipart/mixed\n\nhi"), "t");
    assert(m.root.kind == PartKind.leaf && m.root.role == Role.attachment);
    m = parseMessage(u("Content-Type: bogus\n\nhi"), "t");
    assert(m.textBody is m.root && m.root.text == "hi");
}
