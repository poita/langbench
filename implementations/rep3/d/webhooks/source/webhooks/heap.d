/**
 * A binary min-heap of `(time, id)` pairs ordered lexicographically.
 *
 * The backing array is reserved up front and the heap keeps an explicit
 * length, so push and pop are O(log n) and never reallocate when the reserved
 * capacity suffices.
 */
module webhooks.heap;

/// One scheduled item: a time and an id (the tie-break).
struct TimedItem
{
    long time;
    uint id;
}

private bool less(in TimedItem a, in TimedItem b) @safe pure nothrow @nogc
{
    return a.time < b.time || (a.time == b.time && a.id < b.id);
}

/// Min-heap of `TimedItem`s.
struct MinHeap
{
    private TimedItem[] items;
    private size_t count;

    /// Create a heap with room for `capacity` items.
    this(size_t capacity) @safe pure nothrow
    {
        items = new TimedItem[capacity];
    }

    /// Number of items in the heap.
    size_t length() const @safe pure nothrow @nogc
    {
        return count;
    }

    /// True if the heap holds no items.
    bool empty() const @safe pure nothrow @nogc
    {
        return count == 0;
    }

    /// The smallest item. The heap must not be empty.
    TimedItem front() const @safe pure nothrow @nogc
    in (count > 0)
    {
        return items[0];
    }

    /// Insert an item (growing the storage only if the reserved capacity is exceeded).
    void push(TimedItem item) @safe pure nothrow
    {
        if (count == items.length)
            items.length = items.length == 0 ? 16 : items.length * 2;
        size_t i = count++;
        while (i > 0)
        {
            immutable parent = (i - 1) / 2;
            if (!less(item, items[parent]))
                break;
            items[i] = items[parent];
            i = parent;
        }
        items[i] = item;
    }

    /// Remove and return the smallest item. The heap must not be empty.
    TimedItem pop() @safe pure nothrow @nogc
    in (count > 0)
    {
        immutable top = items[0];
        immutable last = items[--count];
        if (count > 0)
            siftDown(0, last);
        return top;
    }

    private void siftDown(size_t i, TimedItem item) @safe pure nothrow @nogc
    {
        while (true)
        {
            size_t child = 2 * i + 1;
            if (child >= count)
                break;
            if (child + 1 < count && less(items[child + 1], items[child]))
                ++child;
            if (!less(items[child], item))
                break;
            items[i] = items[child];
            i = child;
        }
        items[i] = item;
    }

    /// Build a heap from `all` in O(n) (Floyd's heapify), taking ownership of the array.
    static MinHeap heapify(TimedItem[] all) @safe pure nothrow @nogc
    {
        MinHeap h;
        h.items = all;
        h.count = all.length;
        if (h.count > 1)
            for (size_t i = h.count / 2; i-- > 0;)
                h.siftDown(i, h.items[i]);
        return h;
    }
}
