/**
 * An ordered map implemented as an AVL tree augmented with subtree sizes.
 *
 * Every operation – insert, remove, lookup, neighbour queries, rank and select –
 * costs $(I O(log n)); listing a key range costs $(I O(log n + r)) for $(I r)
 * reported entries.
 *
 * Nodes live in one contiguous array and refer to each other by index (index
 * `0` is the "nil" node), so the map does not allocate per node, and removed
 * nodes are recycled through a free list.
 */
module orderedmap.tree;

import std.typecons : Nullable;

/**
 * An ordered map from `K` to `V`, keys compared with `<`.
 *
 * The map has value semantics but cannot be copied implicitly; use $(LREF dup).
 *
 * Params:
 *     K = key type; must support `<`
 *     V = value type
 */
struct OrderedMap(K, V)
{
    @disable this(this);

    /// Returns an independent copy of the map.
    OrderedMap dup() const @safe pure nothrow
    {
        OrderedMap r;
        r.nodes = nodes.dup;
        r.root = root;
        r.freeHead = freeHead;
        r.count = count;
        return r;
    }

    /// Number of entries.
    size_t length() const @safe pure nothrow @nogc { return count; }

    /// `true` if the map has no entries.
    bool empty() const @safe pure nothrow @nogc { return count == 0; }

    /// Removes all entries.
    void clear() @safe pure nothrow
    {
        nodes = null;
        root = 0;
        freeHead = 0;
        count = 0;
    }

    /**
     * Associates `value` with `key`.
     *
     * Returns: `true` if `key` was newly added, `false` if an existing value
     * was replaced.
     */
    bool insert(K key, V value) @safe pure nothrow
    {
        if (nodes.length == 0)
            nodes ~= Node.init; // slot 0: the nil node (height 0, size 0)
        bool added;
        immutable newRoot = insertAt(root, key, value, added);
        root = newRoot;
        if (added)
            ++count;
        return added;
    }

    /**
     * Removes `key`.
     *
     * Returns: `true` if the key was present.
     */
    bool remove(K key) @safe pure nothrow
    {
        bool removed;
        immutable newRoot = removeAt(root, key, removed);
        root = newRoot;
        if (removed)
            --count;
        return removed;
    }

    /// Returns a pointer to the value stored under `key`, or `null`.
    inout(V)* opBinaryRight(string op : "in")(K key) inout @safe pure nothrow @nogc
    {
        int n = root;
        while (n)
        {
            if (key < nodes[n].key)
                n = nodes[n].left;
            else if (nodes[n].key < key)
                n = nodes[n].right;
            else
                return &nodes[n].value;
        }
        return null;
    }

    /// `true` if `key` is present.
    bool contains(K key) const @safe pure nothrow @nogc { return (key in this) !is null; }

    /// Returns the value for `key`; asserts if it is absent.
    ref inout(V) opIndex(K key) inout @safe pure nothrow @nogc
    {
        auto p = key in this;
        assert(p !is null, "key not present");
        return *p;
    }

    /// Assigns `value` to `key` (same as $(LREF insert)).
    void opIndexAssign(V value, K key) @safe pure nothrow { insert(key, value); }

    /// Smallest key, or null if the map is empty.
    Nullable!K minKey() const @safe pure nothrow @nogc
    {
        Nullable!K r;
        int n = root;
        while (n)
        {
            r = nodes[n].key;
            n = nodes[n].left;
        }
        return r;
    }

    /// Largest key, or null if the map is empty.
    Nullable!K maxKey() const @safe pure nothrow @nogc
    {
        Nullable!K r;
        int n = root;
        while (n)
        {
            r = nodes[n].key;
            n = nodes[n].right;
        }
        return r;
    }

    /// Largest key `<= key`, or null.
    Nullable!K floor(K key) const @safe pure nothrow @nogc
    {
        Nullable!K r;
        int n = root;
        while (n)
        {
            if (key < nodes[n].key)
                n = nodes[n].left;
            else
            {
                r = nodes[n].key;
                n = nodes[n].right;
            }
        }
        return r;
    }

