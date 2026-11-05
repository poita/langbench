/// A chained hash table from composite keys of values to dense entry ids.
module minisql.keytable;

import minisql.value;

/// Hash table keyed by a fixed-width tuple of `Value`s, used for GROUP BY and
/// the hash join. Entries get consecutive ids in insertion order, and the
/// entries of one bucket chain are kept in insertion order too, so walking the
/// matches for a key yields them in the order they were added.
struct KeyTable
{
    private size_t width;
    private Value[] keys; // entry e occupies keys[e*width .. (e+1)*width]
    private ulong[] hashes;
    private int[] next;
    private int[] heads, tails;
    private size_t mask;

    /// Creates a table for keys of `width` values.
    this(size_t width) pure nothrow @safe
    {
        this.width = width;
        heads = new int[16];
        tails = new int[16];
        heads[] = -1;
        tails[] = -1;
        mask = 15;
    }

    /// Number of entries.
    size_t length() const pure nothrow @nogc @safe
    {
        return hashes.length;
    }

    /// Hashes a key.
    static ulong hashKey(const(Value)[] key) pure nothrow @nogc @safe
    {
        ulong h = 0x84222325cbf29ce4UL;
        foreach (ref v; key)
            h = (h ^ hashValue(v)) * 0x100000001b3UL + (h >> 29);
        return h;
    }

    /// The key stored for entry `e`.
    const(Value)[] keyOf(size_t e) const pure nothrow @nogc @safe
    {
        return keys[e * width .. (e + 1) * width];
    }

    private bool matches(int e, ulong h, const(Value)[] key) const pure nothrow @nogc @safe
    {
        if (hashes[e] != h)
            return false;
        auto k = keyOf(e);
        foreach (i, ref v; key)
            if (!sameValue(k[i], v))
                return false;
        return true;
    }

    /// The first entry (in insertion order) equal to `key`, or -1.
    int find(ulong h, const(Value)[] key) const pure nothrow @nogc @safe
    {
        for (int e = heads[h & mask]; e >= 0; e = next[e])
            if (matches(e, h, key))
                return e;
        return -1;
    }

    /// The next entry after `e` equal to `key`, or -1.
    int findNext(int e, ulong h, const(Value)[] key) const pure nothrow @nogc @safe
    {
        for (e = next[e]; e >= 0; e = next[e])
            if (matches(e, h, key))
                return e;
        return -1;
    }

    /// Adds a new entry (even if an equal key exists) and returns its id.
    int add(ulong h, const(Value)[] key) pure nothrow @safe
    {
        if (hashes.length >= heads.length)
            grow();
        immutable e = cast(int) hashes.length;
        hashes ~= h;
        keys ~= key;
        next ~= -1;
        link(e, h);
        return e;
    }

    private void link(int e, ulong h) pure nothrow @nogc @safe
    {
        immutable b = h & mask;
        if (tails[b] < 0)
            heads[b] = e;
        else
            next[tails[b]] = e;
        tails[b] = e;
    }

    private void grow() pure nothrow @safe
    {
        immutable n = heads.length * 2;
        heads = new int[n];
        tails = new int[n];
        heads[] = -1;
        tails[] = -1;
        mask = n - 1;
        foreach (i; 0 .. hashes.length)
        {
            next[i] = -1;
            link(cast(int) i, hashes[i]);
        }
    }
}
