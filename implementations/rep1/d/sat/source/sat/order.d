/// VSIDS variable activities and the max-heap used to pick decisions.
module sat.order;

/**
 * Variable activities with an indexed binary max-heap over the variables that
 * are candidates for branching.
 *
 * Bumping adds the current increment to a variable's activity; `decay`
 * divides the increment by the decay factor (0.95), which makes recent
 * conflicts weigh more. Activities are rescaled by `1e-100` whenever one
 * exceeds `1e100`. Heap operations are O(log n).
 */
struct VarOrder
{
    private double[] act;
    private int[] heap;
    private int[] pos; // position in `heap`, or -1
    private size_t heapLen;
    private double inc = 1.0;

    /// Activity decay factor: the increment is divided by this after each conflict.
    enum double decayFactor = 0.95;

    /// Number of variables known to the order.
    size_t length() const pure nothrow @nogc @safe { return act.length; }

    /// Activity of variable `v`.
    double activity(int v) const pure nothrow @nogc @safe { return act[v]; }

    /// True if no variable is waiting in the heap.
    bool empty() const pure nothrow @nogc @safe { return heapLen == 0; }

    /// True if `v` is in the heap.
    bool contains(int v) const pure nothrow @nogc @safe { return pos[v] >= 0; }

    /// Registers a new variable (the next index) with activity 0 and inserts it.
    void addVariable() pure nothrow @safe
    {
        immutable v = cast(int) act.length;
        act ~= 0.0;
        pos ~= -1;
        heap ~= 0;
        insert(v);
    }

    /// Inserts `v` into the heap if it is not already there.
    void insert(int v) pure nothrow @nogc @safe
    {
        if (pos[v] >= 0)
            return;
        heap[heapLen] = v;
        pos[v] = cast(int) heapLen;
        ++heapLen;
        siftUp(heapLen - 1);
    }

    /// Increases the activity of `v` by the current increment.
    void bump(int v) pure nothrow @nogc @safe
    {
        act[v] += inc;
        if (act[v] > 1e100)
        {
            foreach (ref a; act)
                a *= 1e-100;
            inc *= 1e-100;
        }
        if (pos[v] >= 0)
            siftUp(cast(size_t) pos[v]);
    }

    /// Applies the VSIDS decay (grows the increment by 1/0.95).
    void decay() pure nothrow @nogc @safe { inc /= decayFactor; }

    /// Removes and returns the variable of highest activity, or -1 if the heap is empty.
    int removeMax() pure nothrow @nogc @safe
    {
        if (heapLen == 0)
            return -1;
        immutable top = heap[0];
        --heapLen;
        pos[top] = -1;
        if (heapLen > 0)
        {
            heap[0] = heap[heapLen];
            pos[heap[0]] = 0;
            siftDown(0);
        }
        return top;
    }

private:
    void siftUp(size_t i) pure nothrow @nogc @safe
    {
        immutable v = heap[i];
        immutable a = act[v];
        while (i > 0)
        {
            immutable parent = (i - 1) >> 1;
            if (act[heap[parent]] >= a)
                break;
            heap[i] = heap[parent];
            pos[heap[i]] = cast(int) i;
            i = parent;
        }
        heap[i] = v;
        pos[v] = cast(int) i;
    }

    void siftDown(size_t i) pure nothrow @nogc @safe
    {
        immutable v = heap[i];
        immutable a = act[v];
        for (;;)
        {
            size_t child = 2 * i + 1;
            if (child >= heapLen)
                break;
            if (child + 1 < heapLen && act[heap[child + 1]] > act[heap[child]])
                ++child;
            if (act[heap[child]] <= a)
                break;
            heap[i] = heap[child];
            pos[heap[i]] = cast(int) i;
            i = child;
        }
        heap[i] = v;
        pos[v] = cast(int) i;
    }
}

///
@safe pure nothrow unittest
{
    VarOrder o;
    foreach (_; 0 .. 4)
        o.addVariable();
    o.bump(2);
    o.decay();
    o.bump(1);
    assert(o.removeMax() == 1); // the later bump weighs more
    assert(o.removeMax() == 2);
    assert(!o.contains(1));
    o.insert(1);
    assert(o.contains(1));
    assert(o.removeMax() == 1);
}

@safe pure nothrow unittest
{
    // Heap order matches a sort by activity, and rescaling keeps the order.
    VarOrder o;
    enum n = 200;
    foreach (_; 0 .. n)
        o.addVariable();
    uint s = 12345;
    foreach (_; 0 .. 5000)
    {
        s = s * 1664525 + 1013904223;
        o.bump(cast(int) ((s >> 8) % n));
        o.decay();
    }
    double prev = double.infinity;
    foreach (_; 0 .. n)
    {
        immutable v = o.removeMax();
        assert(o.activity(v) <= prev);
        prev = o.activity(v);
    }
    assert(o.removeMax() == -1 && o.empty);
}
