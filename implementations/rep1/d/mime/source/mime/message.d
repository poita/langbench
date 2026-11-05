/// The MIME part tree of one message, with body selection and attachments.
module mime.message;

import mime.adler32;
import mime.ascii;
import mime.charset;
import mime.header;
import mime.params;
import mime.transfer;

/// Marker for "no such part".
enum size_t noPart = size_t.max;

/// How a part is structured.
enum PartKind : ubyte
{
    leaf, /// has content
    multipart, /// has a boundary and zero or more children
    messageContainer, /// message/rfc822 with exactly one child
}

/// What a leaf is used for.
enum Role : ubyte
{
    none, /// not a leaf
    text,
    html,
    attachment,
}

/// One MIME part. Parts live in a flat, pre-order list (`Message.parts`).
struct Part
{
    size_t index; /// pre-order number; 0 is the whole message
    size_t depth; /// nesting depth; 0 for the whole message
    PartKind kind;
    HeaderField[] headers;

    string type; /// lower-case type, e.g. `text`
    string subtype; /// lower-case subtype, e.g. `plain`
    string charset; /// normalised charset name (meaningful for `text/*`)
    string encoding; /// the Content-Transfer-Encoding token (`7bit` when absent)

    bool hasDisposition;
    string disposition; /// disposition type when `hasDisposition`
    bool hasFilename;
    string filename;

    string boundary; /// multipart containers
    size_t childCount; /// containers
    size_t preambleLength; /// multipart containers
    bool hasEpilogue;
    size_t epilogueLength;

    const(ubyte)[] content; /// leaves: the transfer-decoded body
    uint checksum; /// leaves: Adler-32 of `content`
    Role role; /// leaves

    /// `type/subtype`.
    string mediaType() const @safe pure nothrow
    {
        return type ~ "/" ~ subtype;
    }

    /// True when the type is `text/*`.
    bool isText() const @safe pure nothrow @nogc
    {
        return type == "text";
    }
}

/// A parsed message.
struct Message
{
    Part[] parts; /// pre-order list; `parts[0]` is the whole message
    size_t textIndex = noPart; /// the text body part, or `noPart`
    size_t htmlIndex = noPart; /// the html body part, or `noPart`
    string text; /// decoded text body (when `textIndex != noPart`)
    string html; /// decoded html body (when `htmlIndex != noPart`)
    size_t[] attachments; /// part indices of the attachments, ascending

    /// The header fields of the whole message.
    const(HeaderField)[] headers() const @safe pure nothrow @nogc
    {
        return parts[0].headers;
    }
}

/// Replaces every CRLF with LF; a CR not followed by LF is kept.
ubyte[] normalizeLineEndings(scope const(ubyte)[] s) @safe pure nothrow
{
    auto o = new ubyte[](s.length);
    size_t n = 0;
    size_t i = 0;
    while (i < s.length)
    {
        size_t j = i;
        while (j < s.length && s[j] != '\r')
            j++;
        o[n .. n + (j - i)] = s[i .. j];
        n += j - i;
        if (j >= s.length)
            break;
        if (j + 1 < s.length && s[j + 1] == '\n')
        {
            // drop the CR; the LF is copied by the next run
            i = j + 1;
        }
        else
        {
            o[n++] = '\r';
            i = j + 1;
        }
    }
    return o[0 .. n];
}

/// Parses `raw` (a whole message, CRLF or LF) into its part tree.
Message parseMessage(scope const(ubyte)[] raw) @safe pure
{
    Message m;
    immutable data = (() @trusted => cast(immutable(ubyte)[]) normalizeLineEndings(raw))();
    parsePart(m, data, 0, "");
    selectBodies(m);
    return m;
}

private bool isToken(const(char)[] t) @safe pure nothrow @nogc
{
    if (t.length == 0)
        return false;
    foreach (c; t)
        switch (c)
        {
        case ' ', '\t', '(', ')', '<', '>', '@', ',', ';', ':', '\\', '"', '/', '[', ']', '?', '=':
            return false;
        default:
        }
    return true;
}

private bool splitMediaType(string v, out string type, out string subtype) @safe pure nothrow @nogc
{
    foreach (i, c; v)
        if (c == '/')
        {
            type = v[0 .. i];
            subtype = v[i + 1 .. $];
            return isToken(type) && isToken(subtype);
        }
    return false;
}

private bool isDelimiter(scope const(ubyte)[] line, scope const(ubyte)[] bb, out bool close) @safe pure nothrow @nogc
{
    if (line.length < 2 + bb.length || line[0] != '-' || line[1] != '-')
        return false;
    if (line[2 .. 2 + bb.length] != bb)
        return false;
    size_t i = 2 + bb.length;
    close = false;
    if (i + 1 < line.length && line[i] == '-' && line[i + 1] == '-')
    {
        close = true;
        i += 2;
    }
    while (i < line.length && (line[i] == ' ' || line[i] == '\t'))
        i++;
    return i == line.length;
}

