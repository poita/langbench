/// A minimal growable buffer that keeps its capacity when cleared.
module svgraster.buf;

/// Growable array with explicit length; `clear` resets the length but keeps
/// the allocation so scratch buffers can be reused without reallocating.
struct Buf(T)
{
    private T[] store;
    private size_t used;

    /// Number of elements.
    @property size_t length() const pure nothrow @nogc @safe { return used; }

    /// True when there are no elements.
    @property bool empty() const pure nothrow @nogc @safe { return used == 0; }

    /// Drop all elements, keeping the capacity.
    void clear() pure nothrow @nogc @safe { used = 0; }

    /// Shrink to `n` elements (`n <= length`).
    void truncate(size_t n) pure nothrow @nogc @safe
    {
        assert(n <= used);
        used = n;
    }

    /// Append one element.
    void push(T v) pure nothrow @safe
    {
        if (used == store.length)
            store.length = store.length < 16 ? 16 : store.length * 2;
        store[used++] = v;
    }

    /// View of the live elements (invalidated by `push`).
    @property inout(T)[] slice() inout pure nothrow @nogc @safe { return store[0 .. used]; }

    /// Element access.
    ref inout(T) opIndex(size_t i) inout pure nothrow @nogc @safe
    {
        assert(i < used);
        return store[i];
    }
}

