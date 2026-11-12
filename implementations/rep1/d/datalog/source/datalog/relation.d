/// Storage for the tuples of one predicate, with hash indexes.
module datalog.relation;

/// Marks the end of a bucket chain / an empty hash slot.
enum uint none = uint.max;

/// Hashes one more value into a running hash. Start from `hashSeed`.
enum ulong hashSeed = 0xcbf29ce484222325UL;

ulong mixHash(ulong h, uint value) @safe pure nothrow @nogc
{
    h = (h ^ value) * 0x9E3779B97F4A7C15UL;
    return h ^ (h >> 32);
}

/// A hash index over a subset of the columns of a `Relation`.
///
/// Rows are chained per bucket (`heads` / `next`, newest first). A bucket may
/// hold rows with different keys, so lookups must re-check the key columns.
struct Index
{
    uint mask; /// bit i set when column i is part of the key
    ubyte[] cols; /// key columns, ascending
    uint[] heads; /// bucket -> newest row in the bucket, or `none`
    uint[] next; /// row -> next older row in the same bucket, or `none`
    size_t indexed; /// rows `[0, indexed)` are in the index
}

/// A set of fixed-arity tuples of constant ranks.
///
/// Tuples are stored row-major in insertion order, so a row number is also an
/// age: the rows added by one evaluation round form a contiguous range. A
/// hash table over whole rows rejects duplicates. Indexes are created on demand
/// by `indexFor` and are brought up to date incrementally by `syncIndexes`, so
/// each row is added to each index exactly once however many rounds there are.
final class Relation
{
    /// Number of columns.
    immutable uint arity;
    /// Row-major tuple storage; row `r` is `data[r*arity .. (r+1)*arity]`.
    uint[] data;
    /// Number of rows.
    size_t count;
    /// The indexes created so far.
    Index[] indexes;

    private uint[] table; // open-addressing set of row numbers

    this(uint arity) @safe pure nothrow
    {
        this.arity = arity;
        table = new uint[16];
        table[] = none;
    }

    /// The `r`-th row.
    const(uint)[] row(size_t r) const @safe pure nothrow @nogc
    {
        return data[r * arity .. (r + 1) * arity];
    }

    private ulong hashRow(scope const(uint)[] t) const @safe pure nothrow @nogc
    {
        ulong h = hashSeed;
        foreach (v; t)
            h = mixHash(h, v);
        return h;
    }

    /// Whether `tuple` is in the relation.
    bool contains(scope const(uint)[] tuple) const @safe pure nothrow @nogc
    {
        return find(tuple, hashRow(tuple)) != none;
    }

    private uint find(scope const(uint)[] tuple, ulong h) const @safe pure nothrow @nogc
    {
        immutable m = table.length - 1;
        for (size_t i = h & m;; i = (i + 1) & m)
        {
            immutable r = table[i];
            if (r == none)
                return none;
            if (row(r) == tuple)
                return r;
        }
    }

    /// Adds `tuple` unless present; returns whether it was new. The new row
    /// is not visible through the indexes until `syncIndexes`.
    bool insert(scope const(uint)[] tuple) @safe pure nothrow
    in (tuple.length == arity)
    {
        immutable h = hashRow(tuple);
        immutable m = table.length - 1;
        size_t i = h & m;
        for (;; i = (i + 1) & m)
        {
            immutable r = table[i];
            if (r == none)
                break;
            if (row(r) == tuple)
                return false;
        }
        table[i] = cast(uint) count;
        data ~= tuple;
        ++count;
        if (count * 2 > table.length)
            growTable();
        return true;
    }

    private void growTable() @safe pure nothrow
    {
        auto bigger = new uint[table.length * 2];
        bigger[] = none;
        immutable m = bigger.length - 1;
        foreach (r; 0 .. count)
        {
            size_t i = hashRow(row(r)) & m;
            while (bigger[i] != none)
                i = (i + 1) & m;
            bigger[i] = cast(uint) r;
        }
        table = bigger;
    }

    /// Number (position in `indexes`) of the index on the columns in `mask`,
    /// creating it if needed. `mask` must not be 0.
    size_t indexFor(uint mask) @safe pure nothrow
    in (mask != 0)
    {
        foreach (i, ref ix; indexes)
            if (ix.mask == mask)
                return i;
        Index ix;
        ix.mask = mask;
        foreach (c; 0 .. arity)
            if (mask & (1u << c))
                ix.cols ~= cast(ubyte) c;
        ix.heads = new uint[16];
        ix.heads[] = none;
        indexes ~= ix;
        return indexes.length - 1;
    }

    /// Hash of the key columns of row `r` in index `ix`.
    ulong keyHash(ref const Index ix, size_t r) const @safe pure nothrow @nogc
    {
        ulong h = hashSeed;
        immutable base = r * arity;
        foreach (c; ix.cols)
            h = mixHash(h, data[base + c]);
        return h;
    }

    /// Adds all rows not yet indexed to every index.
    void syncIndexes() @safe pure nothrow
    {
        foreach (ref ix; indexes)
        {
            if (ix.indexed == count)
                continue;
            if (ix.next.length < count)
                ix.next.length = count > ix.next.length * 2 ? count : ix.next.length * 2;
            if (count > ix.heads.length)
            {
                size_t buckets = ix.heads.length;
                while (buckets < count)
                    buckets *= 2;
                ix.heads = new uint[buckets];
                ix.heads[] = none;
                ix.indexed = 0; // rebuild: every row is re-chained below
            }
            immutable m = ix.heads.length - 1;
            foreach (r; ix.indexed .. count)
            {
                immutable b = keyHash(ix, r) & m;
                ix.next[r] = ix.heads[b];
                ix.heads[b] = cast(uint) r;
            }
            ix.indexed = count;
        }
    }
}

@safe pure unittest
{
    auto r = new Relation(2);
    assert(r.insert([1, 2]));
    assert(r.insert([2, 3]));
    assert(!r.insert([1, 2]));
    assert(r.count == 2);
    assert(r.contains([2, 3]) && !r.contains([3, 2]));
    assert(r.row(1) == [2, 3]);
}

@safe pure unittest
{
    // The membership table survives growth.
    auto r = new Relation(2);
    foreach (i; 0 .. 1000)
        assert(r.insert([i, i * 7]));
    foreach (i; 0 .. 1000)
    {
        assert(!r.insert([i, i * 7]));
        assert(r.contains([i, i * 7]));
    }
    assert(!r.contains([1, 1]));
    assert(r.count == 1000);
}

@safe pure unittest
{
    // An index finds all rows with a key, also across growth and incremental syncs.
    auto r = new Relation(2);
    immutable ix = r.indexFor(0b01);
    assert(r.indexFor(0b01) == ix);
    foreach (i; 0 .. 100)
        r.insert([i % 10, i]);
    r.syncIndexes();
    foreach (i; 100 .. 5000)
        r.insert([i % 10, i]);
    r.syncIndexes();
    r.syncIndexes(); // idempotent

    size_t found;
    ulong h = mixHash(hashSeed, 3);
    auto index = &r.indexes[ix];
    for (auto row = index.heads[h & (index.heads.length - 1)]; row != none; row = index.next[row])
        if (r.row(row)[0] == 3)
            ++found;
    assert(found == 500);
}
