/**
 * Indexed binary max-heap of variables keyed by activity, used for
 * VSIDS-style branching.
 *
 * The heap does not own the activities: it keeps a slice of the solver's
 * activity array, so changes made there are seen by the heap. After a
 * variable's activity increases, call $(LREF VarHeap.increased).
 */
module sat.heap;

/// Max-heap of variables `0 .. n-1` ordered by activity.
struct VarHeap
{
    private
    {
        double[] act;   // shared with the owner
        int[] heap;     // heap order
        int[] pos;      // pos[v] = index in `heap`, or -1 when absent
        int count;      // number of elements in `heap`
    }

    /// `activity` must have one entry per variable; the heap starts empty.
    this(double[] activity)
    {
        act = activity;
        heap = new int[activity.length];
        pos = new int[activity.length];
        pos[] = -1;
    }

    /// True if no variable is in the heap.
    bool empty() const @safe pure nothrow @nogc { return count == 0; }

    /// Number of variables in the heap.
    int length() const @safe pure nothrow @nogc { return count; }

    /// True if `v` is currently in the heap.
    bool contains(int v) const @safe pure nothrow @nogc { return pos[v] >= 0; }

    /// Insert `v` if it is not already present.
    void insert(int v) @safe pure nothrow @nogc
    {
        if (pos[v] >= 0)
            return;
        heap[count] = v;
        pos[v] = count;
        ++count;
        siftUp(count - 1);
    }

    /// Restore the heap order after the activity of `v` has increased.
    /// Does nothing when `v` is not in the heap.
    void increased(int v) @safe pure nothrow @nogc
    {
        if (pos[v] >= 0)
            siftUp(pos[v]);
    }

    /// Remove and return the variable with the highest activity.
    /// The last element moves to the root and sifts down. The heap must not be empty.
    int removeMax() @safe pure nothrow @nogc
    {
        assert(count > 0);
        immutable top = heap[0];
        immutable last = heap[count - 1];
        --count;
        pos[top] = -1;
        if (count > 0)
        {
            heap[0] = last;
            pos[last] = 0;
            siftDown(0);
        }
        return top;
    }

    private void siftUp(int i) @safe pure nothrow @nogc
    {
        immutable x = heap[i];
        immutable ax = act[x];
        while (i > 0)
        {
            immutable parent = (i - 1) >> 1;
            immutable p = heap[parent];
            if (act[p] >= ax)
                break;
            heap[i] = p;
            pos[p] = i;
            i = parent;
        }
        heap[i] = x;
        pos[x] = i;
    }

    private void siftDown(int i) @safe pure nothrow @nogc
    {
        immutable x = heap[i];
        immutable ax = act[x];
        while (true)
        {
            immutable left = 2 * i + 1;
            if (left >= count)
                break;
            immutable right = left + 1;
            immutable child = (right < count && act[heap[right]] > act[heap[left]]) ? right : left;
            immutable c = heap[child];
            if (act[c] <= ax)
                break;
            heap[i] = c;
            pos[c] = i;
            i = child;
        }
        heap[i] = x;
        pos[x] = i;
    }
}
