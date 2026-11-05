/// Git's binary delta format (as stored in `OFS_DELTA` / `REF_DELTA` pack objects).
module gitrepo.delta;

import gitrepo.errors;

/// Apply `delta` to `base` and return the reconstructed bytes.
/// Throws `GitError` for a malformed delta, a copy outside the base or a size mismatch.
/// The declared base size is skipped, not checked.
ubyte[] applyDelta(scope const(ubyte)[] base, scope const(ubyte)[] delta) @safe
{
    size_t p = 0;
    static ulong readSize(scope const(ubyte)[] d, ref size_t p) @safe
    {
        ulong v = 0;
        uint shift = 0;
        for (;;)
        {
            if (p >= d.length || shift > 56)
                throw new GitError("bad delta header");
            immutable b = d[p++];
            v |= cast(ulong)(b & 0x7f) << shift;
            shift += 7;
            if (!(b & 0x80))
                return v;
        }
    }

    readSize(delta, p);
    immutable ulong resultSize = readSize(delta, p);
    if (resultSize > (1UL << 31))
        throw new GitError("delta result too large");
    auto result = new ubyte[cast(size_t) resultSize];
    size_t outLen = 0;
    while (p < delta.length)
    {
        immutable op = delta[p++];
        if (op & 0x80)
        {
            size_t offset = 0, size = 0;
            foreach (i; 0 .. 4)
            {
                if (op & (1 << i))
                {
                    if (p >= delta.length)
                        throw new GitError("truncated delta");
                    offset |= cast(size_t) delta[p++] << (8 * i);
                }
            }
            foreach (i; 0 .. 3)
            {
                if (op & (0x10 << i))
                {
                    if (p >= delta.length)
                        throw new GitError("truncated delta");
                    size |= cast(size_t) delta[p++] << (8 * i);
                }
            }
            if (size == 0)
                size = 0x10000;
            if (offset > base.length || size > base.length - offset)
                throw new GitError("delta copy outside base");
            if (size > result.length - outLen)
                throw new GitError("delta output overflow");
            result[outLen .. outLen + size] = base[offset .. offset + size];
            outLen += size;
        }
        else if (op != 0)
        {
            if (op > delta.length - p)
                throw new GitError("truncated delta insert");
            if (op > result.length - outLen)
                throw new GitError("delta output overflow");
            result[outLen .. outLen + op] = delta[p .. p + op];
            outLen += op;
            p += op;
        }
        else
            throw new GitError("invalid delta opcode");
    }
    if (outLen != result.length)
        throw new GitError("delta result size mismatch");
    return result;
}
