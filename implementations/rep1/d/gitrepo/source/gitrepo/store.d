/// The object database: loose objects and packfiles, read once and cached.
module gitrepo.store;

import std.algorithm : sort;
import std.file : dirEntries, exists, isDir, isFile, readFile = read, SpanMode;

import gitrepo.delta;
import gitrepo.errors;
import gitrepo.hex;
import gitrepo.inflate;
import gitrepo.memo;
import gitrepo.objectid;
import gitrepo.objecttype;
import gitrepo.packindex;

/// A fully reconstructed object: its type and payload (without the
/// `<type> <size>\0` header).
struct RawObject
{
    ObjectType type;
    const(ubyte)[] data;
}

/// Counts reported by `ObjectStore.counts`.
struct ObjectCounts
{
    size_t loose; /// loose object files
    size_t inPack; /// objects across all usable packs (an object in two packs counts twice)
    size_t packs; /// `.idx` files that have a matching `.pack`
}

private struct Pack
{
    PackIndex index;
    const(ubyte)[] data;
    RawObject[ulong] cache;
    string[ulong] failures;
}

/// Reads objects by id from `<objects dir>`: a loose copy first, then the packs
/// in name order. Every object is inflated and delta-reconstructed at most once;
/// the result (or the failure) is kept for the life of the store.
final class ObjectStore
{
    private string objectsDir;
    private ObjectId[] looseIds; // sorted
    private Pack[] packs;
    private Memo!RawObject cache;

    /// Delta chains deeper than this are rejected (git's default maximum is 50).
    enum maxDeltaDepth = 1000;

    /// Open the object directory (`<repo>/objects`). Missing directories are
    /// treated as empty.
    this(string objectsDir)
    {
        this.objectsDir = objectsDir;
        scanLoose();
        loadPacks();
    }

    /// Loose-object, packed-object and pack counts.
    ObjectCounts counts() const @safe pure nothrow @nogc
    {
        ObjectCounts c;
        c.loose = looseIds.length;
        c.packs = packs.length;
        foreach (ref p; packs)
            c.inPack += p.index.length;
        return c;
    }

    /// True when `id` is a loose file or listed in a pack index. The content is
    /// not read.
    bool contains(const ObjectId id) const @safe pure
    {
        if (looseHas(id))
            return true;
        foreach (ref p; packs)
            if (p.index.contains(id))
                return true;
        return false;
    }

    /// Ids that begin with the given nibbles: `hex` is 1..40 hexadecimal digits
    /// (either case). At most `limit` distinct ids are returned (ascending
    /// within each source, so the result is only meaningful for `limit` > 1 as
    /// an "is it ambiguous" test). Costs O(log N) per source.
    ObjectId[] findByPrefix(scope const(char)[] hex, size_t limit = 2) const @safe pure
    {
        ObjectId lo, hi;
        foreach (i; 0 .. 40)
        {
            immutable v = i < hex.length ? hexValue(hex[i]) : -1;
            if (i < hex.length && v < 0)
                return null;
            immutable nlo = i < hex.length ? v : 0;
            immutable nhi = i < hex.length ? v : 15;
            if (i % 2 == 0)
            {
                lo.bytes[i / 2] = cast(ubyte)(nlo << 4);
                hi.bytes[i / 2] = cast(ubyte)(nhi << 4);
            }
            else
            {
                lo.bytes[i / 2] |= cast(ubyte) nlo;
                hi.bytes[i / 2] |= cast(ubyte) nhi;
            }
        }
        ObjectId[] found;
        void add(ObjectId id)
        {
            foreach (f; found)
                if (f == id)
                    return;
            found ~= id;
        }

        // loose ids
        {
            size_t a = 0, b = looseIds.length;
            while (a < b)
            {
                immutable mid = a + (b - a) / 2;
                if (looseIds[mid] < lo)
                    a = mid + 1;
                else
                    b = mid;
            }
            for (size_t i = a; i < looseIds.length && looseIds[i] <= hi && found.length < limit; ++i)
                add(looseIds[i]);
        }
        foreach (ref p; packs)
        {
            for (size_t i = p.index.lowerBound(lo); i < p.index.length && found.length < limit; ++i)
            {
                immutable id = p.index.idAt(i);
                if (id > hi)
                    break;
                add(id);
            }
        }
        return found;
    }

