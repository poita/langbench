/// Pack index (version 2) lookup and pack object headers.
module gitrepo.pack;

import gitrepo.errors;
import gitrepo.oid;

/// The kind of a git object.
enum ObjectType : ubyte
{
    commit = 1,
    tree = 2,
    blob = 3,
    tag = 4,
}

/// Name of an object type as it appears in the stored form (`blob`, `tree`, ...).
string typeName(ObjectType t) @safe pure nothrow @nogc
{
    final switch (t)
    {
    case ObjectType.commit: return "commit";
    case ObjectType.tree: return "tree";
    case ObjectType.blob: return "blob";
    case ObjectType.tag: return "tag";
    }
}

/// An index file plus its packfile, both held in memory.
final class Pack
{
    /// Base name (without extension) of the pack in `objects/pack`.
    string name;
    /// The whole `.idx` file.
    immutable(ubyte)[] idx;
    /// The whole `.pack` file.
    immutable(ubyte)[] data;
    /// Number of objects according to the index (`fanout[255]`).
    uint count;

    /// Validates both files; throws `GitError` if either is not a version 2 file.
    this(string name, immutable(ubyte)[] idx, immutable(ubyte)[] data) @safe
    {
        this.name = name;
        this.idx = idx;
        this.data = data;
        if (idx.length < 1032 + 40 || idx[0 .. 4] != cast(immutable(ubyte)[]) "\xfftOc" || be32(idx, 4) != 2)
            throw new GitError("bad pack index");
        count = be32(idx, 8 + 255 * 4);
        uint prev = 0;
        foreach (i; 0 .. 256)
        {
            immutable f = be32(idx, 8 + 4 * i);
            if (f < prev)
                throw new GitError("bad pack index fanout");
            prev = f;
        }
        if (idx.length < 1032 + 28 * cast(ulong) count + 40)
            throw new GitError("truncated pack index");
        if (data.length < 12 + 20 || data[0 .. 4] != cast(immutable(ubyte)[]) "PACK" || be32(data, 4) != 2)
            throw new GitError("bad packfile");
    }

    /// Id of the `i`-th object in index order (ascending).
    ObjectId idAt(size_t i) const @safe pure nothrow @nogc
    {
        ObjectId id;
        id.bytes[] = idx[1032 + 20 * i .. 1032 + 20 * i + 20];
        return id;
    }

    /// Looks `id` up in the index. Returns the object's offset in the pack or -1.
    long find(ref const ObjectId id) const @safe pure nothrow @nogc
    {
        immutable first = id.bytes[0];
        size_t lo = first == 0 ? 0 : be32(idx, 8 + 4 * (first - 1));
        size_t hi = be32(idx, 8 + 4 * first);
        while (lo < hi)
        {
            immutable mid = lo + (hi - lo) / 2;
            immutable c = cmpAt(mid, id);
            if (c == 0)
                return offsetAt(mid);
            if (c < 0)
                lo = mid + 1;
            else
                hi = mid;
        }
        return -1;
    }

    /// Index position of the first id that is >= `id`.
    size_t lowerBound(ref const ObjectId id) const @safe pure nothrow @nogc
    {
        size_t lo = 0, hi = count;
        while (lo < hi)
        {
            immutable mid = lo + (hi - lo) / 2;
            if (cmpAt(mid, id) < 0)
                lo = mid + 1;
            else
                hi = mid;
        }
        return lo;
    }

    private int cmpAt(size_t i, ref const ObjectId id) const @safe pure nothrow @nogc
    {
        immutable base = 1032 + 20 * i;
        foreach (k; 0 .. 20)
        {
            if (idx[base + k] != id.bytes[k])
                return idx[base + k] < id.bytes[k] ? -1 : 1;
        }
        return 0;
    }

    /// Pack offset of the `i`-th object in index order, or -1 if the table is damaged.
    long offsetAt(size_t i) const @safe pure nothrow @nogc
    {
        immutable off = be32(idx, 1032 + 24 * cast(size_t) count + 4 * i);
        if (!(off & 0x80000000))
            return off;
        immutable j = off & 0x7fffffff;
        immutable p = 1032 + 28 * cast(size_t) count + 8 * cast(size_t) j;
        if (p + 8 > idx.length - 40)
            return -1;
        immutable hi = be32(idx, p), lo = be32(idx, p + 4);
        immutable v = (cast(ulong) hi << 32) | lo;
        return v > long.max ? -1 : cast(long) v;
    }
}

/// Reads a big-endian 32-bit integer at `p`.
uint be32(scope const(ubyte)[] a, size_t p) @safe pure nothrow @nogc
{
    return (cast(uint) a[p] << 24) | (cast(uint) a[p + 1] << 16) | (cast(uint) a[p + 2] << 8) | a[p + 3];
}
