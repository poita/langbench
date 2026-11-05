/**
 * Size-augmented AVL tree keyed by `long`.
 *
 * Nodes live in one contiguous pool addressed by 32-bit indices; index 0 is a
 * nil sentinel with height 0 and size 0, so child arithmetic never needs null
 * checks. Values are stored as slices that refer to caller-owned memory; the
 * map never copies value bytes, so the referenced memory must outlive the map
 * (or the entry).
 */
module orderedmap.tree;

/// Node-pool index. 0 is the nil sentinel.
alias NodeId = uint;

private struct Node
{
    long key;
    const(char)[] value;
    NodeId left;
    NodeId right;
    uint size;
    ubyte height;
}

/**
 * An ordered map from `long` keys to `const(char)[]` values.
 *
 * Insert and remove are single recursive descents that rebalance on the way
 * back up; all queries are iterative root-to-leaf walks and allocate nothing.
 */
struct OrderedMap
{
    private Node[] nodes;        // nodes[0] is the nil sentinel
    private NodeId root;
    private NodeId freeList;     // singly linked through Node.left
    private size_t used = 1;     // slots handed out so far, including sentinel

    @disable this(this);

    /// Creates a map with room for `capacity` keys before any reallocation.
    this(size_t capacity) @safe pure nothrow
    {
        reserve(capacity);
    }

    /// Ensures the pool can hold `capacity` live keys without reallocating.
    void reserve(size_t capacity) @safe pure nothrow
    {
        ensurePool();
        if (nodes.length < capacity + 1)
            nodes.length = capacity + 1;
    }

    /// Number of keys in the map.
    size_t length() const @safe pure nothrow @nogc
    {
        return nodes.length ? nodes[root].size : 0;
    }

    /// True if the map holds no keys.
    bool empty() const @safe pure nothrow @nogc
    {
        return length == 0;
    }

    /**
     * Associates `value` with `key`.
     * Returns: `true` if the key was new, `false` if an existing value was replaced.
     */
    bool insert(long key, const(char)[] value) @safe pure nothrow
    {
        ensurePool();
        bool added;
        const r = insertAt(root, key, value, added);
        root = r;
        return added;
    }

    /**
     * Removes `key`.
     * Returns: `true` if the key was present.
     */
    bool remove(long key) @safe pure nothrow
    {
        if (nodes.length == 0)
            return false;
        bool removed;
        const r = removeAt(root, key, removed);
        root = r;
        return removed;
    }

    /// Looks up `key`; on success stores its value in `value`.
    bool get(long key, out const(char)[] value) const @safe pure nothrow @nogc
    {
        if (nodes.length == 0)
            return false;
        NodeId n = root;
        while (n)
        {
            const k = nodes[n].key;
            if (key == k)
            {
                value = nodes[n].value;
                return true;
            }
            n = key < k ? nodes[n].left : nodes[n].right;
        }
        return false;
    }

    /// True if `key` is present.
    bool contains(long key) const @safe pure nothrow @nogc
    {
        const(char)[] ignored;
        return get(key, ignored);
    }

    /// Smallest key. Returns `false` (leaving `key` untouched) if empty.
    bool min(out long key) const @safe pure nothrow @nogc
    {
        if (empty)
            return false;
        NodeId n = root;
        while (nodes[n].left)
            n = nodes[n].left;
        key = nodes[n].key;
        return true;
    }

    /// Largest key. Returns `false` if empty.
    bool max(out long key) const @safe pure nothrow @nogc
    {
        if (empty)
            return false;
        NodeId n = root;
        while (nodes[n].right)
            n = nodes[n].right;
        key = nodes[n].key;
        return true;
    }

    /// Largest key ≤ `key`.
    bool floor(long key, out long result) const @safe pure nothrow @nogc
    {
        return lowerSide!true(key, result);
    }

    /// Largest key < `key`.
    bool pred(long key, out long result) const @safe pure nothrow @nogc
    {
        return lowerSide!false(key, result);
    }

    /// Smallest key ≥ `key`.
    bool ceil(long key, out long result) const @safe pure nothrow @nogc
    {
        return upperSide!true(key, result);
    }

    /// Smallest key > `key`.
    bool succ(long key, out long result) const @safe pure nothrow @nogc
    {
        return upperSide!false(key, result);
    }