    /// Smallest key `>= key`, or null.
    Nullable!K ceil(K key) const @safe pure nothrow @nogc
    {
        Nullable!K r;
        int n = root;
        while (n)
        {
            if (nodes[n].key < key)
                n = nodes[n].right;
            else
            {
                r = nodes[n].key;
                n = nodes[n].left;
            }
        }
        return r;
    }

    /// Smallest key strictly greater than `key`, or null. Never overflows.
    Nullable!K successor(K key) const @safe pure nothrow @nogc
    {
        Nullable!K r;
        int n = root;
        while (n)
        {
            if (key < nodes[n].key)
            {
                r = nodes[n].key;
                n = nodes[n].left;
            }
            else
                n = nodes[n].right;
        }
        return r;
    }

    /// Largest key strictly less than `key`, or null. Never overflows.
    Nullable!K predecessor(K key) const @safe pure nothrow @nogc
    {
        Nullable!K r;
        int n = root;
        while (n)
        {
            if (nodes[n].key < key)
            {
                r = nodes[n].key;
                n = nodes[n].right;
            }
            else
                n = nodes[n].left;
        }
        return r;
    }

    /// Number of keys strictly less than `key` (`key` need not be present).
    size_t rank(K key) const @safe pure nothrow @nogc
    {
        size_t r = 0;
        int n = root;
        while (n)
        {
            if (nodes[n].key < key)
            {
                r += sizeOf(nodes[n].left) + 1;
                n = nodes[n].right;
            }
            else
                n = nodes[n].left;
        }
        return r;
    }

    /// The `k`-th smallest key (0-based), or null if `k >= length`.
    Nullable!K select(size_t k) const @safe pure nothrow @nogc
    {
        Nullable!K r;
        if (k >= count)
            return r;
        int n = root;
        while (n)
        {
            immutable l = sizeOf(nodes[n].left);
            if (k < l)
                n = nodes[n].left;
            else if (k == l)
            {
                r = nodes[n].key;
                break;
            }
            else
            {
                k -= l + 1;
                n = nodes[n].right;
            }
        }
        return r;
    }

    /**
     * Calls `fn(key, value)` (both passed by value) for every entry with `lo <= key <= hi`, in
     * ascending key order. Visits only the part of the tree that can overlap
     * the range: $(I O(log n + r)).
     *
     * `fn` must not modify the map.
     */
    void forEachInRange(Fn)(K lo, K hi, scope Fn fn) const
    {
        if (hi < lo)
            return;
        walkRange(root, lo, hi, fn);
    }

    /// Calls `fn(key, value)` for every entry in ascending key order.
    void forEach(Fn)(scope Fn fn) const
    {
        walkAll(root, fn);
    }

    /// Verifies the BST, AVL-balance and size invariants (for testing).
    bool validate() const @safe pure nothrow
    {
        size_t seen;
        bool ok = true;
        checkNode(root, seen, ok);
        // Every node is either live or on the free list.
        return ok && seen == count && (root == 0 ? count == 0 : sizeOf(root) == count);
    }

private:
    struct Node
    {
        K key;
        V value;
        int left, right; // child indices; 0 == none (also reused as free-list link)
        int height;      // height of the subtree rooted here (nil == 0)
        int size;        // number of entries in the subtree (nil == 0)
    }

    Node[] nodes;
    int root;
    int freeHead; // head of the free list (0 == empty)
    size_t count;

    size_t sizeOf(int n) const @safe pure nothrow @nogc { return nodes[n].size; }

    int alloc(K key, V value) @safe pure nothrow
    {
        int n;
        if (freeHead)
        {
            n = freeHead;
            freeHead = nodes[n].left;
        }
        else
        {
            n = cast(int) nodes.length;
            nodes ~= Node.init;
        }
        nodes[n] = Node(key, value, 0, 0, 1, 1);
        return n;
    }

