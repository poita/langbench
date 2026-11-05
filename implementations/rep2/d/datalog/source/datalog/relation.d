/// Relations: append-only tuple stores with a hash set for deduplication and
/// lazily-built, incrementally-extended hash indexes.
module datalog.relation;

import datalog.ast : ConstId;

/// Largest supported predicate arity.
enum maxArity = 32;

private pragma(inline, true) ulong mix(ulong h, uint v) @safe pure nothrow @nogc
{
    h = (h ^ v) * 0x9E3779B97F4A7C15UL;
    return h ^ (h >> 32);
}

private pragma(inline, true) size_t finish(ulong h) @safe pure nothrow @nogc
{
    h ^= h >> 33;
    h *= 0xff51afd7ed558ccdUL;
    h ^= h >> 33;
    return cast(size_t) h;
}

/// A set of fixed-arity tuples of constant ids, stored contiguously in insertion
/// order, so every tuple has a stable integer position.
final class Relation
{
    /// Number of components per tuple.
    immutable uint arity;
    /// Flat tuple storage (stride `arity`); only the first `length * arity` entries are valid.
    uint[] data;
    private size_t count;
    private uint[] table;      // open addressing; position + 1, 0 = empty
    private Index[uint] indexes;

    ///
    this(uint arity) @safe pure nothrow
    {
        this.arity = arity;
        table = new uint[16];
    }

    /// Number of tuples.
    size_t length() const @safe pure nothrow @nogc { return count; }

    /// The tuple at insertion position `pos`.
    const(uint)[] tuple(size_t pos) const @safe pure nothrow @nogc
    {
        return data[pos * arity .. (pos + 1) * arity];
    }

    private size_t hashOf(const(uint)* t) const @trusted pure nothrow @nogc
    {
        ulong h = 0x243F6A8885A308D3UL;
        foreach (i; 0 .. arity) h = mix(h, t[i]);
        return finish(h);
    }

    private bool sameAt(size_t pos, const(uint)* t) const @trusted pure nothrow @nogc
    {
        auto p = data.ptr + pos * arity;
        foreach (i; 0 .. arity)
            if (p[i] != t[i]) return false;
        return true;
    }

    /// Membership test.
    bool contains(const(uint)[] t) const @trusted pure nothrow @nogc
    {
        return containsPtr(t.ptr);
    }

    /// ditto
    bool containsPtr(const(uint)* t) const @trusted pure nothrow @nogc
    {
        immutable m = table.length - 1;
        size_t i = hashOf(t) & m;
        while (true)
        {
            immutable s = table[i];
            if (s == 0) return false;
            if (sameAt(s - 1, t)) return true;
            i = (i + 1) & m;
        }
    }

    /// Insert a tuple; returns false if it was already present.
    bool insert(const(uint)[] t) @trusted pure nothrow
    {
        assert(t.length == arity);
        if ((count + 1) * 2 > table.length) growTable();
        immutable m = table.length - 1;
        size_t i = hashOf(t.ptr) & m;
        while (true)
        {
            immutable s = table[i];
            if (s == 0) break;
            if (sameAt(s - 1, t.ptr)) return false;
            i = (i + 1) & m;
        }
        if ((count + 1) * arity > data.length)
        {
            auto n = data.length * 2;
            if (n < 64) n = 64 + arity;
            data.length = n;
        }
        data[count * arity .. (count + 1) * arity] = t[];
        table[i] = cast(uint)(count + 1);
        ++count;
        return true;
    }

    private void growTable() @trusted pure nothrow
    {
        auto nt = new uint[table.length * 2];
        immutable m = nt.length - 1;
        foreach (pos; 0 .. count)
        {
            size_t i = hashOf(data.ptr + pos * arity) & m;
            while (nt[i] != 0) i = (i + 1) & m;
            nt[i] = cast(uint)(pos + 1);
        }
        table = nt;
    }

