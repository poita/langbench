/// Canonical text form: rendering a value tree, and parsing text against a descriptor.
///
/// ---
/// {a: 1, b: "x", c: [1, 2], d: {v: -5}, y: x"cafe"}
/// ---
module protowire.textformat;

import std.array : Appender;
import protowire.errors : TextException;
import protowire.hex : appendHex, hexDigitValue;
import protowire.schema;
import protowire.utf8 : isValidUtf8;
import protowire.value;

/// Maximum message nesting accepted when parsing text.
enum maxNestingDepth = 128;

alias CharBuffer = Appender!(char[]);

// ---------------------------------------------------------------- rendering

/// Renders `m` in canonical text form (fields by field number, defaults and
/// empty lists omitted, present sub-messages always printed).
string formatMessage(const Message m) @safe
{
    auto sink = CharBuffer();
    formatMessageTo(sink, m);
    return (() @trusted => cast(string) sink.data)();
}

/// Like `formatMessage`, but appends to `sink`; linear in the output size.
void formatMessageTo(ref CharBuffer sink, const Message m) @safe
{
    sink.put('{');
    bool first = true;
    foreach (i, ref f; m.descriptor.fields)
    {
        const slot = &m.slots[i];
        if (!hasOutput(f, *slot))
            continue;
        if (!first)
            sink.put(", ");
        first = false;
        sink.put(f.name);
        sink.put(": ");
        if (f.repeated)
        {
            sink.put('[');
            final switch (storage(f.kind))
            {
            case Storage.number:
                foreach (j, v; slot.numbers)
                {
                    if (j)
                        sink.put(", ");
                    formatScalar(sink, f.kind, v);
                }
                break;
            case Storage.blob:
                foreach (j, b; slot.blobs)
                {
                    if (j)
                        sink.put(", ");
                    formatBlob(sink, f.kind, b);
                }
                break;
            case Storage.message:
                foreach (j, c; slot.messages)
                {
                    if (j)
                        sink.put(", ");
                    formatMessageTo(sink, c);
                }
                break;
            }
            sink.put(']');
        }
        else
        {
            final switch (storage(f.kind))
            {
            case Storage.number:
                formatScalar(sink, f.kind, slot.scalar);
                break;
            case Storage.blob:
                formatBlob(sink, f.kind, slot.bytes);
                break;
            case Storage.message:
                formatMessageTo(sink, slot.message);
                break;
            }
        }
    }
    sink.put('}');
}

private enum Storage { number, blob, message }

private Storage storage(FieldKind k) @safe pure nothrow @nogc
{
    return isNumeric(k) ? Storage.number : k == FieldKind.message ? Storage.message : Storage.blob;
}

private bool hasOutput(ref const FieldDescriptor f, ref const Slot s) @safe pure nothrow @nogc
{
    final switch (storage(f.kind))
    {
    case Storage.number:
        return f.repeated ? s.numbers.length != 0 : s.scalar != 0;
    case Storage.blob:
        return f.repeated ? s.blobs.length != 0 : s.bytes.length != 0;
    case Storage.message:
        return f.repeated ? s.messages.length != 0 : s.message !is null;
    }
}

private void formatScalar(ref CharBuffer sink, FieldKind kind, ulong v) @safe
{
    if (kind == FieldKind.bool_)
        sink.put(v ? "true" : "false");
    else if (isSigned(kind))
        putSigned(sink, cast(long) v);
    else
        putUnsigned(sink, v);
}

private void putUnsigned(ref CharBuffer sink, ulong v) @safe
{
    char[20] buf = void;
    size_t i = buf.length;
    do
    {
        buf[--i] = cast(char)('0' + v % 10);
        v /= 10;
    }
    while (v);
    sink.put(buf[i .. $]);
}

private void putSigned(ref CharBuffer sink, long v) @safe
{
    if (v < 0)
    {
        sink.put('-');
        putUnsigned(sink, 0UL - cast(ulong) v);
    }
    else
        putUnsigned(sink, v);
}

