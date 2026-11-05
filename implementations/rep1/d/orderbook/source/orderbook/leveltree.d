/++
`LevelTree`: an array-backed segment tree over one side's price levels.

Each node stores the sum of the resting quantity and the number of non-empty
levels below it. All operations are O(log P) where P is the number of leaves.
+/
module orderbook.leveltree;

/// Segment tree over `P` level slots (ranks `0 .. P-1`).
struct LevelTree
{
    private long[] sum; // node sums, 1-based heap layout
    private uint[] cnt; // node counts of non-empty leaves
    private size_t size; // number of leaves (power of two, >= 1)

    /// Create a tree with `leaves` slots, all empty.
    this(size_t leaves) @safe pure nothrow
    {
        size = 1;
        while (size < leaves)
            size <<= 1;
        sum = new long[2 * size];
        cnt = new uint[2 * size];
    }

    /// True if no level is non-empty.
    bool empty() const @safe pure nothrow @nogc
    {
        return cnt.length == 0 || cnt[1] == 0;
    }

    /// Total quantity over all levels.
    long total() const @safe pure nothrow @nogc
    {
        return cnt.length == 0 ? 0 : sum[1];
    }

    /++
    Set leaf `rank` to quantity `qty` (non-empty iff `nonEmpty`) and refresh
    the path above it.
    +/
    void set(size_t rank, long qty, bool nonEmpty) @safe pure nothrow @nogc
    {
        size_t i = rank + size;
        sum[i] = qty;
        cnt[i] = nonEmpty ? 1 : 0;
        for (i >>= 1; i >= 1; i >>= 1)
        {
            sum[i] = sum[2 * i] + sum[2 * i + 1];
            cnt[i] = cnt[2 * i] + cnt[2 * i + 1];
        }
    }

    private size_t descendLeft(size_t i) const @safe pure nothrow @nogc
    {
        while (i < size)
            i = cnt[2 * i] != 0 ? 2 * i : 2 * i + 1;
        return i - size;
    }

    private size_t descendRight(size_t i) const @safe pure nothrow @nogc
    {
        while (i < size)
            i = cnt[2 * i + 1] != 0 ? 2 * i + 1 : 2 * i;
        return i - size;
    }

    /// Lowest non-empty rank, or -1 if none.
    long lowest() const @safe pure nothrow @nogc
    {
        if (empty)
            return -1;
        return descendLeft(1);
    }

    /// Highest non-empty rank, or -1 if none.
    long highest() const @safe pure nothrow @nogc
    {
        if (empty)
            return -1;
        return descendRight(1);
    }

    /// Lowest non-empty rank >= `from`, or -1 if none.
    long firstAtOrAfter(size_t from) const @safe pure nothrow @nogc
    {
        if (empty || from >= size)
            return -1;
        size_t i = from + size;
        if (cnt[i] != 0)
            return from;
        for (; i > 1; i >>= 1)
        {
            if ((i & 1) == 0 && cnt[i + 1] != 0)
                return descendLeft(i + 1);
        }
        return -1;
    }

    /// Highest non-empty rank <= `from`, or -1 if none.
    long lastAtOrBefore(size_t from) const @safe pure nothrow @nogc
    {
        if (empty)
            return -1;
        if (from >= size)
            from = size - 1;
        size_t i = from + size;
        if (cnt[i] != 0)
            return from;
        for (; i > 1; i >>= 1)
        {
            if ((i & 1) == 1 && cnt[i - 1] != 0)
                return descendRight(i - 1);
        }
        return -1;
    }

    /// Sum of quantities over ranks `0 .. rank` inclusive.
    long prefixSum(size_t rank) const @safe pure nothrow @nogc
    {
        if (cnt.length == 0)
            return 0;
        if (rank >= size)
            rank = size - 1;
        // Half-open [size, size + rank + 1) walked bottom-up.
        size_t l = size, r = size + rank + 1;
        long s = 0;
        for (; l < r; l >>= 1, r >>= 1)
        {
            if (l & 1)
                s += sum[l++];
            if (r & 1)
                s += sum[--r];
        }
        return s;
    }

    /// Sum of quantities over ranks `rank .. P-1`.
    long suffixSum(size_t rank) const @safe pure nothrow @nogc
    {
        if (cnt.length == 0 || rank >= size)
            return 0;
        return sum[1] - (rank == 0 ? 0 : prefixSum(rank - 1));
    }
}