    /// Get (creating if necessary) the index keyed on the argument positions whose
    /// bits are set in `keyMask`. The index is not brought up to date; call
    /// `Index.update` before using it.
    Index index(uint keyMask) @safe pure nothrow
    {
        if (auto p = keyMask in indexes) return *p;
        auto ix = new Index(this, keyMask);
        indexes[keyMask] = ix;
        return ix;
    }
}

/// A hash index over a subset of a relation's argument positions. It maps the key
/// values to the positions of matching tuples, in ascending order.
final class Index
{
    /// Marks the end of a position chain / a missing group.
    enum uint none = uint.max;

    private Relation rel;
    private uint[] keyPos;
    private uint[] table;       // group + 1, 0 = empty
    private uint[] first, last; // per group: first / last tuple position
    private uint[] nextPos;     // per tuple position: next position in the same group
    private size_t indexed;

    this(Relation r, uint keyMask) @safe pure nothrow
    {
        rel = r;
        foreach (i; 0 .. r.arity)
            if (keyMask & (1u << i)) keyPos ~= i;
        table = new uint[16];
    }

    /// Index the tuples appended to the relation since the last update.
    void update() @trusted pure nothrow
    {
        immutable n = rel.length;
        if (indexed == n) return;
        if (nextPos.length < n)
        {
            auto len = nextPos.length * 2;
            nextPos.length = len < n ? n : len;
        }
        immutable ar = rel.arity;
        foreach (pos; indexed .. n)
        {
            auto t = rel.data.ptr + pos * ar;
            ulong h = 0x13198A2E03707344UL;
            foreach (k; keyPos) h = mix(h, t[k]);
            if ((first.length + 1) * 2 > table.length) growTable();
            immutable m = table.length - 1;
            size_t i = finish(h) & m;
            nextPos[pos] = none;
            while (true)
            {
                immutable s = table[i];
                if (s == 0)
                {
                    first ~= cast(uint) pos;
                    last ~= cast(uint) pos;
                    table[i] = cast(uint) first.length;
                    break;
                }
                immutable g = s - 1;
                auto ft = rel.data.ptr + first[g] * ar;
                bool same = true;
                foreach (k; keyPos)
                    if (ft[k] != t[k]) { same = false; break; }
                if (same)
                {
                    nextPos[last[g]] = cast(uint) pos;
                    last[g] = cast(uint) pos;
                    break;
                }
                i = (i + 1) & m;
            }
        }
        indexed = n;
    }

    private void growTable() @trusted pure nothrow
    {
        auto nt = new uint[table.length * 2];
        immutable m = nt.length - 1;
        immutable ar = rel.arity;
        foreach (g; 0 .. first.length)
        {
            auto t = rel.data.ptr + first[g] * ar;
            ulong h = 0x13198A2E03707344UL;
            foreach (k; keyPos) h = mix(h, t[k]);
            size_t i = finish(h) & m;
            while (nt[i] != 0) i = (i + 1) & m;
            nt[i] = cast(uint)(g + 1);
        }
        table = nt;
    }

    /// Find the group whose key equals `key` (the values at the key positions, in
    /// ascending position order). Returns the first tuple position of the group,
    /// or `none`. Follow the chain with `next`.
    uint find(const(uint)* key) const @trusted pure nothrow @nogc
    {
        ulong h = 0x13198A2E03707344UL;
        immutable nk = keyPos.length;
        foreach (j; 0 .. nk) h = mix(h, key[j]);
        immutable m = table.length - 1;
        size_t i = finish(h) & m;
        immutable ar = rel.arity;
        while (true)
        {
            immutable s = table[i];
            if (s == 0) return none;
            auto ft = rel.data.ptr + first[s - 1] * ar;
            bool same = true;
            foreach (j; 0 .. nk)
                if (ft[keyPos[j]] != key[j]) { same = false; break; }
            if (same) return first[s - 1];
            i = (i + 1) & m;
        }
    }

    /// The next position in the same group after `pos`, or `none`.
    uint next(uint pos) const @safe pure nothrow @nogc { return nextPos[pos]; }
}
