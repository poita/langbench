/// Secondary index keys (SPEC §14.1) and field-path text helpers.
module tessera.index;

import std.array : Appender, split;

import tessera.constants;
import tessera.value;

/// Append `vkey(v)` — the order-preserving, self-delimiting encoding of a
/// scalar. Returns `false` (appending nothing) for lists and objects, which
/// are not indexable.
bool appendVkey(const Value v, ref Appender!(ubyte[]) o) @safe pure nothrow
{
    final switch (v.kind)
    {
    case Kind.null_:
        o.put(cast(ubyte) 0x10);
        return true;
    case Kind.bool_:
        o.put(cast(ubyte)(v.num ? 0x21 : 0x20));
        return true;
    case Kind.int_:
        o.put(cast(ubyte) 0x30);
        immutable u = cast(ulong) v.num ^ 0x8000_0000_0000_0000UL;
        foreach_reverse (i; 0 .. 8)
            o.put(cast(ubyte)(u >> (8 * i)));
        return true;
    case Kind.string_:
        o.put(cast(ubyte) 0x40);
        foreach (char c; v.str)
        {
            o.put(cast(ubyte) c);
            if (c == 0)
                o.put(cast(ubyte) 0xFF);
        }
        o.put(cast(ubyte) 0);
        o.put(cast(ubyte) 0);
        return true;
    case Kind.list, Kind.object:
        return false;
    }
}

/// The index entry key `vkey(value) ‖ key` for the value at `segments` of
/// `doc`. Returns `false` when the document is not indexed: the path is
/// missing or resolves to a list or an object (SPEC §14.2).
bool entryKey(const Value doc, const(string)[] segments, const(ubyte)[] key,
        out ubyte[] entry) @safe pure nothrow
{
    auto v = resolvePath(doc, segments);
    if (v is null)
        return false;
    Appender!(ubyte[]) o;
    if (!appendVkey(*v, o))
        return false;
    o.put(key);
    entry = o[];
    return true;
}

/// Length in bytes of the `vkey` at the start of an index entry key.
size_t vkeyLength(const(ubyte)[] entry) @safe pure nothrow @nogc
{
    switch (entry[0])
    {
    case 0x30:
        return 9;
    case 0x40:
        size_t p = 1;
        while (true)
        {
            if (entry[p] == 0)
            {
                if (entry[p + 1] == 0)
                    return p + 2;
                p += 2;
            }
            else
                p++;
        }
    default:
        return 1;
    }
}

/// Split the text of a field path into its segments.
string[] pathSegments(string text) @safe pure
{
    return text.split('.');
}

@safe pure unittest
{
    ubyte[] vk(Value v)
    {
        Appender!(ubyte[]) o;
        assert(appendVkey(v, o));
        return o[];
    }

    // SPEC §14.1 worked vkeys
    assert(vk(Value.nul()) == [0x10]);
    assert(vk(Value.boolean(true)) == [0x21]);
    assert(vk(Value.integer(36)) == [0x30, 0x80, 0, 0, 0, 0, 0, 0, 0x24]);
    assert(vk(Value.integer(-1)) == [0x30, 0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]);
    assert(vk(Value.integer(long.min)) == [0x30, 0, 0, 0, 0, 0, 0, 0, 0]);
    assert(vk(Value.text("")) == [0x40, 0, 0]);
    assert(vk(Value.text("a\0b")) == [0x40, 0x61, 0, 0xff, 0x62, 0, 0]);
    Appender!(ubyte[]) o;
    assert(!appendVkey(Value.list(null), o));

    auto doc = Value.object();
    doc.insertField("age", Value.integer(36));
    ubyte[] e;
    assert(entryKey(doc, ["age"], cast(const(ubyte)[]) "u1", e));
    assert(e == [0x30, 0x80, 0, 0, 0, 0, 0, 0, 0x24, 0x75, 0x31]);
    assert(vkeyLength(e) == 9);
    assert(!entryKey(doc, ["nope"], cast(const(ubyte)[]) "u1", e));
    assert(vkeyLength([0x40, 0x61, 0, 0xff, 0x62, 0, 0, 0x75]) == 7);
    assert(pathSegments("a.b.c") == ["a", "b", "c"]);
}