/// Builds the part for `data` (LF-only) and its descendants; returns its index.
private size_t parsePart(ref Message m, immutable(ubyte)[] data, size_t depth, string parentType) @safe pure
{
    immutable idx = m.parts.length;
    m.parts.length = idx + 1;

    auto hb = parseHeaders(data);
    Part p;
    p.index = idx;
    p.depth = depth;
    p.headers = hb.fields;
    auto body_ = data[hb.bodyStart .. $];

    // Content-Type
    string ctRaw;
    bool haveCt = false;
    if (auto f = findHeader(hb.fields, "content-type"))
    {
        ctRaw = f.rawValue;
        haveCt = true;
    }
    auto ct = parseStructured(ctRaw);
    string type, subtype;
    if (!haveCt || !splitMediaType(ct.valueProper(), type, subtype))
    {
        if (parentType == "multipart/digest")
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
    if (p.isText)
    {
        string cs;
        p.charset = ct.find("charset", cs) ? normalizeCharsetName(cs) : "us-ascii";
    }

    // Content-Transfer-Encoding
    p.encoding = "7bit";
    if (auto f = findHeader(hb.fields, "content-transfer-encoding"))
        p.encoding = parseStructured(f.rawValue).valueProper();

    // Content-Disposition and filename
    if (auto f = findHeader(hb.fields, "content-disposition"))
    {
        auto cd = parseStructured(f.rawValue);
        p.hasDisposition = true;
        p.disposition = cd.valueProper();
        if (p.disposition.length == 0)
            p.disposition = "inline";
        p.hasFilename = cd.find("filename", p.filename);
    }
    if (!p.hasFilename)
        p.hasFilename = ct.find("name", p.filename);

    string boundary;
    ct.find("boundary", boundary);

    immutable mediaType = p.mediaType;
    if (p.type == "multipart" && boundary.length > 0)
    {
        p.kind = PartKind.multipart;
        p.boundary = boundary;
        m.parts[idx] = p;
        parseMultipart(m, idx, body_, depth, mediaType);
        return idx;
    }
    if (mediaType == "message/rfc822")
    {
        p.kind = PartKind.messageContainer;
        p.childCount = 1;
        m.parts[idx] = p;
        auto inner = decodeBody(body_, p.encoding);
        immutable innerData = (() @trusted => cast(immutable(ubyte)[]) inner)();
        parsePart(m, innerData, depth + 1, mediaType);
        return idx;
    }
    p.kind = PartKind.leaf;
    p.content = decodeBody(body_, p.encoding);
    p.checksum = adler32(p.content);
    m.parts[idx] = p;
    return idx;
}

private void parseMultipart(ref Message m, size_t idx, immutable(ubyte)[] body_, size_t depth, string mediaType) @safe pure
{
    immutable bb = (() @trusted => cast(immutable(ubyte)[]) m.parts[idx].boundary)();
    immutable n = body_.length;

    size_t pos = 0;
    bool seenFirst = false;
    size_t childStart = 0; // valid once seenFirst
    size_t children = 0;
    size_t preambleLen = 0;
    bool closed = false;
    size_t epilogueStart = 0;

    while (pos < n)
    {
        size_t e = pos;
        while (e < n && body_[e] != '\n')
            e++;
        immutable next = e < n ? e + 1 : n;
        bool close;
        if (body_[pos] == '-' && isDelimiter(body_[pos .. e], bb, close))
        {
            if (!seenFirst)
            {
                seenFirst = true;
                preambleLen = pos > 0 ? pos - 1 : 0;
            }
            else
            {
                size_t end = pos > childStart ? pos - 1 : pos;
                parsePart(m, body_[childStart .. end], depth + 1, mediaType);
                children++;
            }
            if (close)
            {
                closed = true;
                epilogueStart = next;
                break;
            }
            childStart = next;
        }
        pos = next;
    }

    Part* p = &m.parts[idx];
    if (!seenFirst)
    {
        p.preambleLength = n;
        p.hasEpilogue = false;
        p.childCount = 0;
        return;
    }
    if (!closed)
    {
        // the last child runs to the end of the body, less one trailing LF
        size_t end = n;
        if (end > childStart && body_[end - 1] == '\n')
            end--;
        parsePart(m, body_[childStart .. end], depth + 1, mediaType);
        children++;
    }
    p = &m.parts[idx];
    p.preambleLength = preambleLen;
    p.childCount = children;
    p.hasEpilogue = closed;
    p.epilogueLength = closed ? n - epilogueStart : 0;
}

/// Chooses the text and html bodies and lists the attachments.
private void selectBodies(ref Message m) @safe pure
{
    bool[] skip = new bool[](m.parts.length);
    // mark parts inside a message/rfc822 container (not body candidates)
    size_t[] stack; // depths of open message containers
    foreach (ref p; m.parts)
    {
        while (stack.length > 0 && p.depth <= stack[$ - 1])
            stack.length = stack.length - 1;
        if (stack.length > 0)
            skip[p.index] = true;
        if (p.kind == PartKind.messageContainer)
            stack ~= p.depth;
    }
    foreach (ref p; m.parts)
    {
        if (p.kind != PartKind.leaf)
            continue;
        bool candidate = !skip[p.index] && (!p.hasDisposition || p.disposition != "attachment");
        if (candidate && m.textIndex == noPart && p.type == "text" && p.subtype == "plain")
        {
            m.textIndex = p.index;
            p.role = Role.text;
            m.text = decode(p.content, p.charset);
        }
        else if (candidate && m.htmlIndex == noPart && p.type == "text" && p.subtype == "html")
        {
            m.htmlIndex = p.index;
            p.role = Role.html;
            m.html = decode(p.content, p.charset);
        }
        else
        {
            p.role = Role.attachment;
            m.attachments ~= p.index;
        }
    }
}
