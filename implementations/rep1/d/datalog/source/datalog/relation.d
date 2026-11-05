/// Relations: append-only tuple storage with a hash set and lazily built hash indexes.
module datalog.relation;

/// A constant id (rank in the total order of constants).
alias Value = uint;

/// Sentinel position meaning "none".
enum uint noPos = uint.max;

private enum ulong mixMul = 0x9E3779B97F4A7C15UL;

/// Hash a sequence of values.
size_t hashValues(const(Value)[] values) pure nothrow @nogc @safe
{
    ulong h = 0x243F6A8885A308D3UL;
    foreach (v; values)
        h = (h ^ v) * mixMul;
    return cast(size_t)(h ^ (h >> 32));
}

private size_t hashColumns(const(Value)[] tuple, const(uint)[] columns) pure nothrow @nogc @safe
{
    ulong h = 0x243F6A8885A308D3UL;
    foreach (c; columns)
        h = (h ^ tuple[c]) * mixMul;
    return cast(size_t)(h ^ (h >> 32));
}

/// A set of tuples of fixed arity, stored contiguously in insertion order.
///
/// A tuple's position is stable, so "the tuples added since position `k`" is
/// the position range `[k, length)`. Membership is answered by an open
/// addressing hash set over the tuple positions.
final class Relation
{
    /// Number of components of each tuple.
    immutable uint arity;
    /// Flat tuple storage, `arity` values per tuple.
    Value[] data;

    private size_t count;
    private uint[] slots;
    private size_t slotMask;
    private Index[] indexes;

    this(uint arity) pure nothrow @safe
    {
        this.arity = arity;
        slots = new uint[16];
        slots[] = noPos;
        slotMask = 15;
    }

    /// Number of tuples.
    size_t length() const pure nothrow @nogc @safe
    {
        return count;
    }

    /// The tuple at position `pos`.
    const(Value)[] opIndex(size_t pos) const pure nothrow @nogc @safe
    {
        return data[pos * arity .. (pos + 1) * arity];
    }

    /// Is `tuple` in the relation?
    bool contains(const(Value)[] tuple) const pure nothrow @nogc @safe
    {
        size_t i = hashValues(tuple) & slotMask;
        while (true)
        {
            immutable s = slots[i];
            if (s == noPos)
                return false;
            if (this[s] == tuple)
                return true;
            i = (i + 1) & slotMask;
        }
    }

    /// Add `tuple`; returns false if it was already present.
    bool insert(const(Value)[] tuple) nothrow @safe
    {
        assert(tuple.length == arity);
        if ((count + 1) * 2 > slots.length)
            grow();
        size_t i = hashValues(tuple) & slotMask;
        while (true)
        {
            immutable s = slots[i];
            if (s == noPos)
                break;
            if (this[s] == tuple)
                return false;
            i = (i + 1) & slotMask;
        }
        slots[i] = cast(uint) count;
        data ~= tuple;
        ++count;
        return true;
    }

    /// Get (creating if needed) the index keyed on the argument positions in
    /// `keyMask` (bit `i` set = position `i` is part of the key).
    Index index(uint keyMask) nothrow @safe
    {
        if (auto idx = findIndex(keyMask))
            return idx;
        auto idx = new Index(this, keyMask);
        indexes ~= idx;
        return idx;
    }

    /// The index for `keyMask` if it exists, else null.
    Index findIndex(uint keyMask) pure nothrow @nogc @safe
    {
        foreach (idx; indexes)
            if (idx.keyMask == keyMask)
                return idx;
        return null;
    }

private:
    void grow() nothrow @safe
    {
        auto newSlots = new uint[slots.length * 2];
        newSlots[] = noPos;
        immutable newMask = newSlots.length - 1;
        foreach (p; 0 .. count)
        {
            size_t i = hashValues(this[p]) & newMask;
            while (newSlots[i] != noPos)
                i = (i + 1) & newMask;
            newSlots[i] = cast(uint) p;
        }
        slots = newSlots;
        slotMask = newMask;
    }
}

/// A hash index over a subset of a relation's argument positions.
///
/// Maps a key (the values at the key positions) to the ascending chain of
/// positions of matching tuples. The index is extended incrementally with
/// `update`; it is never rebuilt and must not be updated during a join.
final class Index
{
    /// The indexed relation.
    Relation relation;
    /// Bit set of key positions.
    immutable uint keyMask;
    /// Key positions in ascending order.
    immutable(uint)[] columns;
    /// `next[p]` is the next position in `p`'s chain (`noPos` at the end).
    uint[] next;

    private static struct Entry
    {
        uint head = noPos;
        uint tail = noPos;
    }

    private Entry[] table;
    private size_t used;
    private size_t indexed;

    this(Relation relation, uint keyMask) nothrow @safe
    {
        this.relation = relation;
        this.keyMask = keyMask;
        uint[] cols;
        foreach (i; 0 .. relation.arity)
            if (keyMask & (1u << i))
                cols ~= i;
        columns = cols.idup;
        table = new Entry[16];
    }

    /// Index every tuple appended to the relation since the last call.
    void update() nothrow @safe
    {
        immutable n = relation.length;
        if (indexed == n)
            return;
        if (next.length < n)
            next.length = n > 2 * next.length ? n : 2 * next.length;
        foreach (p; indexed .. n)
            add(cast(uint) p);
        indexed = n;
    }

    /// First position whose key equals `key` (given in column order), or `noPos`.
    uint first(const(Value)[] key) const pure nothrow @nogc @safe
    {
        immutable mask = table.length - 1;
        size_t i = hashValues(key) & mask;
        while (true)
        {
            immutable head = table[i].head;
            if (head == noPos)
                return noPos;
            if (keyMatches(relation[head], key))
                return head;
            i = (i + 1) & mask;
        }
    }

private:
    bool keyMatches(const(Value)[] tuple, const(Value)[] key) const pure nothrow @nogc @safe
    {
        foreach (j, c; columns)
            if (tuple[c] != key[j])
                return false;
        return true;
    }

    bool sameKey(const(Value)[] a, const(Value)[] b) const pure nothrow @nogc @safe
    {
        foreach (c; columns)
            if (a[c] != b[c])
                return false;
        return true;
    }

    void add(uint p) nothrow @safe
    {
        if ((used + 1) * 2 > table.length)
            grow();
        immutable mask = table.length - 1;
        auto t = relation[p];
        size_t i = hashColumns(t, columns) & mask;
        next[p] = noPos;
        while (true)
        {
            if (table[i].head == noPos)
            {
                table[i] = Entry(p, p);
                ++used;
                return;
            }
            if (sameKey(relation[table[i].head], t))
            {
                next[table[i].tail] = p;
                table[i].tail = p;
                return;
            }
            i = (i + 1) & mask;
        }
    }

    void grow() nothrow @safe
    {
        auto newTable = new Entry[table.length * 2];
        immutable mask = newTable.length - 1;
        foreach (ref e; table)
        {
            if (e.head == noPos)
                continue;
            size_t i = hashColumns(relation[e.head], columns) & mask;
            while (newTable[i].head != noPos)
                i = (i + 1) & mask;
            newTable[i] = e;
        }
        table = newTable;
    }
}