    /// Read (and cache) the object `id`.
    /// Throws: `GitError` if it is absent or damaged.
    RawObject read(const ObjectId id)
    {
        return readAt(id, 0);
    }

    // ------------------------------------------------------------------

    private bool looseHas(const ObjectId id) const @safe pure nothrow @nogc
    {
        size_t a = 0, b = looseIds.length;
        while (a < b)
        {
            immutable mid = a + (b - a) / 2;
            if (looseIds[mid] < id)
                a = mid + 1;
            else
                b = mid;
        }
        return a < looseIds.length && looseIds[a] == id;
    }

    private void scanLoose()
    {
        if (!exists(objectsDir) || !isDir(objectsDir))
            return;
        foreach (dir; dirEntries(objectsDir, SpanMode.shallow))
        {
            immutable dname = baseName(dir.name);
            if (dname.length != 2 || !isLowerHex(dname) || !dir.isDir)
                continue;
            foreach (f; dirEntries(dir.name, SpanMode.shallow))
            {
                immutable fname = baseName(f.name);
                if (fname.length != 38 || !isLowerHex(fname) || !f.isFile)
                    continue;
                ObjectId id;
                if (ObjectId.tryParse(dname ~ fname, id))
                    looseIds ~= id;
            }
        }
        looseIds.sort();
    }

    private void loadPacks()
    {
        immutable packDir = objectsDir ~ "/pack";
        if (!exists(packDir) || !isDir(packDir))
            return;
        string[] stems;
        foreach (f; dirEntries(packDir, SpanMode.shallow))
        {
            immutable n = baseName(f.name);
            if (n.length > 4 && n[$ - 4 .. $] == ".idx" && f.isFile)
                stems ~= n[0 .. $ - 4];
        }
        stems.sort();
        foreach (stem; stems)
        {
            immutable idxPath = packDir ~ "/" ~ stem ~ ".idx";
            immutable packPath = packDir ~ "/" ~ stem ~ ".pack";
            if (!exists(packPath) || !isFile(packPath))
                continue;
            try
            {
                Pack p;
                p.index = PackIndex.parse(cast(const(ubyte)[]) readFile(idxPath));
                p.data = cast(const(ubyte)[]) readFile(packPath);
                packs ~= p;
            }
            catch (GitError)
            {
                // An unusable pack contributes nothing.
            }
        }
    }

    private RawObject readAt(const ObjectId id, int depth)
    {
        return cache.get(id, () {
            if (depth > maxDeltaDepth)
                throw new GitError("delta chain too deep");
            if (looseHas(id))
                return readLoose(id);
            foreach (pi, ref p; packs)
            {
                ulong off;
                if (p.index.find(id, off))
                    return readPacked(pi, off, depth);
            }
            throw new GitError("object not found: " ~ id.toString());
        });
    }

    private RawObject readLoose(const ObjectId id)
    {
        immutable hex = id.toString();
        immutable path = objectsDir ~ "/" ~ hex[0 .. 2] ~ "/" ~ hex[2 .. $];
        const(ubyte)[] file;
        try
            file = cast(const(ubyte)[]) readFile(path);
        catch (Exception)
            throw new GitError("cannot read loose object " ~ hex);
        auto plain = zlibDecompress(file);
        return parseStoredForm(plain);
    }

    private RawObject readPacked(size_t packIndex, ulong offset, int depth)
    {
        auto p = &packs[packIndex];
        if (auto c = offset in p.cache)
            return *c;
        if (auto f = offset in p.failures)
            throw new GitError(*f);
        try
        {
            auto r = decodePackEntry(packIndex, offset, depth);
            p.cache[offset] = r;
            return r;
        }
        catch (GitError e)
        {
            p.failures[offset] = e.msg;
            throw e;
        }
    }

