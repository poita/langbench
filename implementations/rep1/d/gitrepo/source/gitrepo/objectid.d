/// Object identifiers.
module gitrepo.objectid;

import gitrepo.errors;
import gitrepo.hex;

/// A 20-byte SHA-1 object id. Usable as an associative-array key.
struct ObjectId
{
    /// The raw digest bytes.
    ubyte[20] bytes;

    /// The all-zero id.
    static ObjectId zero() @safe pure nothrow @nogc
    {
        return ObjectId.init;
    }

    /// Wrap 20 raw bytes.
    static ObjectId fromBytes(scope const(ubyte)[] raw) @safe pure
    {
        if (raw.length != 20)
            throw new GitError("object id must be 20 bytes");
        ObjectId id;
        id.bytes[] = raw[];
        return id;
    }

    /// Parse exactly 40 hexadecimal digits (either case). Returns false if `s`
    /// is not one.
    static bool tryParse(scope const(char)[] s, out ObjectId id) @safe pure nothrow @nogc
    {
        if (s.length != 40)
            return false;
        foreach (i; 0 .. 20)
        {
            immutable hi = hexValue(s[2 * i]);
            immutable lo = hexValue(s[2 * i + 1]);
            if (hi < 0 || lo < 0)
                return false;
            id.bytes[i] = cast(ubyte)(hi * 16 + lo);
        }
        return true;
    }

    /// Parse 40 hex digits or throw `GitError`.
    static ObjectId parse(scope const(char)[] s) @safe pure
    {
        ObjectId id;
        if (!tryParse(s, id))
            throw new GitError("not an object id");
        return id;
    }

    /// 40 lowercase hex digits.
    string toString() const @safe pure nothrow
    {
        return toHex(bytes[]);
    }

    /// Lexicographic comparison of the raw bytes.
    int opCmp(const ObjectId o) const @safe pure nothrow @nogc
    {
        foreach (i; 0 .. 20)
            if (bytes[i] != o.bytes[i])
                return bytes[i] < o.bytes[i] ? -1 : 1;
        return 0;
    }
}

unittest
{
    auto id = ObjectId.parse("B7814CAE2E925FE74C6CD5816462FFF515CCB256");
    assert(id.toString == "b7814cae2e925fe74c6cd5816462fff515ccb256");
    ObjectId other;
    assert(!ObjectId.tryParse("abc", other));
    assert(!ObjectId.tryParse("zz814cae2e925fe74c6cd5816462fff515ccb256", other));
    assert(ObjectId.zero < id);
    bool[ObjectId] set;
    set[id] = true;
    assert(id in set);
}
