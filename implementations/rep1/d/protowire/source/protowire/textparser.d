/**
 * Parser for the canonical text form accepted by `encode`.
 */
module protowire.textparser;

import protowire.decoder : maxNesting;
import protowire.hex : hexDigitValue;
import protowire.memory;
import protowire.schema;
import protowire.utf8 : isValidUtf8;
import protowire.value;

/**
 * Single-pass recursive-descent parser from text to a value tree. Methods
 * return false on malformed text and leave a description in `error`.
 */
struct TextParser
{
    const(ubyte)[] src;
    const(Message)[] messages;
    Arena* arena;
    string error;
    size_t pos;

    /// Parse the whole of `src` as one message of type `msgIndex` into `root`.
    bool parseDocument(size_t msgIndex, Node* root) nothrow @trusted
    {
        pos = 0;
        if (!parseMessage(msgIndex, root, 0))
            return false;
        skipSpaces();
        if (pos != src.length)
            return fail("trailing text");
        return true;
    }

private:
    bool fail(string why) nothrow @nogc @safe
    {
        error = why;
        return false;
    }

    void skipSpaces() nothrow @nogc @trusted
    {
        while (pos < src.length && src[pos] == ' ')
            pos++;
    }

    static bool isIdentChar(ubyte c) pure nothrow @nogc @safe
    {
        return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_';
    }

    bool parseMessage(size_t msgIndex, Node* node, uint depth) nothrow @trusted
    {
        if (depth > maxNesting)
            return fail("nesting too deep");
        const msg = &messages[msgIndex];
        skipSpaces();
        if (pos >= src.length || src[pos] != '{')
            return fail("'{' expected");
        pos++;
        skipSpaces();
        if (pos < src.length && src[pos] == '}')
        {
            pos++;
            return true;
        }
        while (true)
        {
            const start = pos;
            while (pos < src.length && isIdentChar(src[pos]))
                pos++;
            if (start == pos)
                return fail("field name expected");
            const idx = msg.findName(cast(const(char)[]) src[start .. pos]);
            if (idx < 0)
                return fail("unknown field");
            const bit = 1UL << idx;
            if (node.seen & bit)
                return fail("duplicate field");
            node.seen |= bit;
            skipSpaces();
            if (pos >= src.length || src[pos] != ':')
                return fail("':' expected");
            pos++;
            skipSpaces();
            if (!parseField(&msg.fields[idx], &node.slots[idx], depth))
                return false;
            skipSpaces();
            if (pos >= src.length)
                return fail("unterminated message");
            const c = src[pos++];
            if (c == ',')
            {
                skipSpaces();
                continue;
            }
            if (c == '}')
                return true;
            return fail("',' or '}' expected");
        }
    }

    bool parseField(const(Field)* f, Slot* sl, uint depth) nothrow @trusted
    {
        if (!f.repeated)
            return parseElement(f, sl, depth);
        if (pos >= src.length || src[pos] != '[')
            return fail("list expected");
        pos++;
        skipSpaces();
        if (pos < src.length && src[pos] == ']')
        {
            pos++;
            return true;
        }
        while (true)
        {
            if (!parseElement(f, sl, depth))
                return false;
            skipSpaces();
            if (pos >= src.length)
                return fail("unterminated list");
            const c = src[pos++];
            if (c == ',')
            {
                skipSpaces();
                continue;
            }
            if (c == ']')
                return true;
            return fail("',' or ']' expected");
        }
    }

    /// Parse one value and store it (appending when the field is repeated).
    bool parseElement(const(Field)* f, Slot* sl, uint depth) nothrow @trusted
    {
        final switch (f.kind)
        {
        case Kind.int32, Kind.int64, Kind.uint32, Kind.uint64, Kind.sint32,
                Kind.sint64, Kind.fixed32, Kind.fixed64, Kind.sfixed32, Kind.sfixed64:
            ulong v;
            if (!parseInteger(f.kind, v))
                return false;
            return storeNumber(f, sl, v);
        case Kind.boolean:
            const start = pos;
            while (pos < src.length && isIdentChar(src[pos]))
                pos++;
            const word = cast(const(char)[]) src[start .. pos];
            if (word == "true")
                return storeNumber(f, sl, 1);
            if (word == "false")
                return storeNumber(f, sl, 0);
            return fail("bool expected");
        case Kind.text:
            const(ubyte)[] s;
            if (!parseString(s))
                return false;
            return storeView(f, sl, s);
        case Kind.bytes:
            const(ubyte)[] s;
            if (!parseBytesLiteral(s))
                return false;
            return storeView(f, sl, s);
        case Kind.message:
            const sub = &messages[f.message];
            Node* child = newNode(*arena, sub.fields.length);
            if (!parseMessage(f.message, child, depth + 1))
                return false;
            if (f.repeated)
            {
                if (sl.kind == SlotKind.absent)
                {
                    sl.childList = arena.make!(Vec!(Node*))();
                    sl.kind = SlotKind.childList;
                }
                sl.childList.push(*arena, child);
            }
            else
            {
                sl.kind = SlotKind.child;
                sl.node = child;
            }
            return true;
        }
    }

    bool storeNumber(const(Field)* f, Slot* sl, ulong v) nothrow @trusted
    {
        if (f.repeated)
        {
            if (sl.kind == SlotKind.absent)
            {
                sl.numList = arena.make!(Vec!ulong)();
                sl.kind = SlotKind.numList;
            }
            sl.numList.push(*arena, v);
        }
        else
        {
            sl.kind = SlotKind.number;
            sl.num = v;
        }
        return true;
    }

