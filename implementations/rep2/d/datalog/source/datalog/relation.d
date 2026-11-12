/// Tuple storage: a duplicate-free set of fixed-arity tuples of `Value`s with
/// incrementally maintained hash indexes.
module datalog.relation;

/// A constant of the evaluated program, represented by its rank in the total
/// order on constants (so `<` on values *is* the order of the language).
alias Value = uint;

/// "No tuple" marker.
enum uint none = uint.max;

private enum ulong hashSeed = 0xcbf29ce484222325UL;

/// Mixes one value into a running hash.
ulong hashStep(ulong h, Value v) @safe pure nothrow @nogc
{
    h = (h ^ (v + 0x9E3779B9UL)) * 0x9E3779B97F4A7C15UL;
    return h ^ (h >> 32);
}

/// Hash of a sequence of values (used for both keys and whole tuples).
ulong hashOf(const(Value)[] values) @safe pure nothrow @nogc
{
    ulong h = hashSeed;
    foreach (v; values)
        h = hashStep(h, v);
    return h;
}

/// Initial value of an incrementally computed key hash.
enum ulong hashStart = hashSeed;

/// A hash index over a subset of a relation's columns (given as a bit mask).
///
/// Tuples with equal key hash are chained through `next`; the chain visits
/// tuple ids in descending order. Hash collisions between different keys are
/// possible, so callers must compare the key columns of every candidate.
final class Index
{
    private Relation owner;
    /// Bit `i` set: column `i` is part of the key.
    immutable uint mask;
    private uint[] heads;
    private uint[] nexts;
    private size_t n; // tuples 0 .. n-1 are indexed

    private this(Relation owner, uint mask) @safe pure nothrow
    {
        this.owner = owner;
        this.mask = mask;
        heads = new uint[16];
        heads[] = none;
    }

    private ulong keyHashOf(uint id) const @safe pure nothrow @nogc
    {
        auto t = owner.tuple(id);
        ulong h = hashStart;
        foreach (i, v; t)
            if (mask & (1u << i))
                h = hashStep(h, v);
        return h;
    }

    private void add(uint id) @safe pure nothrow
    {
        if (n >= heads.length)
            grow();
        if (nexts.length <= id)
            nexts.length = nexts.length * 2 > id + 1 ? nexts.length * 2 : id + 1;
        auto b = keyHashOf(id) & (heads.length - 1);
        nexts[id] = heads[b];
        heads[b] = id;
        ++n;
    }

    private void grow() @safe pure nothrow
    {
        heads = new uint[heads.length * 2];
        heads[] = none;
        foreach (uint id; 0 .. cast(uint) n)
        {
            auto b = keyHashOf(id) & (heads.length - 1);
            nexts[id] = heads[b];
            heads[b] = id;
        }
    }

    /// First candidate of the bucket for a key hash (`none` if empty).
    uint first(ulong keyHash) const @safe pure nothrow @nogc
    {
        return heads[keyHash & (heads.length - 1)];
    }

    /// Next candidate in the chain after `id` (`none` at the end).
    uint next(uint id) const @safe pure nothrow @nogc
    {
        return nexts[id];
    }
}

/// A set of tuples of a fixed arity, stored contiguously in insertion order.
/// A tuple's id is its insertion number.
final class Relation
{
    /// Number of columns.
    immutable uint arity;

    /// Start (inclusive) and end (exclusive) of the tuple ids that form the
    /// current delta; maintained by the evaluator.
    uint deltaStart, deltaEnd;

    private Value[] data;
    private uint[] table; // open-addressing set of tuple ids
    private uint count_;
    private uint indexed_;
    private Index[uint] indexes;
    private Index[] indexList;

    this(uint arity) @safe pure nothrow
    {
        this.arity = arity;
        table = new uint[32];
        table[] = none;
    }

    /// Number of tuples.
    @property uint length() const @safe pure nothrow @nogc
    {
        return count_;
    }

