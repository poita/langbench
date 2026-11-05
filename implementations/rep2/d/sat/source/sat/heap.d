/**
 * Indexed binary max-heap of variables ordered by activity (VSIDS).
 *
 * The heap does not own the activity array; it reads it through a slice that
 * the owner keeps up to date. Every operation is O(log n) except `contains`
 * (O(1)).
 */
module sat.heap;

/// Max-heap of variable indices keyed by an external activity array.
struct VarHeap
{
    private int[] heap;      // heap order -> variable (capacity numVars)
    private size_t count;    // number of live entries in heap
    private int[] indices;   // variable -> position in heap, or -1
    private const(double)[] activity;

    /// Creates an empty heap for variables `0 .. numVars-1`.
    this(size_t numVars, const(double)[] activity) pure nothrow @safe
    {
        this.activity = activity;
        indices = new int[numVars];
        indices[] = -1;
        heap = new int[numVars];
    }

    /// Re-points the heap at a (possibly reallocated) activity array.
    void setActivity(const(double)[] a) pure nothrow @nogc @safe { activity = a; }

    /// True when no variable is in the heap.
    bool empty() const pure nothrow @nogc @safe { return count == 0; }

    /// Number of variables currently in the heap.
    size_t length() const pure nothrow @nogc @safe { return count; }

    /// Whether `v` is currently in the heap.
    bool contains(int v) const pure nothrow @nogc @safe { return indices[v] >= 0; }

    /// Inserts `v` (which must not already be present).
    void insert(int v) pure nothrow @safe
    in (!contains(v))
    {
        indices[v] = cast(int) count;
        heap[count++] = v;
        siftUp(indices[v]);
    }

    /// Restores heap order after the activity of `v` increased.
    void increased(int v) pure nothrow @nogc @safe
    {
        if (contains(v))
            siftUp(indices[v]);
    }

    /// Removes and returns the variable with the greatest activity.
    int removeMax() pure nothrow @safe
    in (!empty)
    {
        const top = heap[0];
        const last = heap[--count];
        indices[top] = -1;
        if (count > 0)
        {
            heap[0] = last;
            indices[last] = 0;
            siftDown(0);
        }
        return top;
    }

    private void siftUp(int i) pure nothrow @nogc @safe
    {
        const x = heap[i];
        const ax = activity[x];
        while (i > 0)
        {
            const parent = (i - 1) >> 1;
            if (activity[heap[parent]] >= ax)
                break;
            heap[i] = heap[parent];
            indices[heap[i]] = i;
            i = parent;
        }
        heap[i] = x;
        indices[x] = i;
    }

    private void siftDown(int i) pure nothrow @nogc @safe
    {
        const x = heap[i];
        const ax = activity[x];
        const n = cast(int) count;
        while (2 * i + 1 < n)
        {
            const left = 2 * i + 1;
            const right = left + 1;
            const child = (right < n && activity[heap[right]] > activity[heap[left]])
                ? right : left;
            if (activity[heap[child]] <= ax)
                break;
            heap[i] = heap[child];
            indices[heap[i]] = i;
            i = child;
        }
        heap[i] = x;
        indices[x] = i;
    }
}