    bool storeView(const(Field)* f, Slot* sl, const(ubyte)[] v) nothrow @trusted
    {
        if (f.repeated)
        {
            if (sl.kind == SlotKind.absent)
            {
                sl.bytesList = arena.make!(Vec!ByteView)();
                sl.kind = SlotKind.bytesList;
            }
            sl.bytesList.push(*arena, v);
        }
        else
        {
            sl.kind = SlotKind.bytes;
            sl.view = v;
        }
        return true;
    }

    /// Parse a decimal integer and range-check it for `k`.
    bool parseInteger(Kind k, out ulong result) nothrow @nogc @trusted
    {
        bool neg = false;
        if (pos < src.length && src[pos] == '-')
        {
            neg = true;
            pos++;
        }
        const start = pos;
        ulong v = 0;
        while (pos < src.length && src[pos] >= '0' && src[pos] <= '9')
        {
            const d = src[pos] - '0';
            if (v > (ulong.max - d) / 10)
                return fail("integer out of range");
            v = v * 10 + d;
            pos++;
        }
        const digits = pos - start;
        if (digits == 0)
            return fail("integer expected");
        if (digits > 1 && src[start] == '0')
            return fail("leading zero");
        if (neg && v == 0)
            return fail("-0");

        uint bits;
        final switch (k)
        {
        case Kind.int32, Kind.sint32, Kind.sfixed32:
            bits = 32;
            break;
        case Kind.int64, Kind.sint64, Kind.sfixed64:
            bits = 64;
            break;
        case Kind.uint32, Kind.fixed32:
            bits = 32;
            if (neg || v > 0xffff_ffffUL)
                return fail("integer out of range");
            result = v;
            return true;
        case Kind.uint64, Kind.fixed64:
            if (neg)
                return fail("negative unsigned");
            result = v;
            return true;
        case Kind.boolean, Kind.text, Kind.bytes, Kind.message:
            assert(0);
        }
        const limit = 1UL << (bits - 1);
        if (neg)
        {
            if (v > limit)
                return fail("integer out of range");
            result = 0UL - v;
        }
        else
        {
            if (v > limit - 1)
                return fail("integer out of range");
            result = v;
        }
        return true;
    }

    /// Parse a `"..."` literal into a UTF-8 validated byte view.
    bool parseString(out const(ubyte)[] result) nothrow @trusted
    {
        if (pos >= src.length || src[pos] != '"')
            return fail("string expected");
        const start = ++pos;
        bool escaped = false;
        while (true)
        {
            if (pos >= src.length)
                return fail("unterminated string");
            const c = src[pos];
            if (c == '"')
                break;
            if (c < 0x20)
                return fail("control character in string");
            if (c == '\\')
            {
                escaped = true;
                pos++;
                if (pos >= src.length)
                    return fail("unterminated string");
            }
            pos++;
        }
        const end = pos++;
        if (!escaped)
            result = src[start .. end];
        else
        {
            auto outBuf = arena.allocBytes(end - start);
            size_t n = 0;
            size_t i = start;
            while (i < end)
            {
                ubyte c = src[i++];
                if (c == '\\')
                {
                    c = src[i++]; // the scan guarantees a character exists
                    switch (c)
                    {
                    case '"', '\\':
                        break;
                    case 'n':
                        c = '\n';
                        break;
                    case 'r':
                        c = '\r';
                        break;
                    case 't':
                        c = '\t';
                        break;
                    case 'x':
                        if (i + 2 > end)
                            return fail("bad \\x escape");
                        const hi = hexDigitValue(lower(src[i]));
                        const lo = hexDigitValue(lower(src[i + 1]));
                        if (hi < 0 || lo < 0)
                            return fail("bad \\x escape");
                        i += 2;
                        c = cast(ubyte)(hi << 4 | lo);
                        break;
                    default:
                        return fail("unknown escape");
                    }
                }
                outBuf[n++] = c;
            }
            result = outBuf[0 .. n];
        }
        if (!isValidUtf8(result))
            return fail("invalid UTF-8 in string");
        return true;
    }

    static ubyte lower(ubyte c) pure nothrow @nogc @safe
    {
        return (c >= 'A' && c <= 'F') ? cast(ubyte)(c + 32) : c;
    }

    /// Parse an `x"<hex>"` literal.
    bool parseBytesLiteral(out const(ubyte)[] result) nothrow @trusted
    {
        if (pos + 1 >= src.length || src[pos] != 'x' || src[pos + 1] != '"')
            return fail("bytes literal expected");
        const start = pos + 2;
        size_t e = start;
        while (e < src.length && src[e] != '"')
        {
            if (hexDigitValue(src[e]) < 0)
                return fail("bad hex digit in bytes literal");
            e++;
        }
        if (e >= src.length)
            return fail("unterminated bytes literal");
        const count = e - start;
        if (count & 1)
            return fail("odd number of hex digits");
        auto outBuf = arena.allocBytes(count / 2);
        foreach (i; 0 .. count / 2)
            outBuf[i] = cast(ubyte)(hexDigitValue(src[start + 2 * i]) << 4
                    | hexDigitValue(src[start + 2 * i + 1]));
        result = outBuf;
        pos = e + 1;
        return true;
    }
}
