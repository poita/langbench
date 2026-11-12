/// Test support: build small git repositories on disk, with loose objects,
/// packs (including delta objects) and refs, using only this project's own code.
module fixture;

import std.conv : to;
import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
import std.path : buildPath;

import gitrepo.hex : toHex;
import gitrepo.objectid;
import gitrepo.sha1;

/// A temporary directory removed when the fixture is destroyed.
struct TempRepo
{
    string root;
    string repo;

    static TempRepo create(string name)
    {
        TempRepo t;
        t.root = buildPath(tempDir(), "gitrepo-test-" ~ name);
        t.repo = buildPath(t.root, "repo");
        try
            rmdirRecurse(t.root);
        catch (Exception)
        {
        }
        mkdirRecurse(buildPath(t.repo, "objects", "pack"));
        mkdirRecurse(buildPath(t.repo, "refs", "heads"));
        mkdirRecurse(buildPath(t.repo, "refs", "tags"));
        return t;
    }

    void remove()
    {
        rmdirRecurse(root);
    }

    void writeRef(string name, string content)
    {
        import std.file : mkdirRecurse;
        import std.path : dirName;

        immutable path = buildPath(repo, name);
        mkdirRecurse(dirName(path));
        write(path, content);
    }

    /// Write `payload` as a loose object and return its id.
    ObjectId loose(string type, const(ubyte)[] payload)
    {
        immutable id = objectId(type, payload);
        immutable hex = id.toString();
        mkdirRecurse(buildPath(repo, "objects", hex[0 .. 2]));
        write(buildPath(repo, "objects", hex[0 .. 2], hex[2 .. $]), zlibStored(storedForm(type, payload)));
        return id;
    }
}

const(ubyte)[] bytes(string s)
{
    return cast(const(ubyte)[]) s;
}

ubyte[] storedForm(string type, const(ubyte)[] payload)
{
    return cast(ubyte[])(type ~ " " ~ payload.length.to!string ~ "\0") ~ payload;
}

ObjectId objectId(string type, const(ubyte)[] payload)
{
    return ObjectId.fromBytes(sha1Of(storedForm(type, payload)));
}

uint adler32(const(ubyte)[] data)
{
    uint a = 1, b = 0;
    foreach (c; data)
    {
        a = (a + c) % 65521;
        b = (b + a) % 65521;
    }
    return (b << 16) | a;
}

/// A valid zlib stream that uses stored (uncompressed) blocks only.
ubyte[] zlibStored(const(ubyte)[] data)
{
    ubyte[] r = [0x78, 0x01];
    size_t pos;
    do
    {
        immutable n = data.length - pos > 65535 ? 65535 : data.length - pos;
        immutable last = pos + n == data.length;
        r ~= [cast(ubyte)(last ? 1 : 0), cast(ubyte) n, cast(ubyte)(n >> 8), cast(ubyte)~n, cast(ubyte)(~n >> 8)];
        r ~= data[pos .. pos + n];
        pos += n;
    }
    while (pos < data.length);
    immutable ad = adler32(data);
    r ~= [cast(ubyte)(ad >> 24), cast(ubyte)(ad >> 16), cast(ubyte)(ad >> 8), cast(ubyte) ad];
    return r;
}

/// A tree payload from (mode, name, id) triples.
ubyte[] treePayload(const(Entry)[] entries)
{
    ubyte[] r;
    foreach (e; entries)
    {
        r ~= cast(const(ubyte)[])(e.mode ~ " " ~ e.name ~ "\0");
        r ~= e.id.bytes[];
    }
    return r;
}

struct Entry
{
    string mode;
    string name;
    ObjectId id;
}

/// A delta that copies all of `base` and appends `suffix` (at most 127 bytes).
ubyte[] appendDelta(const(ubyte)[] base, const(ubyte)[] suffix)
{
    assert(suffix.length > 0 && suffix.length < 128 && base.length < 128);
    ubyte[] d = [cast(ubyte) base.length, cast(ubyte)(base.length + suffix.length), 0x90,
        cast(ubyte) base.length, cast(ubyte) suffix.length];
    return d ~ suffix;
}