    /// Number of tuples already visible in the indexes (a prefix of the ids).
    @property uint indexedLength() const @safe pure nothrow @nogc
    {
        return indexed_;
    }

    /// Tuple number `id`.
    const(Value)[] tuple(uint id) const @safe pure nothrow @nogc
    {
        return data[id * arity .. (id + 1) * arity];
    }

    /// Id of `t` or `none` when it is not in the relation.
    uint find(scope const(Value)[] t) const @safe pure nothrow @nogc
    {
        auto mask = table.length - 1;
        auto s = hashOf(t) & mask;
        for (;; s = (s + 1) & mask)
        {
            auto id = table[s];
            if (id == none)
                return none;
            if (tuple(id) == t)
                return id;
        }
    }

    /// Adds `t`; returns false if it was already present. The tuple becomes
    /// visible to indexes only after the next `flush`.
    bool insert(scope const(Value)[] t) @safe pure nothrow
    in (t.length == arity)
    {
        auto mask = table.length - 1;
        auto s = hashOf(t) & mask;
        for (;; s = (s + 1) & mask)
        {
            auto id = table[s];
            if (id == none)
                break;
            if (tuple(id) == t)
                return false;
        }
        table[s] = count_;
        data ~= t;
        ++count_;
        if (count_ * 2 > table.length)
            rehash();
        return true;
    }

    private void rehash() @safe pure nothrow
    {
        table = new uint[table.length * 2];
        table[] = none;
        auto mask = table.length - 1;
        foreach (uint id; 0 .. count_)
        {
            auto s = hashOf(tuple(id)) & mask;
            while (table[s] != none)
                s = (s + 1) & mask;
            table[s] = id;
        }
    }

    /// The index on the columns in `mask`, created (and filled with the
    /// indexed prefix) on first request.
    Index index(uint mask) @safe pure nothrow
    {
        if (auto p = mask in indexes)
            return *p;
        auto ix = new Index(this, mask);
        foreach (uint id; 0 .. indexed_)
            ix.add(id);
        indexes[mask] = ix;
        indexList ~= ix;
        return ix;
    }

    /// Makes all tuples inserted so far visible to the indexes.
    void flush() @safe pure nothrow
    {
        foreach (ix; indexList)
            foreach (uint id; indexed_ .. count_)
                ix.add(id);
        indexed_ = count_;
    }
}

@("relation: set semantics")
@safe pure nothrow unittest
{
    auto r = new Relation(2);
    assert(r.insert([1, 2]));
    assert(!r.insert([1, 2]));
    assert(r.insert([2, 1]));
    assert(r.length == 2);
    assert(r.find([2, 1]) == 1);
    assert(r.find([3, 3]) == none);
}

@("relation: growth keeps every tuple findable")
@safe pure nothrow unittest
{
    auto r = new Relation(2);
    foreach (uint i; 0 .. 5000)
        assert(r.insert([i, i * 7]));
    foreach (uint i; 0 .. 5000)
        assert(r.find([i, i * 7]) == i);
    assert(r.length == 5000);
}

@("relation: indexes are maintained by flush")
@safe pure nothrow unittest
{
    auto r = new Relation(2);
    auto ix = r.index(0b01);
    foreach (uint i; 0 .. 1000)
        r.insert([i % 10, i]);
    assert(r.indexedLength == 0);
    r.flush();
    assert(r.indexedLength == 1000);
    uint hits;
    for (auto id = ix.first(hashOf([3])); id != none; id = ix.next(id))
        if (r.tuple(id)[0] == 3)
            ++hits;
    assert(hits == 100);
    // an index created late covers the existing tuples
    auto iy = r.index(0b10);
    hits = 0;
    for (auto id = iy.first(hashOf([42])); id != none; id = iy.next(id))
        if (r.tuple(id)[1] == 42)
            ++hits;
    assert(hits == 1);
}
