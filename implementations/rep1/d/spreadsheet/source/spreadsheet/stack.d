/// A growable stack whose capacity survives pops (no reallocation churn).
module spreadsheet.stack;

/// A LIFO vector.  Unlike truncating and re-appending to a D slice, popping
/// never gives up capacity.
struct Stack(T)
{
    private T[] buf;
    private size_t used;

    /// Number of elements.
    size_t length() const @safe pure nothrow @nogc { return used; }

    /// True if there are no elements.
    bool empty() const @safe pure nothrow @nogc { return used == 0; }

    /// Push `v` on top.
    void push(T v) @safe pure nothrow
    {
        if (used == buf.length)
            buf.length = used < 4 ? 4 : used * 2;
        buf[used++] = v;
    }

    /// Remove and return the top element.
    T pop() @safe pure nothrow @nogc
    in (used > 0)
    {
        return buf[--used];
    }

    /// The top element.
    ref inout(T) back() inout @safe pure nothrow @nogc
    in (used > 0)
    {
        return buf[used - 1];
    }

    /// Remove all elements, keeping capacity.
    void clear() @safe pure nothrow @nogc { used = 0; }

    /// View of the live elements (invalidated by `push`).
    inout(T)[] opSlice() inout @safe pure nothrow @nogc { return buf[0 .. used]; }

    /// Element access.
    ref inout(T) opIndex(size_t i) inout @safe pure nothrow @nogc { return buf[i]; }

    /// Remove the first element equal to `v` by swapping in the last one.
    /// Returns false if `v` is not present.
    bool swapRemove(T v) @safe pure nothrow @nogc
    {
        foreach (i; 0 .. used)
        {
            if (buf[i] == v)
            {
                buf[i] = buf[--used];
                return true;
            }
        }
        return false;
    }
}