/// Builds a version-2 pack and its index.
struct PackBuilder
{
    ubyte[] data = [cast(ubyte) 'P', 'A', 'C', 'K', 0, 0, 0, 2, 0, 0, 0, 0];
    struct Item
    {
        ObjectId id;
        size_t offset;
    }

    Item[] items;

    private static ubyte[] header(uint type, size_t size)
    {
        ubyte first = cast(ubyte)((type << 4) | (size & 15));
        size >>= 4;
        ubyte[] h;
        if (size)
            first |= 0x80;
        h ~= first;
        while (size)
        {
            ubyte b = size & 0x7f;
            size >>= 7;
            if (size)
                b |= 0x80;
            h ~= b;
        }
        return h;
    }

    /// Add a plain object; returns its offset.
    size_t add(uint type, string typeName, const(ubyte)[] payload)
    {
        immutable off = data.length;
        data ~= header(type, payload.length);
        data ~= zlibStored(payload);
        items ~= Item(objectId(typeName, payload), off);
        return off;
    }

    /// Add an OFS_DELTA against the object at `baseOffset`; `resultId` is the
    /// id of the reconstructed object.
    size_t addOfsDelta(size_t baseOffset, const(ubyte)[] delta, ObjectId resultId)
    {
        immutable off = data.length;
        data ~= header(6, delta.length);
        size_t rel = off - baseOffset;
        ubyte[] enc = [cast(ubyte)(rel & 0x7f)];
        rel >>= 7;
        while (rel)
        {
            --rel;
            enc = cast(ubyte)(0x80 | (rel & 0x7f)) ~ enc;
            rel >>= 7;
        }
        data ~= enc;
        data ~= zlibStored(delta);
        items ~= Item(resultId, off);
        return off;
    }

    /// Add a REF_DELTA against `baseId`.
    size_t addRefDelta(ObjectId baseId, const(ubyte)[] delta, ObjectId resultId)
    {
        immutable off = data.length;
        data ~= header(7, delta.length);
        data ~= baseId.bytes[];
        data ~= zlibStored(delta);
        items ~= Item(resultId, off);
        return off;
    }

    /// Write `<name>.pack` and `<name>.idx` into the repository.
    void finish(string repo, string name)
    {
        auto d = data.dup;
        immutable n = items.length;
        d[8 .. 12] = [cast(ubyte)(n >> 24), cast(ubyte)(n >> 16), cast(ubyte)(n >> 8), cast(ubyte) n];
        d ~= sha1Of(d)[];
        auto sorted = items.dup;
        import std.algorithm : sort;

        sorted.sort!((a, b) => a.id < b.id);
        ubyte[] idx = [0xff, 't', 'O', 'c', 0, 0, 0, 2];
        foreach (b; 0 .. 256)
        {
            uint c;
            foreach (it; sorted)
                if (it.id.bytes[0] <= b)
                    ++c;
            idx ~= [cast(ubyte)(c >> 24), cast(ubyte)(c >> 16), cast(ubyte)(c >> 8), cast(ubyte) c];
        }
        foreach (it; sorted)
            idx ~= it.id.bytes[];
        idx ~= new ubyte[](4 * n); // CRCs are not checked
        foreach (it; sorted)
            idx ~= [cast(ubyte)(it.offset >> 24), cast(ubyte)(it.offset >> 16), cast(ubyte)(it.offset >> 8),
                cast(ubyte) it.offset];
        idx ~= d[$ - 20 .. $];
        idx ~= sha1Of(idx)[];
        write(buildPath(repo, "objects", "pack", name ~ ".pack"), d);
        write(buildPath(repo, "objects", "pack", name ~ ".idx"), idx);
    }
}
