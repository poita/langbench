/// A minimal growable array with amortised O(1) appends and cheap reuse.
module textbuffer.vec;

import core.stdc.string : memcpy;

/// A growable array whose backing storage is kept across `clear` calls.
///
/// Unlike a built-in dynamic array, the logical length is tracked separately
/// from the capacity, so truncating and refilling never reallocates.
struct Vec(T)
{
    private T[] store;
    private size_t used;

    /// Number of elements.
    size_t length() const pure nothrow @nogc @safe { return used; }

    /// True when there are no elements.
    bool empty() const pure nothrow @nogc @safe { return used == 0; }

    /// The elements as a slice. Invalidated by the next append.
    inout(T)[] opSlice() inout pure nothrow @nogc @safe { return store[0 .. used]; }

    /// Element access.
    ref inout(T) opIndex(size_t i) inout pure nothrow @nogc @safe { return store[i]; }

    /// Removes all elements, keeping the capacity.
    void clear() pure nothrow @nogc @safe { used = 0; }

    /// Ensures room for `extra` more elements.
    void reserve(size_t extra) pure nothrow
    {
        immutable need = used + extra;
        if (need <= store.length)
            return;
        size_t cap = store.length * 2;
        if (cap < need) cap = need;
        if (cap < 16) cap = 16;
        auto fresh = new T[](cap);
        fresh[0 .. used] = store[0 .. used];
        store = fresh;
    }

    /// Appends one element.
    void put(T value) pure nothrow
    {
        if (used == store.length)
            reserve(1);
        store[used++] = value;
    }

    /// Appends a run of elements.
    void put(V)(const(V)[] values) nothrow if (is(V == T) && __traits(isScalar, T))
    {
        if (values.length == 0)
            return;
        reserve(values.length);
        memcpy(store.ptr + used, values.ptr, values.length * T.sizeof);
        used += values.length;
    }

    /// Shrinks to `n` elements (`n <= length`).
    void truncate(size_t n) pure nothrow @nogc @safe
    {
        assert(n <= used);
        used = n;
    }
}

/// A growable byte/character buffer with number formatting, used for output.
alias CharBuf = Vec!char;

/// Appends the decimal representation of a non-negative integer.
void putDecimal(ref CharBuf buf, size_t value) nothrow
{
    char[20] tmp = void;
    size_t i = tmp.length;
    do
    {
        tmp[--i] = cast(char)('0' + value % 10);
        value /= 10;
    }
    while (value != 0);
    buf.put(tmp[i .. $]);
}
