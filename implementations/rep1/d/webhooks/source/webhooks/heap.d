/**
 * A binary min-heap of `(time, delivery)` pairs ordered lexicographically.
 */
module webhooks.heap;

/// One pending attempt: scheduled time and owning delivery number.
struct Slot
{
    long time;
    uint delivery;

    bool before(const Slot o) const @safe pure nothrow @nogc
    {
        return time < o.time || (time == o.time && delivery < o.delivery);
    }
}

/// Binary min-heap over reserved storage with an explicit length.
struct SlotHeap
{
    private Slot[] items;
    private size_t count;

    /// Reserves room for `capacity` elements (no reallocation up to that).
    this(size_t capacity) @safe pure nothrow
    {
        items = new Slot[capacity];
    }

    bool empty() const @safe pure nothrow @nogc { return count == 0; }
    size_t length() const @safe pure nothrow @nogc { return count; }

    /// Inserts `s`, growing the storage if it was under-reserved.
    void push(Slot s) @safe pure nothrow
    {
        if (count == items.length)
            items.length = items.length == 0 ? 16 : items.length * 2;
        size_t i = count++;
        while (i > 0)
        {
            immutable parent = (i - 1) / 2;
            if (!s.before(items[parent]))
                break;
            items[i] = items[parent];
            i = parent;
        }
        items[i] = s;
    }

    /// Removes and returns the smallest element. Must not be empty.
    Slot pop() @safe pure nothrow @nogc
    in (count > 0)
    {
        auto top = items[0];
        auto last = items[--count];
        if (count > 0)
        {
            size_t i = 0;
            for (;;)
            {
                size_t child = 2 * i + 1;
                if (child >= count)
                    break;
                if (child + 1 < count && items[child + 1].before(items[child]))
                    ++child;
                if (!items[child].before(last))
                    break;
                items[i] = items[child];
                i = child;
            }
            items[i] = last;
        }
        return top;
    }
}
