/// A minimal growable array with O(1) truncation that keeps its capacity.
module sat.vec;

/**
 * Growable array. Unlike a built-in slice, `shrink` followed by `push`
 * reuses the storage instead of reallocating, which the solver's watch lists
 * and trail rely on.
 */
struct Vec(T)
{
    private T[] data;
    private size_t len;

    /// Number of elements.
    size_t length() const pure nothrow @nogc @safe { return len; }

    /// True when there are no elements.
    bool empty() const pure nothrow @nogc @safe { return len == 0; }

    /// Appends an element.
    void push(T value) pure nothrow @safe
    {
        if (len == data.length)
            data.length = len < 4 ? 4 : len * 2;
        data[len++] = value;
    }

    /// Removes and returns the last element.
    T pop() pure nothrow @nogc @safe
    in (len > 0)
    {
        return data[--len];
    }

    /// Drops all elements beyond the first `n`.
    void shrink(size_t n) pure nothrow @nogc @safe
    in (n <= len)
    {
        len = n;
    }

    /// Removes all elements.
    void clear() pure nothrow @nogc @safe { len = 0; }

    /// Element access.
    ref inout(T) opIndex(size_t i) inout pure nothrow @nogc @safe
    in (i < len)
    {
        return data[i];
    }

    /// The live elements as a slice (invalidated by `push`).
    inout(T)[] opSlice() inout pure nothrow @nogc @safe { return data[0 .. len]; }

    /// ditto
    inout(T)[] opSlice(size_t from, size_t to) inout pure nothrow @nogc @safe
    in (from <= to && to <= len)
    {
        return data[from .. to];
    }

    /// Number of elements (for `$` in slices).
    size_t opDollar() const pure nothrow @nogc @safe { return len; }

    /// Last element.
    ref inout(T) back() inout pure nothrow @nogc @safe
    in (len > 0)
    {
        return data[len - 1];
    }
}

///
@safe pure nothrow unittest
{
    Vec!int v;
    foreach (i; 0 .. 10)
        v.push(i);
    assert(v.length == 10 && v[3] == 3 && v.back == 9);
    v.shrink(2);
    assert(v[] == [0, 1]);
    v.push(42);
    assert(v[] == [0, 1, 42] && v.pop() == 42);
    v.clear();
    assert(v.empty);
}
