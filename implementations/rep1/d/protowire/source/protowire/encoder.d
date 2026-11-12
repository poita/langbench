/// Value tree -> binary wire format (canonical, deterministic).
module protowire.encoder;

import protowire.schema;
import protowire.value;
import protowire.wire;

/// Encodes a message canonically: fields in increasing field-number order,
/// default singular scalars omitted, present singular messages always emitted,
/// repeated numeric fields packed, all varints minimal.
///
/// Runs in two linear passes (sizes, then bytes) so each node is visited once
/// regardless of nesting depth. The size pass caches sizes in the tree, so the
/// message is not safe to encode from several threads at once.
ubyte[] encodeMessage(Message m) @safe
{
    immutable total = computeSize(m);
    auto buf = new ubyte[cast(size_t) total];
    immutable end = writeMessage(m, buf, 0);
    assert(end == buf.length);
    return buf;
}

// Size in bytes of one value (or packed element) of numeric kind `kind`.
private size_t elementSize(FieldKind kind, ulong v) @safe pure nothrow @nogc
{
    with (FieldKind) switch (kind)
    {
    case sint32:
        return varintSize(zigzag32(cast(int) v));
    case sint64:
        return varintSize(zigzag64(cast(long) v));
    case bool_:
        return 1;
    case fixed32, sfixed32:
        return 4;
    case fixed64, sfixed64:
        return 8;
    default:
        return varintSize(v);
    }
}

private size_t tagSize(uint number) @safe pure nothrow @nogc
{
    return varintSize(cast(ulong) number << 3);
}

private ulong computeSize(Message m) @safe
{
    ulong total = 0;
    foreach (i, ref f; m.descriptor.fields)
    {
        auto slot = &m.slots[i];
        immutable ts = tagSize(f.number);
        if (f.kind == FieldKind.message)
        {
            if (f.repeated)
                foreach (child; slot.messages)
                {
                    immutable n = computeSize(child);
                    total += ts + varintSize(n) + n;
                }
            else if (slot.message !is null)
            {
                immutable n = computeSize(slot.message);
                total += ts + varintSize(n) + n;
            }
        }
        else if (f.kind == FieldKind.string_ || f.kind == FieldKind.bytes_)
        {
            if (f.repeated)
                foreach (b; slot.blobs)
                    total += ts + varintSize(b.length) + b.length;
            else if (slot.bytes.length)
                total += ts + varintSize(slot.bytes.length) + slot.bytes.length;
        }
        else if (f.repeated)
        {
            if (slot.numbers.length)
            {
                ulong payload = 0;
                foreach (v; slot.numbers)
                    payload += elementSize(f.kind, v);
                slot.packedSize = payload;
                total += ts + varintSize(payload) + payload;
            }
        }
        else if (slot.scalar != 0)
        {
            total += ts + elementSize(f.kind, slot.scalar);
        }
    }
    m.encodedSize = total;
    return total;
}

private size_t putTag(ubyte[] buf, size_t pos, uint number, WireType wt) @safe
{
    return putVarint(buf, pos, (cast(ulong) number << 3) | wt);
}

private size_t putBytes(ubyte[] buf, size_t pos, const(ubyte)[] data) @safe
{
    buf[pos .. pos + data.length] = data[];
    return pos + data.length;
}

private size_t putElement(ubyte[] buf, size_t pos, FieldKind kind, ulong v) @safe
{
    with (FieldKind) switch (kind)
    {
    case sint32:
        return putVarint(buf, pos, zigzag32(cast(int) v));
    case sint64:
        return putVarint(buf, pos, zigzag64(cast(long) v));
    case bool_:
        buf[pos] = v ? 1 : 0;
        return pos + 1;
    case fixed32, sfixed32:
        foreach (k; 0 .. 4)
            buf[pos + k] = cast(ubyte)(v >> (8 * k));
        return pos + 4;
    case fixed64, sfixed64:
        foreach (k; 0 .. 8)
            buf[pos + k] = cast(ubyte)(v >> (8 * k));
        return pos + 8;
    default:
        return putVarint(buf, pos, v);
    }
}

private size_t writeMessage(Message m, ubyte[] buf, size_t pos) @safe
{
    foreach (i, ref f; m.descriptor.fields)
    {
        auto slot = &m.slots[i];
        if (f.kind == FieldKind.message)
        {
            if (f.repeated)
                foreach (child; slot.messages)
                    pos = writeSubMessage(f, child, buf, pos);
            else if (slot.message !is null)
                pos = writeSubMessage(f, slot.message, buf, pos);
        }
        else if (f.kind == FieldKind.string_ || f.kind == FieldKind.bytes_)
        {
            if (f.repeated)
                foreach (b; slot.blobs)
                    pos = writeBlob(f.number, b, buf, pos);
            else if (slot.bytes.length)
                pos = writeBlob(f.number, slot.bytes, buf, pos);
        }
        else if (f.repeated)
        {
            if (slot.numbers.length)
            {
                pos = putTag(buf, pos, f.number, WireType.lengthDelimited);
                pos = putVarint(buf, pos, slot.packedSize);
                foreach (v; slot.numbers)
                    pos = putElement(buf, pos, f.kind, v);
            }
        }
        else if (slot.scalar != 0)
        {
            pos = putTag(buf, pos, f.number, wireTypeOf(f.kind));
            pos = putElement(buf, pos, f.kind, slot.scalar);
        }
    }
    return pos;
}

private size_t writeSubMessage(ref const FieldDescriptor f, Message child, ubyte[] buf, size_t pos) @safe
{
    pos = putTag(buf, pos, f.number, WireType.lengthDelimited);
    pos = putVarint(buf, pos, child.encodedSize);
    return writeMessage(child, buf, pos);
}

private size_t writeBlob(uint number, const(ubyte)[] data, ubyte[] buf, size_t pos) @safe
{
    pos = putTag(buf, pos, number, WireType.lengthDelimited);
    pos = putVarint(buf, pos, data.length);
    return putBytes(buf, pos, data);
}

@safe unittest
{
    import protowire.hex : toHex;
    import protowire.textformat : parseMessage;

    auto s = Schema.parse("message N { int32 a = 1; sint64 s = 2; fixed32 f = 3; sfixed64 g = 4; bool b = 5; "
            ~ "repeated bool bs = 6; repeated string ts = 7; N child = 8; repeated N kids = 9; "
            ~ "repeated sint32 zs = 10; uint64 u = 11; }");
    auto n = s["N"];
    string enc(string text) @safe
    {
        return toHex(encodeMessage(parseMessage(n, text)));
    }

    assert(enc("{}") == "");
    assert(enc("{a: -1}") == "08ffffffffffffffffff01");           // int32 -1 is ten bytes
    assert(enc("{u: 18446744073709551615}") == "58ffffffffffffffffff01");
    assert(enc("{s: -128}") == "10ff01");                          // zigzag
    assert(enc("{f: 4294967295, g: -1}") == "1dffffffff21ffffffffffffffff");
    assert(enc("{b: true, bs: [true, false]}") == "28013202" ~ "0100");
    assert(enc("{a: 0, b: false, ts: []}") == "");                 // defaults vanish
    assert(enc(`{ts: ["", "a"]}`) == "3a003a0161");                // elements are never dropped
    assert(enc("{child: {}}") == "4200");                           // present empty message
    assert(enc("{kids: [{}, {a: 1}], zs: [0, -1]}") == "4a004a02080152020001");
    assert(enc("{child: {child: {child: {a: 5}}}}") == "420642044202" ~ "0805");
}
