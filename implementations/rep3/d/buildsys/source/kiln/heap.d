/// A binary min-heap of integers.
module kiln.heap;

/// Min-heap of ints (used for step serials).
struct MinHeap
{
    private int[] a;

    @property bool empty() const @safe pure nothrow @nogc
    {
        return a.length == 0;
    }

    @property size_t length() const @safe pure nothrow @nogc
    {
        return a.length;
    }

    /// Insert a value.
    void push(int v) @safe pure nothrow
    {
        a ~= v;
        size_t i = a.length - 1;
        while (i > 0)
        {
            immutable p = (i - 1) / 2;
            if (a[p] <= a[i])
                break;
            immutable t = a[p];
            a[p] = a[i];
            a[i] = t;
            i = p;
        }
    }

    /// The smallest value.
    int top() const @safe pure nothrow @nogc
    {
        return a[0];
    }

    /// Remove and return the smallest value.
    int pop() @safe pure nothrow
    {
        immutable r = a[0];
        a[0] = a[$ - 1];
        a.length = a.length - 1;
        size_t i = 0;
        immutable n = a.length;
        while (true)
        {
            size_t l = 2 * i + 1, rr = l + 1, m = i;
            if (l < n && a[l] < a[m])
                m = l;
            if (rr < n && a[rr] < a[m])
                m = rr;
            if (m == i)
                break;
            immutable t = a[m];
            a[m] = a[i];
            a[i] = t;
            i = m;
        }
        return r;
    }
}
