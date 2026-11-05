module sat.heap_test;

import sat.heap;
import sat.testutil : Rng;

unittest // pops in descending activity order
{
    double[] a = [1.0, 5.0, 3.0, 4.0, 2.0];
    auto h = VarHeap(a);
    foreach (v; 0 .. 5)
        h.insert(v);
    assert(h.length == 5);
    int[] order;
    while (!h.empty)
        order ~= h.removeMax();
    assert(order == [1, 3, 2, 4, 0]);
}

unittest // equal activities come out in insertion order for small heaps
{
    double[] a = [0, 0, 0];
    auto h = VarHeap(a);
    foreach (v; 0 .. 3)
        h.insert(v);
    assert(h.removeMax() == 0);
    assert(h.removeMax() == 2); // last element moved to the root
    assert(h.removeMax() == 1);
}

unittest // insert is idempotent, contains tracks membership
{
    double[] a = [1.0, 2.0];
    auto h = VarHeap(a);
    h.insert(0);
    h.insert(0);
    assert(h.length == 1 && h.contains(0) && !h.contains(1));
    h.removeMax();
    assert(!h.contains(0));
}

unittest // increased moves a variable up; no-op for absent variables
{
    double[] a = [1.0, 2.0, 3.0];
    auto h = VarHeap(a);
    h.insert(0);
    h.insert(1);
    a[0] = 10.0;
    h.increased(0);
    a[2] = 100.0;
    h.increased(2);          // not in the heap: ignored
    assert(h.length == 2);
    assert(h.removeMax() == 0);
    assert(h.removeMax() == 1);
}

unittest // randomised: pops are sorted
{
    Rng rng;
    enum n = 200;
    auto a = new double[n];
    foreach (ref x; a)
        x = rng.below(1000);
    auto h = VarHeap(a);
    foreach (v; 0 .. n)
        h.insert(v);
    foreach (_; 0 .. 100)
    {
        immutable v = rng.below(n);
        a[v] += rng.below(500);
        h.increased(v);
    }
    double prev = double.infinity;
    int popped;
    while (!h.empty)
    {
        immutable v = h.removeMax();
        assert(a[v] <= prev);
        prev = a[v];
        ++popped;
    }
    assert(popped == n);
}
