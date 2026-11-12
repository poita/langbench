/// VSIDS variable ordering: activities plus a max-heap of candidate variables.
module sat.order;

/**
 * Variable activities with a binary max-heap keyed on activity.
 *
 * Bumping adds the current increment to a variable's activity; `decay`
 * makes later bumps count more (the increment is divided by the decay
 * factor). Activities are rescaled by `1e-100` when one exceeds `1e100`.
 * Selection from the heap is O(log n).
 */
struct VarOrder
{
    private double[] act;
    private int[] heap;     // heap of variables
    private int[] pos;      // position in `heap`, or -1
    private double inc = 1.0;
    /// Factor the increment is divided by after each conflict.
    double decayFactor = 0.95;

    /// Adds a new variable (initial activity 0) and puts it in the heap.
    void addVar() pure nothrow @safe
    {
        const v = cast(int) act.length;
        act ~= 0.0;
        pos ~= -1;
        insert(v);
    }

    /// Number of variables.
    size_t length() const pure nothrow @nogc @safe { return act.length; }

    /// Activity of variable `v`.
    double activity(int v) const pure nothrow @nogc @safe { return act[v]; }

    /// True if `v` is currently in the heap.
    bool inHeap(int v) const pure nothrow @nogc @safe { return pos[v] >= 0; }

    /// Inserts `v` into the heap unless already present.
    void insert(int v) pure nothrow @safe
    {
        if (pos[v] >= 0)
            return;
        pos[v] = cast(int) heap.length;
        heap ~= v;
        up(pos[v]);
    }

    /// Bumps the activity of `v`.
    void bump(int v) pure nothrow @safe
    {
        act[v] += inc;
        if (act[v] > 1e100)
        {
            foreach (ref a; act)
                a *= 1e-100;
            inc *= 1e-100;
        }
        if (pos[v] >= 0)
            up(pos[v]);
    }

    /// Applies one decay step.
    void decay() pure nothrow @nogc @safe { inc /= decayFactor; }

    /// True if no variable is in the heap.
    bool empty() const pure nothrow @nogc @safe { return heap.length == 0; }

    /// Removes and returns the variable of highest activity.
    int removeMax() pure nothrow @safe
    in (!empty)
    {
        const top = heap[0];
        const last = heap[$ - 1];
        heap = heap[0 .. $ - 1];
        pos[top] = -1;
        if (heap.length)
        {
            heap[0] = last;
            pos[last] = 0;
            down(0);
        }
        return top;
    }

    private bool less(int a, int b) const pure nothrow @nogc @safe
    {
        return act[a] > act[b]; // max-heap: "less" means higher up
    }

    private void up(int i) pure nothrow @nogc @safe
    {
        const x = heap[i];
        while (i > 0)
        {
            const p = (i - 1) >> 1;
            if (!less(x, heap[p]))
                break;
            heap[i] = heap[p];
            pos[heap[i]] = i;
            i = p;
        }
        heap[i] = x;
        pos[x] = i;
    }

    private void down(int i) pure nothrow @nogc @safe
    {
        const x = heap[i];
        const n = cast(int) heap.length;
        for (;;)
        {
            int c = 2 * i + 1;
            if (c >= n)
                break;
            if (c + 1 < n && less(heap[c + 1], heap[c]))
                c++;
            if (!less(heap[c], x))
                break;
            heap[i] = heap[c];
            pos[heap[i]] = i;
            i = c;
        }
        heap[i] = x;
        pos[x] = i;
    }
}

@safe pure nothrow unittest
{
    VarOrder o;
    foreach (_; 0 .. 5)
        o.addVar();
    o.bump(3);
    o.bump(3);
    o.bump(1);
    assert(o.removeMax() == 3);
    assert(o.removeMax() == 1);
    o.insert(3);
    assert(o.inHeap(3));
    assert(o.removeMax() == 3);
    int n;
    while (!o.empty)
    {
        o.removeMax();
        n++;
    }
    assert(n == 3);
}

@safe pure nothrow unittest
{
    // decay makes later bumps outweigh earlier ones; rescaling keeps order
    VarOrder o;
    o.addVar();
    o.addVar();
    o.bump(0);
    foreach (_; 0 .. 5000)
        o.decay();
    o.bump(1);
    assert(o.activity(1) < 1e101 && o.activity(1) > o.activity(0));
    assert(o.removeMax() == 1);
}
