/**
 * Append-only relations of integer tuples with a deduplicating hash set and
 * lazily created hash indexes.
 *
 * A relation stores its tuples contiguously in insertion order, so a tuple has
 * a stable integer position. Indexes map the values at a fixed set of columns
 * to the ascending positions of the matching tuples and are extended
 * incrementally (never rebuilt) by `HashIndex.update`.
 */
module datalog.relation;

/// "No position" marker (also the empty hash-table slot).
enum uint none = uint.max;

private ulong mix(ulong h, uint v) pure nothrow @nogc @safe
{
    h = (h ^ v) * 0x9E3779B97F4A7C15UL;
    return h ^ (h >> 29);
}

private uint finish(ulong h) pure nothrow @nogc @safe
{
    return cast(uint)(h ^ (h >> 32));
}

private enum ulong hashSeed = 0x243F6A8885A308D3UL;

/// A set of fixed-arity tuples of `uint`, kept in insertion order.
final class Relation
{
    private uint arity_;
    private uint[] data;
    private uint count;
    private uint[] table; // open addressing; slot holds a tuple position or `none`
    private uint mask;
    private HashIndex[] indexes;

    /// Creates an empty relation of the given arity (at least 1).
    this(uint arity) pure nothrow @safe
    {
        arity_ = arity;
        table = new uint[16];
        table[] = none;
        mask = 15;
    }

    /// Number of columns.
    uint arity() const pure nothrow @nogc @safe { return arity_; }

    /// Number of tuples.
    uint length() const pure nothrow @nogc @safe { return count; }

    /// The tuple at insertion position `pos`.
    const(uint)[] opIndex(uint pos) const pure nothrow @nogc @safe
    {
        const start = cast(size_t) pos * arity_;
        return data[start .. start + arity_];
    }

    private uint hashOf(scope const(uint)[] t) const pure nothrow @nogc @safe
    {
        ulong h = hashSeed;
        foreach (v; t)
            h = mix(h, v);
        return finish(h);
    }

    /// True if the tuple is in the relation.
    bool contains(scope const(uint)[] t) const pure nothrow @nogc @safe
    {
        uint i = hashOf(t) & mask;
        while (true)
        {
            const p = table[i];
            if (p == none) return false;
            if (this[p] == t) return true;
            i = (i + 1) & mask;
        }
    }

    /// Adds the tuple unless already present; returns whether it was added.
    bool insert(scope const(uint)[] t) pure nothrow @safe
    {
        assert(t.length == arity_);
        uint i = hashOf(t) & mask;
        while (true)
        {
            const p = table[i];
            if (p == none) break;
            if (this[p] == t) return false;
            i = (i + 1) & mask;
        }
        table[i] = count;
        data ~= t;
        count++;
        if (cast(ulong) count * 2 > table.length)
            grow();
        return true;
    }

    private void grow() pure nothrow @safe
    {
        table = new uint[table.length * 2];
        table[] = none;
        mask = cast(uint)(table.length - 1);
        foreach (p; 0 .. count)
        {
            uint i = hashOf(this[p]) & mask;
            while (table[i] != none)
                i = (i + 1) & mask;
            table[i] = p;
        }
    }

    /**
     * Returns the index on the columns whose bits are set in `columnMask`
     * (bit i = column i), creating it (empty, not yet updated) if needed.
     */
    HashIndex indexOn(uint columnMask) pure nothrow @safe
    {
        foreach (ix; indexes)
            if (ix.columnMask == columnMask)
                return ix;
        auto ix = new HashIndex(this, columnMask);
        indexes ~= ix;
        return ix;
    }
}

/**
 * Hash index of a relation on a set of columns. Each distinct key owns a chain
 * of tuple positions in ascending order, so a scan can stop at the first
 * position beyond a snapshot bound.
 */
final class HashIndex
{
    private Relation rel;
    private uint columnMask_;
    private uint[] cols_;
    private uint[] heads; // slot -> first position with this key, or `none`
    private uint[] tails; // slot -> last position with this key
    private uint[] next_; // position -> next position with the same key
    private uint hmask;
    private uint used;    // distinct keys
    private uint indexed; // tuples [0, indexed) are in the index

    private this(Relation r, uint columnMask) pure nothrow @safe
    {
        rel = r;
        columnMask_ = columnMask;
        foreach (c; 0 .. r.arity)
            if (columnMask & (1u << c))
                cols_ ~= c;
        heads = new uint[16];
        heads[] = none;
        tails = new uint[16];
        hmask = 15;
    }

    /// Bit set of indexed columns.
    uint columnMask() const pure nothrow @nogc @safe { return columnMask_; }

    /// Indexed columns in ascending order (the order key values are given in).
    const(uint)[] columns() const pure nothrow @nogc @safe { return cols_; }

    /// Chain successor table: `next[p]` is the following position with p's key, or `none`.
    const(uint)[] next() const pure nothrow @nogc @safe { return next_; }

    /// Indexes the tuples appended to the relation since the last update.
    void update() pure nothrow @safe
    {
        const n = rel.length;
        if (indexed == n) return;
        if (next_.length < n)
        {
            auto bigger = new uint[n > 2 * next_.length ? n : 2 * next_.length];
            bigger[0 .. indexed] = next_[0 .. indexed];
            next_ = bigger;
        }
        foreach (p; indexed .. n)
            add(p);
        indexed = n;
    }

    /// First position whose key columns equal `key`, or `none`.
    /// Follow with `next` while the position is below the wanted bound.
    uint find(scope const(uint)[] key) const pure nothrow @nogc @safe
    {
        ulong h = hashSeed;
        foreach (v; key)
            h = mix(h, v);
        uint i = finish(h) & hmask;
        while (true)
        {
            const p = heads[i];
            if (p == none) return none;
            if (keyEquals(rel[p], key)) return p;
            i = (i + 1) & hmask;
        }
    }

    private bool keyEquals(const(uint)[] tuple, scope const(uint)[] key) const pure nothrow @nogc @safe
    {
        foreach (j, c; cols_)
            if (tuple[c] != key[j])
                return false;
        return true;
    }

    private uint hashTuple(const(uint)[] tuple) const pure nothrow @nogc @safe
    {
        ulong h = hashSeed;
        foreach (c; cols_)
            h = mix(h, tuple[c]);
        return finish(h);
    }

    private void add(uint p) pure nothrow @safe
    {
        next_[p] = none;
        const tuple = rel[p];
        uint i = hashTuple(tuple) & hmask;
        while (true)
        {
            const h = heads[i];
            if (h == none) break;
            if (sameKey(rel[h], tuple))
            {
                next_[tails[i]] = p;
                tails[i] = p;
                return;
            }
            i = (i + 1) & hmask;
        }
        heads[i] = p;
        tails[i] = p;
        used++;
        if (cast(ulong) used * 2 > heads.length)
            grow();
    }

    private bool sameKey(const(uint)[] a, const(uint)[] b) const pure nothrow @nogc @safe
    {
        foreach (c; cols_)
            if (a[c] != b[c])
                return false;
        return true;
    }

    private void grow() pure nothrow @safe
    {
        auto oldHeads = heads, oldTails = tails;
        heads = new uint[oldHeads.length * 2];
        heads[] = none;
        tails = new uint[oldHeads.length * 2];
        hmask = cast(uint)(heads.length - 1);
        foreach (s, h; oldHeads)
        {
            if (h == none) continue;
            uint i = hashTuple(rel[h]) & hmask;
            while (heads[i] != none)
                i = (i + 1) & hmask;
            heads[i] = h;
            tails[i] = oldTails[s];
        }
    }
}