    /// Number of keys strictly less than `key` (`key` need not be present).
    size_t rank(long key) const @safe pure nothrow @nogc
    {
        if (empty)
            return 0;
        size_t r = 0;
        NodeId n = root;
        while (n)
        {
            if (key > nodes[n].key)
            {
                r += nodes[nodes[n].left].size + 1;
                n = nodes[n].right;
            }
            else
                n = nodes[n].left;
        }
        return r;
    }

    /// The `k`-th smallest key (0-based). Returns `false` if `k >= length`.
    bool select(ulong k, out long key) const @safe pure nothrow @nogc
    {
        if (k >= length)
            return false;
        NodeId n = root;
        while (true)
        {
            const ls = nodes[nodes[n].left].size;
            if (k < ls)
                n = nodes[n].left;
            else if (k == ls)
            {
                key = nodes[n].key;
                return true;
            }
            else
            {
                k -= ls + 1;
                n = nodes[n].right;
            }
        }
    }

    /**
     * Calls `sink.put(key)` for every key in `[lo, hi]` in ascending order.
     * Runs in $(I O(log n + r)); does nothing when `lo > hi`.
     */
    void range(Sink)(long lo, long hi, ref Sink sink) const
    {
        if (lo > hi || empty)
            return;
        walkRange(root, lo, hi, sink);
    }

    /// All keys in `[lo, hi]`, ascending, as a freshly allocated array.
    long[] keysInRange(long lo, long hi) const @safe pure nothrow
    {
        static struct Collector
        {
            long[] keys;
            void put(long k) @safe pure nothrow { keys ~= k; }
        }
        Collector c;
        range(lo, hi, c);
        return c.keys;
    }

    /// Height of the tree (0 when empty); exposed for balance checks in tests.
    size_t height() const @safe pure nothrow @nogc
    {
        return nodes.length ? nodes[root].height : 0;
    }

    /// Verifies BST order, AVL balance, heights and sizes. For tests.
    bool checkInvariants() const @safe pure nothrow
    {
        if (nodes.length == 0)
            return true;
        if (nodes[0].size != 0 || nodes[0].height != 0)
            return false;
        return checkAt(root);
    }

private:

    void ensurePool() @safe pure nothrow
    {
        if (nodes.length == 0)
            nodes.length = 16;
    }

    NodeId allocNode(long key, const(char)[] value) @safe pure nothrow
    {
        NodeId id;
        if (freeList)
        {
            id = freeList;
            freeList = nodes[id].left;
        }
        else
        {
            if (used == nodes.length)
                nodes.length = nodes.length * 2;
            id = cast(NodeId) used++;
        }
        nodes[id] = Node(key, value, 0, 0, 1, 1);
        return id;
    }

    void freeNode(NodeId id) @safe pure nothrow @nogc
    {
        nodes[id].left = freeList;
        freeList = id;
    }

    void update(NodeId n) @safe pure nothrow @nogc
    {
        const l = nodes[n].left, r = nodes[n].right;
        const hl = nodes[l].height, hr = nodes[r].height;
        nodes[n].height = cast(ubyte)((hl > hr ? hl : hr) + 1);
        nodes[n].size = nodes[l].size + nodes[r].size + 1;
    }

    NodeId rotateRight(NodeId n) @safe pure nothrow @nogc
    {
        const l = nodes[n].left;
        nodes[n].left = nodes[l].right;
        nodes[l].right = n;
        update(n);
        update(l);
        return l;
    }

    NodeId rotateLeft(NodeId n) @safe pure nothrow @nogc
    {
        const r = nodes[n].right;
        nodes[n].right = nodes[r].left;
        nodes[r].left = n;
        update(n);
        update(r);
        return r;
    }

    /// Recomputes `n`'s metadata and restores the AVL property at `n`.
    NodeId rebalance(NodeId n) @safe pure nothrow @nogc
    {
        update(n);
        const bf = cast(int) nodes[nodes[n].left].height - nodes[nodes[n].right].height;
        if (bf > 1)
        {
            const l = nodes[n].left;
            if (nodes[nodes[l].left].height < nodes[nodes[l].right].height)
                nodes[n].left = rotateLeft(l);
            return rotateRight(n);
        }
        if (bf < -1)
        {
            const r = nodes[n].right;
            if (nodes[nodes[r].right].height < nodes[nodes[r].left].height)
                nodes[n].right = rotateRight(r);
            return rotateLeft(n);
        }
        return n;
    }