private void formatBlob(ref CharBuffer sink, FieldKind kind, const(ubyte)[] b) @safe
{
    if (kind == FieldKind.bytes_)
    {
        sink.put("x\"");
        appendHex(sink, b);
        sink.put('"');
        return;
    }
    // string: escape ", \, control characters and DEL; everything else is raw UTF-8.
    sink.put('"');
    static immutable char[16] hexd = "0123456789abcdef";
    size_t runStart = 0;
    foreach (i, c; b)
    {
        if (c >= 0x20 && c != 0x7f && c != '"' && c != '\\')
            continue;
        if (i > runStart)
            sink.put((() @trusted => cast(const(char)[]) b[runStart .. i])());
        runStart = i + 1;
        switch (c)
        {
        case '"':
            sink.put(`\"`);
            break;
        case '\\':
            sink.put(`\\`);
            break;
        case '\n':
            sink.put(`\n`);
            break;
        case '\r':
            sink.put(`\r`);
            break;
        case '\t':
            sink.put(`\t`);
            break;
        default:
            sink.put(`\x`);
            sink.put(hexd[c >> 4]);
            sink.put(hexd[c & 15]);
            break;
        }
    }
    if (b.length > runStart)
        sink.put((() @trusted => cast(const(char)[]) b[runStart .. $])());
    sink.put('"');
}

// ------------------------------------------------------------------ parsing

/// Parses canonical-or-relaxed text (see the specification) as a message of
/// type `desc`. Throws `TextException` on any error. Linear in `text.length`.
Message parseMessage(const MessageDescriptor desc, scope const(char)[] text) @safe
{
    auto p = TextParser(text);
    auto m = p.parseMessage(desc, 0);
    p.skipSpaces();
    if (p.pos != text.length)
        throw new TextException("trailing text after message");
    return m;
}

private struct TextParser
{
    const(char)[] s;
    size_t pos;

    this(const(char)[] s) @safe pure nothrow @nogc
    {
        this.s = s;
    }

    void skipSpaces() @safe pure nothrow @nogc
    {
        while (pos < s.length && s[pos] == ' ')
            ++pos;
    }

    // Next character after optional spaces, consumed; throws at end of text.
    char next() @safe pure
    {
        skipSpaces();
        if (pos >= s.length)
            throw new TextException("unexpected end of text");
        return s[pos++];
    }

    void expect(char c) @safe pure
    {
        if (next() != c)
            throw new TextException("expected '" ~ c ~ "'");
    }

    // Looks at the next non-space character without consuming it (0 at end).
    char peek() @safe pure nothrow @nogc
    {
        skipSpaces();
        return pos < s.length ? s[pos] : '\0';
    }

    static bool isNameChar(char c) @safe pure nothrow @nogc
    {
        return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_';
    }

    const(char)[] word() @safe pure nothrow @nogc
    {
        immutable start = pos;
        while (pos < s.length && isNameChar(s[pos]))
            ++pos;
        return s[start .. pos];
    }

    Message parseMessage(const MessageDescriptor desc, uint depth) @safe
    {
        if (depth > maxNestingDepth)
            throw new TextException("nesting too deep");
        expect('{');
        auto m = new Message(desc);
        if (peek() == '}')
        {
            ++pos;
            return m;
        }
        while (true)
        {
            skipSpaces();
            const name = word();
            immutable idx = desc.indexOfName(name);
            if (idx < 0)
                throw new TextException("unknown field");
            auto slot = &m.slots[idx];
            if (slot.present)
                throw new TextException("duplicate field");
            slot.present = true;
            expect(':');
            parseFieldValue(desc.fields[idx], *slot, depth);
            immutable c = next();
            if (c == '}')
                return m;
            if (c != ',')
                throw new TextException("expected ',' or '}'");
        }
    }

    void parseFieldValue(ref const FieldDescriptor f, ref Slot slot, uint depth) @safe
    {
        if (!f.repeated)
        {
            parseElement(f, slot, depth);
            return;
        }
        expect('[');
        if (peek() == ']')
        {
            ++pos;
            return;
        }
        while (true)
        {
            parseElement(f, slot, depth);
            immutable c = next();
            if (c == ']')
                return;
            if (c != ',')
                throw new TextException("expected ',' or ']'");
        }
    }

