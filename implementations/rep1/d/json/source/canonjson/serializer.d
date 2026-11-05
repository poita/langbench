/**
 * Canonical serialization of a $(REF Value, canonjson,value) tree.
 *
 * The tree is walked once, in pre-order, appending to a single buffer.
 * Objects are deduplicated (last occurrence wins) and sorted by key in UTF-16
 * code unit order at the point where they are written.
 */
module canonjson.serializer;

import std.algorithm.sorting : sort;
import std.algorithm.mutation : SwapStrategy;

import canonjson.buffer : ByteBuffer;
import canonjson.keyorder : compareKeys;
import canonjson.scan : skipPlain;
import canonjson.value : Kind, Member, Value;

/// Appends the canonical form of `v` to `output`.
void serialize(ref const Value v, ref ByteBuffer output) @trusted
{
    // The serializer only lives for this call, so the pointer cannot escape.
    auto s = Serializer(&output);
    s.write(v);
}

/// Returns the canonical form of `v` as a fresh byte array (no trailing newline).
ubyte[] toCanonical(ref const Value v) @safe
{
    ByteBuffer buf;
    serialize(v, buf);
    return buf.data.dup;
}

/// Appends `bytes` (valid UTF-8) to `output` as a canonical JSON string literal.
void writeString(ref ByteBuffer output, const(ubyte)[] bytes) @safe
{
    output.put('"');
    size_t i = 0;
    while (i < bytes.length)
    {
        immutable j = skipPlain(bytes, i);
        output.put(bytes[i .. j]); // bulk copy of the run needing no escape
        if (j >= bytes.length)
            break;
        immutable c = bytes[j];
        switch (c)
        {
        case '"':  output.put(`\"`); break;
        case '\\': output.put(`\\`); break;
        case '\b': output.put(`\b`); break;
        case '\f': output.put(`\f`); break;
        case '\n': output.put(`\n`); break;
        case '\r': output.put(`\r`); break;
        case '\t': output.put(`\t`); break;
        default:
            output.put(`\u00`);
            output.put(hexDigits[c >> 4]);
            output.put(hexDigits[c & 15]);
        }
        i = j + 1;
    }
    output.put('"');
}

private immutable ubyte[16] hexDigits = cast(immutable(ubyte)[16]) "0123456789abcdef";

private struct Serializer
{
    ByteBuffer* out_;
    // Stack of member-index handles shared by all open objects.
    uint[] handles;
    size_t handlesTop;

    this(ByteBuffer* o) @safe
    {
        out_ = o;
    }

    void write(ref const Value v) @safe
    {
        final switch (v.kind)
        {
        case Kind.null_:   out_.put("null");  break;
        case Kind.false_:  out_.put("false"); break;
        case Kind.true_:   out_.put("true");  break;
        case Kind.number:  out_.put(v.numberText); break;
        case Kind.string:  writeString(*out_, v.stringBytes); break;
        case Kind.array:   writeArray(v.array); break;
        case Kind.object:  writeObject(v.object); break;
        }
    }

    void writeArray(const(Value)[] items) @safe
    {
        out_.put('[');
        foreach (k, ref item; items)
        {
            if (k)
                out_.put(',');
            write(item);
        }
        out_.put(']');
    }

    void writeObject(const(Member)[] members) @safe
    {
        immutable m = members.length;
        if (m == 0)
        {
            out_.put("{}");
            return;
        }
        if (m == 1)
        {
            out_.put('{');
            writeMember(members[0]);
            out_.put('}');
            return;
        }
        if (m > uint.max)
            assert(0, "object too large");

        // Sort small handles (member indices); ties broken by input index.
        immutable base = handlesTop;
        if (handles.length < base + m)
            handles.length = (base + m) * 2;
        auto h = handles[base .. base + m];
        foreach (k, ref e; h)
            e = cast(uint) k;
        h.sort!((a, b) {
            immutable c = compareKeys(members[a].key, members[b].key);
            return c < 0 || (c == 0 && a < b);
        }, SwapStrategy.unstable);

        // Equal keys are now adjacent, in input order: keep the last of each run.
        size_t kept = 0;
        foreach (k; 0 .. m)
            if (k + 1 == m || members[h[k]].key != members[h[k + 1]].key)
                h[kept++] = h[k];

        handlesTop = base + kept; // nested objects use the space above
        out_.put('{');
        foreach (k; 0 .. kept)
        {
            if (k)
                out_.put(',');
            writeMember(members[handles[base + k]]); // re-index: `handles` may have moved
        }
        out_.put('}');
        handlesTop = base;
    }

    void writeMember(ref const Member m) @safe
    {
        writeString(*out_, m.key);
        out_.put(':');
        write(m.value);
    }
}
