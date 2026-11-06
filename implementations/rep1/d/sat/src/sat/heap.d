/// Indexed binary max-heap of variables ordered by activity (VSIDS).
module sat.heap;

import sat.types : Var;

/**
 * A binary max-heap of variables keyed by an external activity array, with a
 * position index so that membership tests and key increases are O(log n).
 *
 * The activity array is shared by pointer-to-slice: the owner mutates the
 * activities and calls $(LREF VarHeap.increased) afterwards.
 */
struct VarHeap
{
    private
    {
        Var[] heap;
        int[] pos; // index in heap, or -1 when absent
        size_t count;
        const(double)[]* act;
    }

    /// Create an empty heap for variables `0 .. numVars` ordered by `*activity`.
    this(size_t numVars, const(double)[]* activity) pure nothrow @safe
    {
        heap = new Var[numVars];
        pos = new int[numVars];
        pos[] = -1;
        act = activity;
    }

    /// Number of variables in the heap.
    size_t length() const pure nothrow @safe @nogc
    {
        return count;
    }

    /// Whether the heap holds no variables.
    bool empty() const pure nothrow @safe @nogc
    {
        return count == 0;
    }

    /// Whether `v` is currently in the heap.
    bool contains(Var v) const pure nothrow @safe @nogc
    {
        return pos[v] >= 0;
    }

    /// Insert `v` (must not already be present).
    void insert(Var v) pure nothrow @trusted @nogc
    in (!contains(v))
    {
        pos[v] = cast(int) count;
        heap[count++] = v;
        siftUp(pos[v]);
    }

    /// Restore the heap order after the activity of `v` has increased.
    void increased(Var v) pure nothrow @trusted @nogc
    {
        if (pos[v] >= 0)
            siftUp(pos[v]);
    }

    /// Remove and return the variable with the greatest activity.
    Var removeMax() pure nothrow @trusted @nogc
    in (!empty)
    {
        Var top = heap[0];
        Var last = heap[--count];
        pos[top] = -1;
        if (count > 0)
        {
            heap[0] = last;
            pos[last] = 0;
            siftDown(0);
        }
        return top;
    }

    private void siftUp(int i) pure nothrow @system @nogc
    {
        const double* a = (*act).ptr;
        Var x = heap[i];
        const double ax = a[x];
        while (i > 0)
        {
            int parent = (i - 1) >> 1;
            Var p = heap[parent];
            if (a[p] >= ax)
                break;
            heap[i] = p;
            pos[p] = i;
            i = parent;
        }
        heap[i] = x;
        pos[x] = i;
    }

    private void siftDown(int i) pure nothrow @system @nogc
    {
        const double* a = (*act).ptr;
        Var x = heap[i];
        const double ax = a[x];
        const int n = cast(int) count;
        for (;;)
        {
            int child = 2 * i + 1;
            if (child >= n)
                break;
            if (child + 1 < n && a[heap[child + 1]] > a[heap[child]])
                child++;
            Var c = heap[child];
            if (a[c] <= ax)
                break;
            heap[i] = c;
            pos[c] = i;
            i = child;
        }
        heap[i] = x;
        pos[x] = i;
    }
}
