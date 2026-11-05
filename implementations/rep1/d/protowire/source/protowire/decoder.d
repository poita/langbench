/**
 * Wire-format decoder: bytes to a value tree.
 */
module protowire.decoder;

import protowire.memory;
import protowire.schema;
import protowire.utf8 : isValidUtf8;
import protowire.value;
import protowire.wire;

/// Deepest message or group nesting the decoder accepts.
enum maxNesting = 100;

/// Convert a decoded varint to the canonical 64-bit form for `k`.
ulong varintToCanonical(Kind k, ulong v) pure nothrow @nogc @safe
{
    final switch (k)
    {
    case Kind.int32:
        return cast(ulong) cast(long) cast(int) v;
    case Kind.int64, Kind.uint64:
        return v;
    case Kind.uint32:
        return v & 0xffff_ffffUL;
    case Kind.sint32:
        return cast(ulong) cast(long) unzigzag32(cast(uint) v);
    case Kind.sint64:
        return cast(ulong) unzigzag64(v);
    case Kind.boolean:
        return v != 0;
    case Kind.fixed32, Kind.sfixed32, Kind.fixed64, Kind.sfixed64,
            Kind.text, Kind.bytes, Kind.message:
        assert(0);
    }
}

/**
 * Decodes one wire-format message into a value tree allocated in an arena.
 *
 * Methods return false on malformed input and leave a description in
 * `error`; the partially built tree must then be discarded.
 */
struct Decoder
{
    const(ubyte)[] buf;
    const(Message)[] messages;
    Arena* arena;
    string error;

    /// Decode `buf[pos .. end]` as message `msgIndex` into `node`.
    bool decodeMessage(size_t msgIndex, Node* node, size_t pos, size_t end, uint depth) nothrow @trusted
    {
        if (depth > maxNesting)
            return fail("nesting too deep");
        const msg = &messages[msgIndex];
        while (pos < end)
        {
            uint num, wt;
            if (!readTag(pos, end, num, wt))
                return false;
            if (wt == WireType.endGroup)
                return fail("unexpected end-group tag");
            const slotIdx = msg.findNumber(num);
            if (slotIdx >= 0)
            {
                const f = &msg.fields[slotIdx];
                Slot* sl = &node.slots[slotIdx];
                if (wt == f.wireType)
                {
                    if (!decodeValue(f, sl, pos, end, depth))
                        return false;
                    continue;
                }
                if (wt == WireType.lengthDelimited && f.repeated && isNumeric(f.kind))
                {
                    if (!decodePacked(f, sl, pos, end))
                        return false;
                    continue;
                }
            }
            if (!skipField(num, wt, pos, end, depth))
                return false;
        }
        return true;
    }

private:
    bool fail(string why) nothrow @nogc @safe
    {
        error = why;
        return false;
    }

    bool readTag(ref size_t pos, size_t end, out uint num, out uint wt) nothrow @nogc @trusted
    {
        ulong t;
        if (!readVarint(buf.ptr, pos, end, maxTagBytes, t))
            return fail("bad tag");
        if (t >> 32)
            return fail("tag too large");
        num = cast(uint)(t >> 3);
        wt = cast(uint)(t & 7);
        if (num == 0)
            return fail("field number 0");
        if (wt > 5)
            return fail("bad wire type");
        return true;
    }

    bool readLength(ref size_t pos, size_t end, out size_t len) nothrow @nogc @trusted
    {
        ulong l;
        if (!readVarint(buf.ptr, pos, end, maxTagBytes, l))
            return fail("bad length prefix");
        if (l > end - pos)
            return fail("length exceeds remaining bytes");
        len = cast(size_t) l;
        return true;
    }

    bool skipField(uint num, uint wt, ref size_t pos, size_t end, uint depth) nothrow @trusted
    {
        switch (wt)
        {
        case WireType.varint:
            ulong ignored;
            if (!readVarint(buf.ptr, pos, end, maxVarintBytes, ignored))
                return fail("bad varint");
            return true;
        case WireType.fixed64:
            if (end - pos < 8)
                return fail("truncated fixed64");
            pos += 8;
            return true;
        case WireType.lengthDelimited:
            size_t len;
            if (!readLength(pos, end, len))
                return false;
            pos += len;
            return true;
        case WireType.startGroup:
            return skipGroup(num, pos, end, depth + 1);
        case WireType.fixed32:
            if (end - pos < 4)
                return fail("truncated fixed32");
            pos += 4;
            return true;
        default:
            return fail("bad wire type");
        }
    }

    bool skipGroup(uint startNum, ref size_t pos, size_t end, uint depth) nothrow @trusted
    {
        if (depth > maxNesting)
            return fail("nesting too deep");
        while (pos < end)
        {
            uint num, wt;
            if (!readTag(pos, end, num, wt))
                return false;
            if (wt == WireType.endGroup)
                return num == startNum ? true : fail("mismatched end-group tag");
            if (!skipField(num, wt, pos, end, depth))
                return false;
        }
        return fail("unterminated group");
    }

