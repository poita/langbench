module heap_test;

import sat.heap;

unittest
{
    // Ties pop in the documented order: the last element moves to the root.
    auto act = new double[3];
    act[] = 0;
    auto h = VarHeap(3, act);
    foreach (v; 0 .. 3)
        h.insert(v);
    assert(h.length == 3 && h.contains(1));
    assert(h.removeMax() == 0);
    assert(h.removeMax() == 2);
    assert(h.removeMax() == 1);
    assert(h.empty && !h.contains(1));
}

unittest
{
    double[] act = [1.0, 5.0, 3.0, 4.0, 2.0];
    auto h = VarHeap(5, act);
    foreach (v; 0 .. 5)
        h.insert(v);
    assert(h.removeMax() == 1);
    act[0] = 10.0;
    h.increased(0);
    assert(h.removeMax() == 0);
    int[] rest;
    while (!h.empty)
        rest ~= h.removeMax();
    assert(rest == [3, 2, 4]);
    // Re-insertion after removal works.
    h.insert(4);
    assert(h.contains(4) && h.removeMax() == 4);
}