    void parseElement(ref const FieldDescriptor f, ref Slot slot, uint depth) @safe
    {
        skipSpaces();
        final switch (storage(f.kind))
        {
        case Storage.number:
            immutable v = f.kind == FieldKind.bool_ ? parseBool() : parseInteger(f.kind);
            if (f.repeated)
                slot.numbers ~= v;
            else
                slot.scalar = v;
            break;
        case Storage.blob:
            auto b = f.kind == FieldKind.string_ ? parseString() : parseBytes();
            if (f.repeated)
                slot.blobs ~= b;
            else
                slot.bytes = b;
            break;
        case Storage.message:
            auto child = parseMessage(f.message, depth + 1);
            if (f.repeated)
                slot.messages ~= child;
            else
                slot.message = child;
            break;
        }
    }

    ulong parseBool() @safe pure
    {
        const w = word();
        if (w == "true")
            return 1;
        if (w == "false")
            return 0;
        throw new TextException("expected true or false");
    }

    ulong parseInteger(FieldKind kind) @safe pure
    {
        immutable negative = pos < s.length && s[pos] == '-';
        if (negative)
            ++pos;
        immutable start = pos;
        ulong mag = 0;
        while (pos < s.length && s[pos] >= '0' && s[pos] <= '9')
        {
            immutable d = s[pos] - '0';
            if (mag > (ulong.max - d) / 10)
                throw new TextException("integer out of range");
            mag = mag * 10 + d;
            ++pos;
        }
        immutable digits = pos - start;
        if (digits == 0)
            throw new TextException("expected integer");
        if (digits > 1 && s[start] == '0')
            throw new TextException("leading zero");
        immutable bits = bitWidth(kind);
        if (isSigned(kind))
        {
            immutable limit = 1UL << (bits - 1);
            if (negative)
            {
                if (mag == 0 || mag > limit)
                    throw new TextException("integer out of range");
                return 0UL - mag;
            }
            if (mag >= limit)
                throw new TextException("integer out of range");
            return mag;
        }
        if (negative)
            throw new TextException("negative unsigned integer");
        if (bits == 32 && mag > 0xffff_ffffUL)
            throw new TextException("integer out of range");
        return mag;
    }

    ubyte[] parseString() @safe
    {
        if (pos >= s.length || s[pos] != '"')
            throw new TextException("expected string");
        ++pos;
        auto out_ = Appender!(ubyte[])();
        while (true)
        {
            if (pos >= s.length)
                throw new TextException("unterminated string");
            immutable runStart = pos;
            while (pos < s.length && s[pos] >= 0x20 && s[pos] != '"' && s[pos] != '\\')
                ++pos;
            if (pos > runStart)
                out_.put(cast(const(ubyte)[]) s[runStart .. pos].representation);
            if (pos >= s.length)
                throw new TextException("unterminated string");
            immutable c = s[pos++];
            if (c == '"')
                break;
            if (c < 0x20)
                throw new TextException("control character in string");
            // backslash escape
            if (pos >= s.length)
                throw new TextException("unterminated string");
            immutable e = s[pos++];
            switch (e)
            {
            case '"':
                out_.put(cast(ubyte) '"');
                break;
            case '\\':
                out_.put(cast(ubyte) '\\');
                break;
            case 'n':
                out_.put(cast(ubyte) '\n');
                break;
            case 'r':
                out_.put(cast(ubyte) '\r');
                break;
            case 't':
                out_.put(cast(ubyte) '\t');
                break;
            case 'x':
                if (pos + 2 > s.length)
                    throw new TextException("bad \\x escape");
                immutable hi = hexValueAnyCase(s[pos]);
                immutable lo = hexValueAnyCase(s[pos + 1]);
                if (hi < 0 || lo < 0)
                    throw new TextException("bad \\x escape");
                pos += 2;
                out_.put(cast(ubyte)(hi * 16 + lo));
                break;
            default:
                throw new TextException("bad escape");
            }
        }
        auto result = out_.data;
        if (!isValidUtf8(result))
            throw new TextException("string is not valid UTF-8");
        return result;
    }