    void release(int n) @safe pure nothrow
    {
        nodes[n] = Node.init;
        nodes[n].left = freeHead;
        freeHead = n;
    }

    void update(int n) @safe pure nothrow @nogc
    {
        immutable l = nodes[n].left, r = nodes[n].right;
        immutable hl = nodes[l].height, hr = nodes[r].height;
        nodes[n].height = (hl > hr ? hl : hr) + 1;
        nodes[n].size = nodes[l].size + nodes[r].size + 1;
    }

    int rotateRight(int n) @safe pure nothrow @nogc
    {
        immutable l = nodes[n].left;
        nodes[n].left = nodes[l].right;
        nodes[l].right = n;
        update(n);
        update(l);
        return l;
    }

    int rotateLeft(int n) @safe pure nothrow @nogc
    {
        immutable r = nodes[n].right;
        nodes[n].right = nodes[r].left;
        nodes[r].left = n;
        update(n);
        update(r);
        return r;
    }

    /// Recomputes `n`'s metadata and restores the AVL property; returns the new subtree root.
    int rebalance(int n) @safe pure nothrow @nogc
    {
        update(n);
        immutable bf = nodes[nodes[n].left].height - nodes[nodes[n].right].height;
        if (bf > 1)
        {
            immutable l = nodes[n].left;
            if (nodes[nodes[l].left].height < nodes[nodes[l].right].height)
                nodes[n].left = rotateLeft(l);
            return rotateRight(n);
        }
        if (bf < -1)
        {
            immutable r = nodes[n].right;
            if (nodes[nodes[r].right].height < nodes[nodes[r].left].height)
                nodes[n].right = rotateRight(r);
            return rotateLeft(n);
        }
        return n;
    }

    int insertAt(int n, K key, V value, ref bool added) @safe pure nothrow
    {
        if (n == 0)
        {
            added = true;
            return alloc(key, value);
        }
        if (key < nodes[n].key)
        {
            immutable c = insertAt(nodes[n].left, key, value, added);
            nodes[n].left = c;
        }
        else if (nodes[n].key < key)
        {
            immutable c = insertAt(nodes[n].right, key, value, added);
            nodes[n].right = c;
        }
        else
        {
            nodes[n].value = value;
            return n;
        }
        return added ? rebalance(n) : n;
    }

    /// Detaches the minimum node of subtree `n` into `minNode`; returns the new subtree root.
    int removeMin(int n, ref int minNode) @safe pure nothrow @nogc
    {
        if (nodes[n].left == 0)
        {
            minNode = n;
            return nodes[n].right;
        }
        immutable c = removeMin(nodes[n].left, minNode);
        nodes[n].left = c;
        return rebalance(n);
    }

    int removeAt(int n, K key, ref bool removed) @safe pure nothrow
    {
        if (n == 0)
            return 0;
        if (key < nodes[n].key)
        {
            immutable c = removeAt(nodes[n].left, key, removed);
            nodes[n].left = c;
        }
        else if (nodes[n].key < key)
        {
            immutable c = removeAt(nodes[n].right, key, removed);
            nodes[n].right = c;
        }
        else
        {
            removed = true;
            immutable l = nodes[n].left, r = nodes[n].right;
            int replacement;
            if (l == 0 || r == 0)
                replacement = l ? l : r;
            else
            {
                int m;
                immutable newRight = removeMin(r, m);
                nodes[m].left = l;
                nodes[m].right = newRight;
                replacement = rebalance(m);
            }
            release(n);
            return replacement;
        }
        return removed ? rebalance(n) : n;
    }

