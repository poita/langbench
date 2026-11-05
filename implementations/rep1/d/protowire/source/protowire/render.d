/**
 * Rendering a value tree as canonical text.
 */
module protowire.render;

import protowire.memory;
import protowire.schema;
import protowire.value;

private immutable bool[256] needsEscape = () {
    bool[256] t;
    foreach (i; 0 .. 0x20)
        t[i] = true;
    t[0x7f] = true;
    t['"'] = true;
    t['\\'] = true;
    return t;
}();

/// Append `s` as a quoted, escaped string literal.
void renderString(ref ByteBuffer o, const(ubyte)[] s) nothrow @nogc @trusted
{
    static immutable char[16] hex = "0123456789abcdef";
    o.putByte('"');
    size_t runStart = 0;
    foreach (i; 0 .. s.length)
    {
        const c = s[i];
        if (!needsEscape[c])
            continue;
        o.putBytes(s[runStart .. i]);
        runStart = i + 1;
        switch (c)
        {
        case '"':
            o.putString("\\\"");
            break;
        case '\\':
            o.putString("\\\\");
            break;
        case '\n':
            o.putString("\\n");
            break;
        case '\r':
            o.putString("\\r");
            break;
        case '\t':
            o.putString("\\t");
            break;
        default:
            o.putString("\\x");
            o.putByte(hex[c >> 4]);
            o.putByte(hex[c & 15]);
            break;
        }
    }
    o.putBytes(s[runStart .. $]);
    o.putByte('"');
}

/// Append `x"<hex>"`.
void renderBytes(ref ByteBuffer o, const(ubyte)[] s) nothrow @nogc
{
    o.putString("x\"");
    o.putHex(s);
    o.putByte('"');
}

/// Append one numeric value of type `k` given in canonical form.
void renderNumber(ref ByteBuffer o, Kind k, ulong v) nothrow @nogc
{
    if (k == Kind.boolean)
        o.putString(v ? "true" : "false");
    else if (isSigned(k))
        o.putSigned(cast(long) v);
    else
        o.putUnsigned(v);
}

/// Append the canonical text form of message `msgIndex` held in `node`.
void renderMessage(ref ByteBuffer o, const(Message)[] messages, size_t msgIndex,
        const(Node)* node) nothrow @trusted
{
    const msg = &messages[msgIndex];
    o.putByte('{');
    bool first = true;
    foreach (i, ref f; msg.fields)
    {
        const sl = &node.slots[i];
        final switch (sl.kind)
        {
        case SlotKind.absent:
            continue;
        case SlotKind.number:
            if (sl.num == 0)
                continue;
            break;
        case SlotKind.bytes:
            if (sl.view.length == 0)
                continue;
            break;
        case SlotKind.child:
            break;
        case SlotKind.numList:
            if (sl.numList.len == 0)
                continue;
            break;
        case SlotKind.bytesList:
            if (sl.bytesList.len == 0)
                continue;
            break;
        case SlotKind.childList:
            if (sl.childList.len == 0)
                continue;
            break;
        }
        if (!first)
            o.putString(", ");
        first = false;
        o.putString(f.name);
        o.putString(": ");
        final switch (sl.kind)
        {
        case SlotKind.absent:
            break;
        case SlotKind.number:
            renderNumber(o, f.kind, sl.num);
            break;
        case SlotKind.bytes:
            if (f.kind == Kind.text)
                renderString(o, sl.view);
            else
                renderBytes(o, sl.view);
            break;
        case SlotKind.child:
            renderMessage(o, messages, f.message, sl.node);
            break;
        case SlotKind.numList:
            o.putByte('[');
            foreach (j, v; sl.numList.items)
            {
                if (j)
                    o.putString(", ");
                renderNumber(o, f.kind, v);
            }
            o.putByte(']');
            break;
        case SlotKind.bytesList:
            o.putByte('[');
            foreach (j, v; sl.bytesList.items)
            {
                if (j)
                    o.putString(", ");
                if (f.kind == Kind.text)
                    renderString(o, v);
                else
                    renderBytes(o, v);
            }
            o.putByte(']');
            break;
        case SlotKind.childList:
            o.putByte('[');
            foreach (j, c; sl.childList.items)
            {
                if (j)
                    o.putString(", ");
                renderMessage(o, messages, f.message, c);
            }
            o.putByte(']');
            break;
        }
    }
    o.putByte('}');
}