    ubyte[] parseBytes() @safe
    {
        if (pos + 1 >= s.length || s[pos] != 'x' || s[pos + 1] != '"')
            throw new TextException("expected bytes literal");
        pos += 2;
        immutable start = pos;
        while (pos < s.length && s[pos] != '"')
            ++pos;
        if (pos >= s.length)
            throw new TextException("unterminated bytes literal");
        auto hex = s[start .. pos];
        ++pos;
        import protowire.hex : fromHex;

        try
            return fromHex(hex);
        catch (Exception)
            throw new TextException("bad bytes literal");
    }
}

private int hexValueAnyCase(char c) @safe pure nothrow @nogc
{
    if (c >= 'A' && c <= 'F')
        return c - 'A' + 10;
    return hexDigitValue(c);
}

import std.string : representation;

@safe unittest
{
    auto s = Schema.parse("message Inner { sint32 v = 1; }"
            ~ "message Outer { int32 a = 1; string b = 2; repeated int32 c = 3; Inner d = 4; "
            ~ "bytes y = 5; repeated string ss = 6; bool k = 7; repeated Inner is_ = 8; uint64 u = 9; }");
    auto o = s["Outer"];

    auto m = parseMessage(o, `{a: 1, b: "x", c: [1, 2], d: {v: -5}}`);
    assert(formatMessage(m) == `{a: 1, b: "x", c: [1, 2], d: {v: -5}}`);

    // relaxed spacing and ordering; defaults vanish, {} stays
    m = parseMessage(o, ` { d:{} ,c:[] , a : 0,b:"" , y:x"" }  `);
    assert(formatMessage(m) == `{d: {}}`);

    // escapes
    m = parseMessage(o, `{b: "q\" b\\ \n\r\t \x00\x1F\x7f \xc3\xA9 é"}`);
    assert(formatMessage(m) == `{b: "q\" b\\ \n\r\t \x00\x1f\x7f é é"}`);

    m = parseMessage(o, `{y: x"00ff", ss: ["", "a"], k: true, is_: [{}, {v: 1}], u: 18446744073709551615}`);
    assert(formatMessage(m) == `{y: x"00ff", ss: ["", "a"], k: true, is_: [{}, {v: 1}], u: 18446744073709551615}`);
}

@safe unittest
{
    import std.exception : assertThrown;

    auto s = Schema.parse("message M { int32 a = 1; uint32 u = 2; int64 l = 3; bool b = 4; string s = 5; "
            ~ "bytes y = 6; repeated int32 r = 7; M m = 8; }");
    auto M = s["M"];
    foreach (bad; [
        ``, ` `, `{`, `{a: 1`, `{a: 1,}`, `{a 1}`, `{a: 1 b: 2}`, `{a: 1} x`, `{a: 1}}`,
        `{a: 1, a: 2}`, `{zz: 1}`, `{a: -0}`, `{a: 007}`, `{a: +5}`, `{a: 1.0}`, `{a: - 1}`,
        `{a: 2147483648}`, `{a: -2147483649}`, `{u: -1}`, `{u: 4294967296}`,
        `{l: 9223372036854775808}`, `{l: 99999999999999999999999}`,
        `{b: 1}`, `{b: True}`, `{b: tr ue}`, `{b: "true"}`, `{a: "1"}`, `{a: {}}`, `{a: [1]}`,
        `{r: 1}`, `{r: [1,]}`, `{r: [[1]]}`, `{s: 1}`, `{s: "\q"}`, `{s: "\x4"}`, `{s: "\xff"}`,
        "{s: \"a\tb\"}", "{a:\t1}", `{y: x "00"}`, `{y: x"0"}`, `{y: x"AB"}`, `{y: "00"}`, `{m: {a: 1}`,
        `{s: "abc}`, `{a:1}{}`
    ])
        assertThrown!TextException(parseMessage(M, bad), bad);

    assert(formatMessage(parseMessage(M, `{a:-2147483648,l:-9223372036854775808,u:4294967295}`))
            == `{a: -2147483648, u: 4294967295, l: -9223372036854775808}`);
}