    void walkRange(Fn)(int n, K lo, K hi, ref Fn fn) const
    {
        while (n)
        {
            if (nodes[n].key < lo)
            {
                n = nodes[n].right; // whole left subtree is < lo
                continue;
            }
            if (lo < nodes[n].key)
                walkRange(nodes[n].left, lo, hi, fn);
            if (hi < nodes[n].key)
                return; // this node and everything to its right is > hi
            fn(nodes[n].key, nodes[n].value);
            n = nodes[n].right;
        }
    }

    void walkAll(Fn)(int n, ref Fn fn) const
    {
        while (n)
        {
            walkAll(nodes[n].left, fn);
            fn(nodes[n].key, nodes[n].value);
            n = nodes[n].right;
        }
    }

    void checkNode(int n, ref size_t seen, ref bool ok) const @safe pure nothrow
    {
        if (n == 0)
            return;
        immutable l = nodes[n].left, r = nodes[n].right;
        checkNode(l, seen, ok);
        ++seen;
        checkNode(r, seen, ok);
        if (l && !(nodes[l].key < nodes[n].key)) ok = false;
        if (r && !(nodes[n].key < nodes[r].key)) ok = false;
        immutable hl = nodes[l].height, hr = nodes[r].height;
        if (nodes[n].height != (hl > hr ? hl : hr) + 1) ok = false;
        if (hl - hr > 1 || hr - hl > 1) ok = false;
        if (nodes[n].size != nodes[l].size + nodes[r].size + 1) ok = false;
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

version (unittest)
{
    import std.algorithm : sort, map;
    import std.array : array;
    import std.random : Random, uniform;
    import std.range : iota;
}

@("empty map")
unittest
{
    OrderedMap!(long, string) m;
    assert(m.empty && m.length == 0);
    assert(m.minKey.isNull && m.maxKey.isNull);
    assert(m.floor(0).isNull && m.ceil(0).isNull);
    assert(m.successor(0).isNull && m.predecessor(0).isNull);
    assert(m.rank(5) == 0);
    assert(m.select(0).isNull);
    assert(!m.remove(1));
    assert(1 !in m);
    int calls;
    m.forEachInRange(long.min, long.max, (long k, string v) { ++calls; });
    assert(calls == 0);
    assert(m.validate);
}

@("insert, update, lookup, remove")
unittest
{
    OrderedMap!(long, string) m;
    assert(m.insert(5, "five"));
    assert(!m.insert(5, "FIVE"));
    assert(m[5] == "FIVE");
    assert(m.length == 1);
    m[2] = "two";
    assert(2 in m && *(2 in m) == "two");
    assert(m.remove(5));
    assert(!m.remove(5));
    assert(!m.contains(5) && m.contains(2));
    assert(m.validate);
}

@("neighbour queries, rank and select")
unittest
{
    OrderedMap!(long, string) m;
    foreach (k; [10L, 20, 30])
        m.insert(k, "v");
    assert(m.floor(25).get == 20 && m.ceil(25).get == 30);
    assert(m.floor(10).get == 10 && m.ceil(10).get == 10);
    assert(m.floor(9).isNull && m.ceil(31).isNull);
    assert(m.successor(10).get == 20 && m.predecessor(10).isNull);
    assert(m.successor(30).isNull && m.predecessor(30).get == 20);
    assert(m.rank(20) == 1 && m.rank(21) == 2 && m.rank(5) == 0 && m.rank(99) == 3);
    assert(m.select(2).get == 30 && m.select(3).isNull);
    assert(m.minKey.get == 10 && m.maxKey.get == 30);
}

@("extreme keys do not overflow")
unittest
{
    OrderedMap!(long, string) m;
    m.insert(long.min, "lo");
    m.insert(long.max, "hi");
    m.insert(0, "zero");
    assert(m.successor(long.max).isNull);
    assert(m.predecessor(long.min).isNull);
    assert(m.successor(long.min).get == 0);
    assert(m.predecessor(long.max).get == 0);
    assert(m.floor(long.min + 1).get == long.min);
    assert(m.ceil(1).get == long.max);
    assert(m.rank(long.max) == 2);
    long[] got;
    m.forEachInRange(long.min, long.max, (long k, string v) { got ~= k; });
    assert(got == [long.min, 0, long.max]);
}

@("range queries")
unittest
{
    OrderedMap!(long, string) m;
    foreach (k; 0 .. 50)
        m.insert(k * 2, "v");
    long[] got;
    m.forEachInRange(11, 20, (long k, string v) { got ~= k; });
    assert(got == [12L, 14, 16, 18, 20]);
    got = null;
    m.forEachInRange(20, 11, (long k, string v) { got ~= k; });
    assert(got.length == 0);
    got = null;
    m.forEachInRange(21, 21, (long k, string v) { got ~= k; });
    assert(got.length == 0);
}

@("sorted insertion and descending deletion stay balanced")
unittest
{
    enum N = 100_000;
    OrderedMap!(long, string) m;
    foreach (i; 0 .. N)
        m.insert(i, "x");
    assert(m.length == N && m.validate);
    assert(m.rank(N / 2) == N / 2 && m.select(N / 2).get == N / 2);
    foreach_reverse (i; 0 .. N)
    {
        assert(m.remove(i));
        if (i % 10_000 == 0)
            assert(m.validate);
    }
    assert(m.empty && m.validate);
    // Slots are recycled after removal.
    foreach (i; 0 .. 10)
        m.insert(i, "y");
    assert(m.length == 10 && m.validate);
}

@("randomised comparison against a sorted array")
unittest
{
    auto rng = Random(12345);
    OrderedMap!(long, string) m;
    long[] ref_; // sorted
    string[long] vals;

    size_t lowerBound(long k)
    {
        size_t i = 0;
        while (i < ref_.length && ref_[i] < k)
            ++i;
        return i;
    }

    foreach (step; 0 .. 20_000)
    {
        immutable key = uniform(-200L, 200L, rng);
        immutable op = uniform(0, 8, rng);
        immutable lb = lowerBound(key);
        immutable present = lb < ref_.length && ref_[lb] == key;
        switch (op)
        {
        case 0, 1, 2:
            assert(m.insert(key, "v") == !present);
            if (!present)
                ref_ = ref_[0 .. lb] ~ key ~ ref_[lb .. $];
            break;
        case 3, 4:
            assert(m.remove(key) == present);
            if (present)
                ref_ = ref_[0 .. lb] ~ ref_[lb + 1 .. $];
            break;
        case 5:
            assert(m.rank(key) == lb);
            auto s = m.select(cast(size_t)(key + 200));
            if (key + 200 < ref_.length)
                assert(s.get == ref_[key + 200]);
            else
                assert(s.isNull);
            break;
        default:
            auto f = m.floor(key), c = m.ceil(key), su = m.successor(key), pr = m.predecessor(key);
            immutable ub = present ? lb + 1 : lb;
            assert(c.isNull == (lb == ref_.length) && (c.isNull || c.get == ref_[lb]));
            assert(su.isNull == (ub == ref_.length) && (su.isNull || su.get == ref_[ub]));
            assert(pr.isNull == (lb == 0) && (pr.isNull || pr.get == ref_[lb - 1]));
            if (present)
                assert(f.get == key);
            else
                assert(f.isNull == (lb == 0) && (f.isNull || f.get == ref_[lb - 1]));
            long[] got;
            m.forEachInRange(key, key + 30, (long k, string v) { got ~= k; });
            long[] want;
            foreach (x; ref_)
                if (x >= key && x <= key + 30)
                    want ~= x;
            assert(got == want);
            break;
        }
        assert(m.length == ref_.length);
        if (step % 500 == 0)
            assert(m.validate);
    }
    assert(m.validate);
}

@("dup is independent")
unittest
{
    OrderedMap!(long, string) a;
    a.insert(1, "a");
    auto b = a.dup;
    b.insert(2, "b");
    assert(a.length == 1 && b.length == 2);
}
