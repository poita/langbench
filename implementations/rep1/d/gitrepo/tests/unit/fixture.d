/// Helpers for building throw-away repositories in unit tests.
module unit.fixture;

import std.array : appender;
import std.conv : to;
import std.file;
import std.path : buildPath, dirName;

import gitrepo.oid;
import gitrepo.pack : typeName, ObjectType;
import gitrepo.sha1;

/// zlib stream made of one stored block (no compression).
ubyte[] zlibStored(const(ubyte)[] data)
{
    assert(data.length < 65536);
    ubyte[] r = [0x78, 0x01, 0x01, cast(ubyte) data.length, cast(ubyte)(data.length >> 8),
        cast(ubyte)~data.length, cast(ubyte)(~data.length >> 8)];
    r ~= data;
    uint a = 1, b = 0;
    foreach (c; data)
    {
        a = (a + c) % 65521;
        b = (b + a) % 65521;
    }
    uint ad = (b << 16) | a;
    r ~= [cast(ubyte)(ad >> 24), cast(ubyte)(ad >> 16), cast(ubyte)(ad >> 8), cast(ubyte) ad];
    return r;
}

ubyte[] storedForm(string type, const(ubyte)[] payload)
{
    return cast(ubyte[])(type ~ " " ~ payload.length.to!string ~ "\0") ~ payload.dup;
}

ObjectId idOf(string type, const(ubyte)[] payload)
{
    ObjectId id;
    id.bytes = sha1Of(storedForm(type, payload));
    return id;
}

/// A scratch repository directory.
struct Fixture
{
    string root;

    static Fixture create(string name)
    {
        auto root = buildPath(tempDir(), "gitrepo-test-" ~ name);
        if (exists(root))
            rmdirRecurse(root);
        mkdirRecurse(buildPath(root, "objects", "pack"));
        mkdirRecurse(buildPath(root, "refs", "heads"));
        mkdirRecurse(buildPath(root, "refs", "tags"));
        return Fixture(root);
    }

    void destroy()
    {
        rmdirRecurse(root);
    }

    void write(string rel, const(void)[] content)
    {
        auto p = buildPath(root, rel);
        mkdirRecurse(dirName(p));
        std.file.write(p, content);
    }

    /// Writes a loose object and returns its id.
    ObjectId loose(string type, const(ubyte)[] payload)
    {
        auto id = idOf(type, payload);
        auto hex = id.toString();
        write(buildPath("objects", hex[0 .. 2], hex[2 .. $]), zlibStored(storedForm(type, payload)));
        return id;
    }

    ObjectId loose(string type, string payload)
    {
        return loose(type, cast(const(ubyte)[]) payload);
    }

    ObjectId blob(string s) { return loose("blob", s); }

    ObjectId tree(const(Entry)[] entries)
    {
        ubyte[] p;
        foreach (e; entries)
        {
            p ~= cast(ubyte[])(e.mode ~ " " ~ e.name ~ "\0");
            p ~= e.id.bytes[];
        }
        return loose("tree", p);
    }

    ObjectId commit(ObjectId tree, const(ObjectId)[] parents, long when, string subject)
    {
        string s = "tree " ~ tree.toString() ~ "\n";
        foreach (p; parents)
            s ~= "parent " ~ p.toString() ~ "\n";
        s ~= "author Ada Lovelace <ada@example.com> " ~ when.to!string ~ " +0000\n";
        s ~= "committer Ada Lovelace <ada@example.com> " ~ when.to!string ~ " +0000\n\n" ~ subject ~ "\n";
        return loose("commit", s);
    }
}

struct Entry
{
    string mode;
    string name;
    ObjectId id;
}

/// Writes a v2 index for the given (id, offset) pairs.
ubyte[] makeIndex(ObjectId[] ids, uint[] offsets)
{
    import std.algorithm.sorting : sort;
    import std.range : zip;

    struct P { ObjectId id; uint off; }
    P[] ps;
    foreach (i, id; ids)
        ps ~= P(id, offsets[i]);
    ps.sort!((a, b) => a.id < b.id);
    ubyte[] r = [0xff, 't', 'O', 'c', 0, 0, 0, 2];
    void be(uint v) { r ~= [cast(ubyte)(v >> 24), cast(ubyte)(v >> 16), cast(ubyte)(v >> 8), cast(ubyte) v]; }
    foreach (b; 0 .. 256)
    {
        uint n = 0;
        foreach (p; ps)
            if (p.id.bytes[0] <= b)
                ++n;
        be(n);
    }
    foreach (p; ps)
        r ~= p.id.bytes[];
    foreach (p; ps)
        be(0);
    foreach (p; ps)
        be(p.off);
    r ~= new ubyte[40];
    return r;
}