    static void storeNumber(ref Arena arena, const(Field)* f, Slot* sl, ulong v) nothrow @trusted
    {
        if (f.repeated)
        {
            if (sl.kind == SlotKind.absent)
            {
                sl.numList = arena.make!(Vec!ulong)();
                sl.kind = SlotKind.numList;
            }
            sl.numList.push(arena, v);
        }
        else
        {
            sl.kind = SlotKind.number;
            sl.num = v;
        }
    }

    bool decodeValue(const(Field)* f, Slot* sl, ref size_t pos, size_t end, uint depth) nothrow @trusted
    {
        final switch (f.kind)
        {
        case Kind.int32, Kind.int64, Kind.uint32, Kind.uint64, Kind.sint32,
                Kind.sint64, Kind.boolean:
            ulong v;
            if (!readVarint(buf.ptr, pos, end, maxVarintBytes, v))
                return fail("bad varint");
            storeNumber(*arena, f, sl, varintToCanonical(f.kind, v));
            return true;
        case Kind.fixed32, Kind.sfixed32:
            if (end - pos < 4)
                return fail("truncated fixed32");
            storeNumber(*arena, f, sl, loadFixed32(f.kind, buf.ptr + pos));
            pos += 4;
            return true;
        case Kind.fixed64, Kind.sfixed64:
            if (end - pos < 8)
                return fail("truncated fixed64");
            storeNumber(*arena, f, sl, loadFixed64(buf.ptr + pos));
            pos += 8;
            return true;
        case Kind.text, Kind.bytes:
            size_t len;
            if (!readLength(pos, end, len))
                return false;
            const view = buf[pos .. pos + len];
            if (f.kind == Kind.text && !isValidUtf8(view))
                return fail("invalid UTF-8 in string");
            pos += len;
            if (f.repeated)
            {
                if (sl.kind == SlotKind.absent)
                {
                    sl.bytesList = arena.make!(Vec!ByteView)();
                    sl.kind = SlotKind.bytesList;
                }
                sl.bytesList.push(*arena, view);
            }
            else
            {
                sl.kind = SlotKind.bytes;
                sl.view = view;
            }
            return true;
        case Kind.message:
            size_t len;
            if (!readLength(pos, end, len))
                return false;
            const sub = &messages[f.message];
            Node* child;
            if (f.repeated)
            {
                if (sl.kind == SlotKind.absent)
                {
                    sl.childList = arena.make!(Vec!(Node*))();
                    sl.kind = SlotKind.childList;
                }
                child = newNode(*arena, sub.fields.length);
                sl.childList.push(*arena, child);
            }
            else if (sl.kind == SlotKind.child)
                child = sl.node; // merge into the existing sub-message
            else
            {
                child = newNode(*arena, sub.fields.length);
                sl.kind = SlotKind.child;
                sl.node = child;
            }
            if (!decodeMessage(f.message, child, pos, pos + len, depth + 1))
                return false;
            pos += len;
            return true;
        }
    }

    bool decodePacked(const(Field)* f, Slot* sl, ref size_t pos, size_t end) nothrow @trusted
    {
        size_t len;
        if (!readLength(pos, end, len))
            return false;
        const subEnd = pos + len;
        if (sl.kind == SlotKind.absent)
        {
            sl.numList = arena.make!(Vec!ulong)();
            sl.kind = SlotKind.numList;
        }
        auto list = sl.numList;
        switch (f.wireType)
        {
        case WireType.varint:
            while (pos < subEnd)
            {
                ulong v;
                if (!readVarint(buf.ptr, pos, subEnd, maxVarintBytes, v))
                    return fail("bad varint in packed field");
                list.push(*arena, varintToCanonical(f.kind, v));
            }
            return true;
        case WireType.fixed32:
            if (len % 4 != 0)
                return fail("packed fixed32 length not a multiple of 4");
            list.reserve(*arena, len / 4);
            for (; pos < subEnd; pos += 4)
                list.push(*arena, loadFixed32(f.kind, buf.ptr + pos));
            return true;
        default:
            if (len % 8 != 0)
                return fail("packed fixed64 length not a multiple of 8");
            list.reserve(*arena, len / 8);
            for (; pos < subEnd; pos += 8)
                list.push(*arena, loadFixed64(buf.ptr + pos));
            return true;
        }
    }
}

private ulong loadFixed32(Kind k, const(ubyte)* p) pure nothrow @nogc @system
{
    const uint v = p[0] | (p[1] << 8) | (p[2] << 16) | (cast(uint) p[3] << 24);
    return k == Kind.sfixed32 ? cast(ulong) cast(long) cast(int) v : v;
}

private ulong loadFixed64(const(ubyte)* p) pure nothrow @nogc @system
{
    ulong v = 0;
    foreach (i; 0 .. 8)
        v |= cast(ulong) p[i] << (8 * i);
    return v;
}
