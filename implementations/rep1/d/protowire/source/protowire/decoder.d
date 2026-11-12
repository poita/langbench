/// Binary wire format -> value tree.
module protowire.decoder;

import protowire.errors : WireException;
import protowire.schema;
import protowire.utf8 : isValidUtf8;
import protowire.value;
import protowire.wire;

/// Maximum message nesting accepted when decoding.
enum maxNestingDepth = 128;

/// Decodes `data` as a message of type `desc`.
///
/// Follows proto3 semantics: unknown fields and fields with a mismatched wire
/// type are skipped, repeated numeric fields may be packed or unpacked,
/// repeated occurrences of a singular sub-message are merged, and strings must
/// be valid UTF-8. Throws `WireException` on malformed data. Runs in time
/// linear in `data.length`.
Message decodeMessage(const MessageDescriptor desc, const(ubyte)[] data) @safe
{
    auto m = new Message(desc);
    decodeInto(m, data, 0);
    return m;
}

private void decodeInto(Message m, const(ubyte)[] data, uint depth) @safe
{
    if (depth > maxNestingDepth)
        throw new WireException("nesting too deep");
    auto r = Reader(data);
    const desc = m.descriptor;
    while (!r.empty)
    {
        immutable tag = r.readTag();
        if (tag.wireType == WireType.endGroup)
            throw new WireException("unexpected end group");
        immutable idx = desc.indexOfNumber(tag.fieldNumber);
        if (idx < 0)
        {
            r.skipValue(tag);
            continue;
        }
        decodeField(desc.fields[idx], m.slots[idx], r, tag, depth);
    }
}

private void decodeField(ref const FieldDescriptor f, ref Slot slot, ref Reader r,
        Tag tag, uint depth) @safe
{
    immutable kind = f.kind;
    if (kind == FieldKind.message || kind == FieldKind.string_ || kind == FieldKind.bytes_)
    {
        if (tag.wireType != WireType.lengthDelimited)
        {
            r.skipValue(tag);
            return;
        }
        auto payload = r.readLengthDelimited();
        if (kind == FieldKind.message)
        {
            if (f.repeated)
            {
                auto child = new Message(f.message);
                decodeInto(child, payload, depth + 1);
                slot.messages ~= child;
            }
            else
            {
                if (slot.message is null)
                    slot.message = new Message(f.message);
                decodeInto(slot.message, payload, depth + 1);
            }
        }
        else
        {
            if (kind == FieldKind.string_ && !isValidUtf8(payload))
                throw new WireException("invalid UTF-8 in string");
            if (f.repeated)
                slot.blobs ~= payload.dup;
            else
                slot.bytes = payload.dup;
        }
        slot.present = true;
        return;
    }

    // Numeric / bool field.
    if (tag.wireType == wireTypeOf(kind))
    {
        immutable v = tag.wireType == WireType.varint ? fromVarint(kind, r.readVarint())
            : tag.wireType == WireType.fixed32 ? fromFixed32(kind, r.readFixed32())
            : r.readFixed64();
        if (f.repeated)
            slot.numbers ~= v;
        else
            slot.scalar = v;
        slot.present = true;
    }
    else if (f.repeated && tag.wireType == WireType.lengthDelimited)
    {
        decodePacked(kind, r.readLengthDelimited(), slot);
        slot.present = true;
    }
    else
    {
        r.skipValue(tag);
    }
}

private void decodePacked(FieldKind kind, const(ubyte)[] payload, ref Slot slot) @safe
{
    auto pr = Reader(payload);
    switch (wireTypeOf(kind))
    {
    case WireType.varint:
        while (!pr.empty)
            slot.numbers ~= fromVarint(kind, pr.readVarint());
        break;
    case WireType.fixed32:
        if (payload.length % 4)
            throw new WireException("packed fixed32 length not a multiple of 4");
        slot.numbers.reserve(slot.numbers.length + payload.length / 4);
        while (!pr.empty)
            slot.numbers ~= fromFixed32(kind, pr.readFixed32());
        break;
    default: // fixed64
        if (payload.length % 8)
            throw new WireException("packed fixed64 length not a multiple of 8");
        slot.numbers.reserve(slot.numbers.length + payload.length / 8);
        while (!pr.empty)
            slot.numbers ~= pr.readFixed64();
        break;
    }
}

/// Converts a raw varint to the internal 64-bit representation for `kind`.
ulong fromVarint(FieldKind kind, ulong v) @safe pure nothrow @nogc
{
    with (FieldKind) final switch (kind)
    {
    case int32:
        return cast(ulong) cast(long) cast(int) v;
    case int64, uint64:
        return v;
    case uint32:
        return v & 0xffff_ffff;
    case sint32:
        return cast(ulong) cast(long) unzigzag32(cast(uint) v);
    case sint64:
        return cast(ulong) unzigzag64(v);
    case bool_:
        return v != 0;
    case fixed32, fixed64, sfixed32, sfixed64, string_, bytes_, message:
        assert(false, "not a varint kind");
    }
}

/// Converts a raw little-endian 32-bit value to the internal representation.
ulong fromFixed32(FieldKind kind, uint v) @safe pure nothrow @nogc
{
    return kind == FieldKind.sfixed32 ? cast(ulong) cast(long) cast(int) v : v;
}

@safe unittest
{
    import std.exception : assertThrown;

    auto s = Schema.parse("message P { repeated int32 r = 1; P p = 2; string s = 3; sint32 z = 4; "
            ~ "repeated fixed32 f = 5; bool b = 6; }");
    auto p = s["P"];

    // spec example: unpacked elements and merged sub-messages
    auto m = decodeMessage(p, [0x08, 0x01, 0x08, 0x02, 0x12, 0x02, 0x08, 0x03, 0x12, 0x02, 0x08, 0x04]);
    assert(m.slots[0].numbers == [1, 2]);
    assert(m.slots[1].message.slots[0].numbers == [3, 4]);

    // mixed packed and unpacked
    m = decodeMessage(p, [0x0a, 0x02, 0x01, 0x02, 0x08, 0x03]);
    assert(m.slots[0].numbers == [1, 2, 3]);

    // negative int32 from a 10-byte varint
    m = decodeMessage(p, [0x08, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01]);
    assert(cast(long) m.slots[0].numbers[0] == -1);

    // zigzag
    m = decodeMessage(p, [0x20, 0x09]);
    assert(cast(long) m.slots[3].scalar == -5);

    // wrong wire type is skipped, group is skipped
    m = decodeMessage(p, [0x1b, 0x08, 0x01, 0x1c, 0x08, 0x05]);
    assert(!m.slots[2].present && m.slots[0].numbers == [5]);
    m = decodeMessage(p, [0x31, 1, 2, 3, 4, 5, 6, 7, 8]); // field 6, fixed64 for a bool
    assert(!m.slots[5].present);

    // errors
    assertThrown!WireException(decodeMessage(p, [0x08, 0xff]));
    assertThrown!WireException(decodeMessage(p, [0x1b, 0x14]));       // end group mismatch
    assertThrown!WireException(decodeMessage(p, [0x1a, 0x01, 0xff])); // bad UTF-8
    assertThrown!WireException(decodeMessage(p, [0x2a, 0x03, 0, 0, 0])); // packed fixed32 length
    assertThrown!WireException(decodeMessage(p, [0x0a, 0x01, 0x80])); // packed varint cut short
    assertThrown!WireException(decodeMessage(p, [0x0c]));             // stray end group
}