    private RawObject decodePackEntry(size_t packIndex, ulong offset, int depth)
    {
        if (depth > maxDeltaDepth)
            throw new GitError("delta chain too deep");
        const data = packs[packIndex].data;
        if (offset < 12 || offset >= data.length)
            throw new GitError("pack offset out of range");
        size_t pos = cast(size_t) offset;
        ubyte b = data[pos++];
        immutable type = (b >> 4) & 7;
        ulong size = b & 15;
        uint shift = 4;
        while (b & 0x80)
        {
            if (pos >= data.length || shift > 60)
                throw new GitError("bad pack object header");
            b = data[pos++];
            size |= cast(ulong)(b & 0x7f) << shift;
            shift += 7;
        }
        switch (type)
        {
        case 1: .. case 4:
            auto payload = inflateAt(data, pos, size);
            return RawObject(cast(ObjectType) type, payload);
        case 6:
            if (pos >= data.length)
                throw new GitError("bad pack object header");
            b = data[pos++];
            ulong v = b & 0x7f;
            while (b & 0x80)
            {
                if (pos >= data.length || v > (ulong.max >> 8))
                    throw new GitError("bad pack object header");
                b = data[pos++];
                v = ((v + 1) << 7) | (b & 0x7f);
            }
            if (v == 0 || v > offset)
                throw new GitError("bad OFS_DELTA base offset");
            auto delta = inflateAt(data, pos, size);
            auto base = readPacked(packIndex, offset - v, depth + 1);
            return RawObject(base.type, applyDelta(base.data, delta));
        case 7:
            if (pos + 20 > data.length)
                throw new GitError("bad pack object header");
            immutable baseId = ObjectId.fromBytes(data[pos .. pos + 20]);
            pos += 20;
            auto delta = inflateAt(data, pos, size);
            auto base = readAt(baseId, depth + 1);
            return RawObject(base.type, applyDelta(base.data, delta));
        default:
            throw new GitError("invalid pack object type");
        }
    }

    private static const(ubyte)[] inflateAt(const(ubyte)[] data, size_t pos, ulong sizeHint)
    {
        size_t used;
        immutable hint = sizeHint < (1UL << 28) ? cast(size_t) sizeHint : 0;
        return zlibDecompress(data[pos .. $], used, hint);
    }
}

/// Split an object's stored form (`<type> <size>\0<payload>`) into type and
/// payload, checking the header and the size.
/// Throws: `GitError` if the form is damaged.
RawObject parseStoredForm(const(ubyte)[] plain) @safe pure
{
    size_t i;
    while (i < plain.length && i < 7 && plain[i] != ' ')
        ++i;
    ObjectType type;
    if (i >= plain.length || plain[i] != ' ' || !tryParseType(cast(const(char)[]) plain[0 .. i], type))
        throw new GitError("bad object header");
    ++i;
    size_t digits;
    ulong size;
    while (i < plain.length && plain[i] >= '0' && plain[i] <= '9')
    {
        if (size > ulong.max / 10 - 1)
            throw new GitError("bad object size");
        size = size * 10 + (plain[i] - '0');
        ++i;
        ++digits;
    }
    if (digits == 0 || i >= plain.length || plain[i] != 0)
        throw new GitError("bad object header");
    ++i;
    if (plain.length - i != size)
        throw new GitError("object size mismatch");
    return RawObject(type, plain[i .. $]);
}

private string baseName(string path) @safe pure nothrow @nogc
{
    size_t i = path.length;
    while (i > 0 && path[i - 1] != '/')
        --i;
    return path[i .. $];
}

unittest
{
    import std.exception : assertThrown;

    auto o = parseStoredForm(cast(const(ubyte)[]) "blob 9\0one file\n");
    assert(o.type == ObjectType.blob && cast(string) o.data == "one file\n");
    assertThrown!GitError(parseStoredForm(cast(const(ubyte)[]) "blob 8\0one file\n"));
    assertThrown!GitError(parseStoredForm(cast(const(ubyte)[]) "bloc 9\0one file\n"));
    assertThrown!GitError(parseStoredForm(cast(const(ubyte)[]) "blob \0one file\n"));
    assertThrown!GitError(parseStoredForm(cast(const(ubyte)[]) "blob 9 one file\n"));
    assert(parseStoredForm(cast(const(ubyte)[]) "tree 0\0").data.length == 0);
}
