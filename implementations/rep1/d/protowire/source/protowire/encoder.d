/**
 * Wire-format encoder: value tree to bytes, in two passes. The size pass
 * computes (and caches in each node) the encoded size bottom-up; the write
 * pass then emits every byte exactly once, length prefixes included.
 */
module protowire.encoder;

import core.stdc.string : memcpy;

import protowire.memory;
import protowire.schema;
import protowire.value;
import protowire.wire;

/// Wire-form varint value of a canonical number of kind `k`.
private ulong varintValue(Kind k, ulong v) pure nothrow @nogc @safe
{
    switch (k)
    {
    case Kind.sint32:
        return zigzag32(cast(int) v);
    case Kind.sint64:
        return zigzag64(cast(long) v);
    default:
        return v;
    }
}

private size_t scalarSize(Kind k, ulong v) pure nothrow @nogc @safe
{
    switch (k)
    {
    case Kind.fixed32, Kind.sfixed32:
        return 4;
    case Kind.fixed64, Kind.sfixed64:
        return 8;
    default:
        return varintLength(varintValue(k, v));
    }
}

private ubyte* putScalar(ubyte* p, Kind k, ulong v) pure nothrow @nogc @system
{
    switch (k)
    {
    case Kind.fixed32, Kind.sfixed32:
        foreach (i; 0 .. 4)
            *p++ = cast(ubyte)(v >> (8 * i));
        return p;
    case Kind.fixed64, Kind.sfixed64:
        foreach (i; 0 .. 8)
            *p++ = cast(ubyte)(v >> (8 * i));
        return p;
    default:
        return putVarint(p, varintValue(k, v));
    }
}

/// Compute (and cache in `node.size`) the encoded size of `node`.
ulong computeSize(const(Message)[] messages, size_t msgIndex, Node* node) nothrow @trusted
{
    const msg = &messages[msgIndex];
    ulong total = 0;
    foreach (i, ref f; msg.fields)
    {
        auto sl = &node.slots[i];
        final switch (sl.kind)
        {
        case SlotKind.absent:
            break;
        case SlotKind.number:
            if (sl.num != 0)
                total += f.tagLen + scalarSize(f.kind, sl.num);
            break;
        case SlotKind.bytes:
            const n = sl.view.length;
            if (n != 0)
                total += f.tagLen + varintLength(n) + n;
            break;
        case SlotKind.child:
            const n = computeSize(messages, f.message, sl.node);
            total += f.tagLen + varintLength(n) + n;
            break;
        case SlotKind.numList:
            auto list = sl.numList;
            if (list.len == 0)
                break;
            ulong payload = 0;
            switch (f.kind)
            {
            case Kind.fixed32, Kind.sfixed32:
                payload = list.len * 4;
                break;
            case Kind.fixed64, Kind.sfixed64:
                payload = list.len * 8;
                break;
            default:
                foreach (v; list.items)
                    payload += varintLength(varintValue(f.kind, v));
            }
            list.payload = payload;
            total += f.packedTagLen + varintLength(payload) + payload;
            break;
        case SlotKind.bytesList:
            foreach (v; sl.bytesList.items)
                total += f.tagLen + varintLength(v.length) + v.length;
            break;
        case SlotKind.childList:
            foreach (c; sl.childList.items)
            {
                const n = computeSize(messages, f.message, c);
                total += f.tagLen + varintLength(n) + n;
            }
            break;
        }
    }
    node.size = total;
    return total;
}

private ubyte* writeNode(const(Message)[] messages, size_t msgIndex, const(Node)* node,
        ubyte* p) nothrow @trusted
{
    const msg = &messages[msgIndex];
    foreach (i, ref f; msg.fields)
    {
        const sl = &node.slots[i];
        final switch (sl.kind)
        {
        case SlotKind.absent:
            break;
        case SlotKind.number:
            if (sl.num != 0)
            {
                p = putVarint(p, f.tag);
                p = putScalar(p, f.kind, sl.num);
            }
            break;
        case SlotKind.bytes:
            if (sl.view.length != 0)
            {
                p = putVarint(p, f.tag);
                p = putVarint(p, sl.view.length);
                memcpy(p, sl.view.ptr, sl.view.length);
                p += sl.view.length;
            }
            break;
        case SlotKind.child:
            p = putVarint(p, f.tag);
            p = putVarint(p, sl.node.size);
            p = writeNode(messages, f.message, sl.node, p);
            break;
        case SlotKind.numList:
            auto list = sl.numList;
            if (list.len == 0)
                break;
            p = putVarint(p, f.packedTag);
            p = putVarint(p, list.payload);
            foreach (v; list.items)
                p = putScalar(p, f.kind, v);
            break;
        case SlotKind.bytesList:
            foreach (v; sl.bytesList.items)
            {
                p = putVarint(p, f.tag);
                p = putVarint(p, v.length);
                if (v.length)
                    memcpy(p, v.ptr, v.length);
                p += v.length;
            }
            break;
        case SlotKind.childList:
            foreach (c; sl.childList.items)
            {
                p = putVarint(p, f.tag);
                p = putVarint(p, c.size);
                p = writeNode(messages, f.message, c, p);
            }
            break;
        }
    }
    return p;
}

/// Append the canonical wire encoding of `root` to `output`.
void encodeNode(const(Message)[] messages, size_t msgIndex, Node* root,
        ref ByteBuffer output) nothrow @trusted
{
    const total = computeSize(messages, msgIndex, root);
    output.reserve(total);
    ubyte* start = output.tail;
    ubyte* end = writeNode(messages, msgIndex, root, start);
    assert(end - start == total);
    output.advance(total);
}