    NodeId insertAt(NodeId n, long key, const(char)[] value, ref bool added)
        @safe pure nothrow
    {
        if (n == 0)
        {
            added = true;
            return allocNode(key, value);
        }
        const k = nodes[n].key;
        if (key == k)
        {
            nodes[n].value = value;   // update only: no rebalancing needed
            return n;
        }
        if (key < k)
        {
            const c = insertAt(nodes[n].left, key, value, added);
            nodes[n].left = c;
        }
        else
        {
            const c = insertAt(nodes[n].right, key, value, added);
            nodes[n].right = c;
        }
        return added ? rebalance(n) : n;
    }

    /// Detaches the leftmost node of subtree `n`, copying its key/value out.
    NodeId removeMin(NodeId n, ref long key, ref const(char)[] value)
        @safe pure nothrow @nogc
    {
        const l = nodes[n].left;
        if (l == 0)
        {
            key = nodes[n].key;
            value = nodes[n].value;
            const r = nodes[n].right;
            freeNode(n);
            return r;
        }
        const c = removeMin(l, key, value);
        nodes[n].left = c;
        return rebalance(n);
    }

    NodeId removeAt(NodeId n, long key, ref bool removed) @safe pure nothrow @nogc
    {
        if (n == 0)
            return 0;
        const k = nodes[n].key;
        if (key < k)
        {
            const c = removeAt(nodes[n].left, key, removed);
            nodes[n].left = c;
        }
        else if (key > k)
        {
            const c = removeAt(nodes[n].right, key, removed);
            nodes[n].right = c;
        }
        else
        {
            removed = true;
            const l = nodes[n].left, r = nodes[n].right;
            if (l == 0 || r == 0)
            {
                freeNode(n);
                return l ? l : r;
            }
            long sk;
            const(char)[] sv;
            const c = removeMin(r, sk, sv);
            nodes[n].key = sk;
            nodes[n].value = sv;
            nodes[n].right = c;
        }
        return removed ? rebalance(n) : n;
    }

    // Largest key ≤ key (inclusive) or < key (!inclusive).
    bool lowerSide(bool inclusive)(long key, out long result) const @safe pure nothrow @nogc
    {
        if (empty)
            return false;
        bool found;
        NodeId n = root;
        while (n)
        {
            const k = nodes[n].key;
            if (inclusive ? k <= key : k < key)
            {
                result = k;
                found = true;
                n = nodes[n].right;
            }
            else
                n = nodes[n].left;
        }
        return found;
    }

    // Smallest key ≥ key (inclusive) or > key (!inclusive).
    bool upperSide(bool inclusive)(long key, out long result) const @safe pure nothrow @nogc
    {
        if (empty)
            return false;
        bool found;
        NodeId n = root;
        while (n)
        {
            const k = nodes[n].key;
            if (inclusive ? k >= key : k > key)
            {
                result = k;
                found = true;
                n = nodes[n].left;
            }
            else
                n = nodes[n].right;
        }
        return found;
    }

    void walkRange(Sink)(NodeId n, long lo, long hi, ref Sink sink) const
    {
        while (n)
        {
            const k = nodes[n].key;
            if (k > lo)
                walkRange(nodes[n].left, lo, hi, sink);
            if (k >= lo && k <= hi)
                sink.put(k);
            if (k >= hi)
                return;
            n = nodes[n].right;
        }
    }

    bool checkAt(NodeId n) const @safe pure nothrow
    {
        if (n == 0)
            return true;
        const nd = nodes[n];
        if (!checkAt(nd.left) || !checkAt(nd.right))
            return false;
        if (nd.left && maxOf(nd.left) >= nd.key)
            return false;
        if (nd.right && minOf(nd.right) <= nd.key)
            return false;
        const hl = nodes[nd.left].height, hr = nodes[nd.right].height;
        if (nd.height != (hl > hr ? hl : hr) + 1)
            return false;
        if (hl > hr + 1 || hr > hl + 1)
            return false;
        return nd.size == nodes[nd.left].size + nodes[nd.right].size + 1;
    }

    long minOf(NodeId n) const @safe pure nothrow @nogc
    {
        while (nodes[n].left)
            n = nodes[n].left;
        return nodes[n].key;
    }

    long maxOf(NodeId n) const @safe pure nothrow @nogc
    {
        while (nodes[n].right)
            n = nodes[n].right;
        return nodes[n].key;
    }
}
