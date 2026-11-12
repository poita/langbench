/**
 * A binary min-heap, used as the priority queue of the delivery simulator.
 */
module webhooks.heap;

/**
 * Binary min-heap of `T` ordered by `less`.
 *
 * `push` and `pop` are O(log n); `front` is O(1).
 */
struct MinHeap(T, alias less = "a < b")
{
    import std.functional : binaryFun;

    private alias lessFun = binaryFun!less;
    private T[] items;

    /// Number of elements.
    size_t length() const pure nothrow @safe @nogc
    {
        return items.length;
    }

    /// `true` when the heap holds no elements.
    bool empty() const pure nothrow @safe @nogc
    {
        return items.length == 0;
    }

    /// The smallest element. Must not be called on an empty heap.
    ref const(T) front() const pure nothrow @safe @nogc
    in (!empty)
    {
        return items[0];
    }

    /// Inserts `value`.
    void push(T value) pure nothrow @safe
    {
        items ~= value;
        size_t i = items.length - 1;
        while (i > 0)
        {
            immutable parent = (i - 1) / 2;
            if (!lessFun(items[i], items[parent]))
                break;
            swap(i, parent);
            i = parent;
        }
    }

    /// Removes and returns the smallest element. Must not be called on an
    /// empty heap.
    T pop() pure nothrow @safe
    in (!empty)
    {
        T top = items[0];
        items[0] = items[$ - 1];
        items.length = items.length - 1;
        size_t i = 0;
        immutable n = items.length;
        for (;;)
        {
            size_t smallest = i;
            immutable l = 2 * i + 1;
            immutable r = l + 1;
            if (l < n && lessFun(items[l], items[smallest]))
                smallest = l;
            if (r < n && lessFun(items[r], items[smallest]))
                smallest = r;
            if (smallest == i)
                break;
            swap(i, smallest);
            i = smallest;
        }
        return top;
    }

    private void swap(size_t a, size_t b) pure nothrow @safe @nogc
    {
        T tmp = items[a];
        items[a] = items[b];
        items[b] = tmp;
    }
}

@safe unittest
{
    MinHeap!int h;
    assert(h.empty);
    foreach (v; [5, 3, 9, 1, 7, 3, 8, 2, 6, 4, 0])
        h.push(v);
    assert(h.length == 11 && h.front == 0);
    int prev = -1;
    while (!h.empty)
    {
        immutable v = h.pop();
        assert(v >= prev);
        prev = v;
    }
    assert(prev == 9);
}

@safe unittest
{
    struct Item
    {
        long time;
        uint id;
    }

    MinHeap!(Item, (a, b) => a.time < b.time || (a.time == b.time && a.id < b.id)) h;
    h.push(Item(10, 2));
    h.push(Item(10, 1));
    h.push(Item(-4, 7));
    assert(h.pop() == Item(-4, 7));
    assert(h.pop() == Item(10, 1));
    assert(h.pop() == Item(10, 2));
}
