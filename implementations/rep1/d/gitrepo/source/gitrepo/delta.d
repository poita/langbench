/// Git's binary delta format (as used by `OFS_DELTA` and `REF_DELTA`).
module gitrepo.delta;

import gitrepo.errors;

/// Apply `delta` to `base` and return the reconstructed object payload.
///
/// A delta starts with two varints (base size, result size) followed by copy
/// and insert instructions. The result is damaged — and `GitError` is thrown —
/// when an instruction is invalid (including the reserved byte 0), a copy runs
/// past the end of `base`, an insert runs past the end of `delta`, or the
/// result length differs from the declared result size.
ubyte[] applyDelta(scope const(ubyte)[] base, scope const(ubyte)[] delta) @safe pure
{
    size_t pos;

    ulong varint()
    {
        ulong v;
        uint shift;
        while (true)
        {
            if (pos >= delta.length || shift > 63)
                throw new GitError("truncated delta header");
            immutable b = delta[pos++];
            v |= cast(ulong)(b & 0x7f) << shift;
            shift += 7;
            if (!(b & 0x80))
                return v;
        }
    }

    varint(); // declared base size: not enforced, see SPEC.md
    immutable resultSize = varint();
    if (resultSize > (1UL << 31))
        throw new GitError("delta result too large");
    auto result = new ubyte[](cast(size_t) resultSize);
    size_t outPos;

    while (pos < delta.length)
    {
        immutable op = delta[pos++];
        if (op & 0x80)
        {
            ulong off, size;
            foreach (i; 0 .. 4)
                if (op & (1 << i))
                {
                    if (pos >= delta.length)
                        throw new GitError("truncated delta copy");
                    off |= cast(ulong) delta[pos++] << (8 * i);
                }
            foreach (i; 0 .. 3)
                if (op & (0x10 << i))
                {
                    if (pos >= delta.length)
                        throw new GitError("truncated delta copy");
                    size |= cast(ulong) delta[pos++] << (8 * i);
                }
            if (size == 0)
                size = 0x10000;
            if (off > base.length || size > base.length - off)
                throw new GitError("delta copy outside base");
            if (size > result.length - outPos)
                throw new GitError("delta result overflows declared size");
            result[outPos .. outPos + size] = base[cast(size_t) off .. cast(size_t)(off + size)];
            outPos += size;
        }
        else if (op != 0)
        {
            if (op > delta.length - pos)
                throw new GitError("truncated delta insert");
            if (op > result.length - outPos)
                throw new GitError("delta result overflows declared size");
            result[outPos .. outPos + op] = delta[pos .. pos + op];
            outPos += op;
            pos += op;
        }
        else
            throw new GitError("invalid delta instruction 0");
    }
    if (outPos != result.length)
        throw new GitError("delta result size mismatch");
    return result;
}

unittest
{
    import std.exception : assertThrown;

    const base = cast(const(ubyte)[]) "hello world";
    // base size 11, result size 11 ("hello there"): copy 6 bytes @0, insert "there".
    ubyte[] d = [11, 11, 0x90, 6, 5, 't', 'h', 'e', 'r', 'e'];
    assert(cast(string) applyDelta(base, d) == "hello there");
    // A copy of size 0 means 0x10000 bytes, which does not fit in the base.
    assertThrown!GitError(applyDelta(base, [11, 0, 0x80]));
    // Instruction 0 is invalid.
    assertThrown!GitError(applyDelta(base, [11, 0, 0]));
    // Copy past end of base.
    assertThrown!GitError(applyDelta(base, [11, 5, 0x91, 8, 5]));
    // Result size mismatch.
    assertThrown!GitError(applyDelta(base, [11, 6, 0x90, 5]));
    // Offset bytes: copy 5 bytes from offset 6.
    assert(cast(string) applyDelta(base, [11, 5, 0x91, 6, 5]) == "world");
}
