module tests.components_test;

import sat;

@("Luby sequence")
unittest
{
    immutable long[] expected = [1, 1, 2, 1, 1, 2, 4, 1, 1, 2, 1, 1, 2, 4, 8];
    foreach (i, e; expected)
        assert(luby(2, i) == e);
    assert(luby(3, 2) == 3);
}

@("heap pops in activity order, ties by insertion layout")
unittest
{
    double[] act = [1.0, 5.0, 3.0, 5.0, 0.0];
    auto h = VarHeap(5, cast(const(double)[]*)&act);
    foreach (v; 0 .. 5)
        h.insert(v);
    assert(h.length == 5 && h.contains(4));
    Var[] order;
    while (!h.empty)
        order ~= h.removeMax();
    assert(order[0] == 1 || order[0] == 3);
    assert(order[$ - 1] == 4);
    assert(!h.contains(1));
}

@("heap reacts to activity increases")
unittest
{
    double[] act = new double[6];
    act[] = 0.0;
    auto h = VarHeap(6, cast(const(double)[]*)&act);
    foreach (v; 0 .. 6)
        h.insert(v);
    act[4] += 2.0;
    h.increased(4);
    assert(h.removeMax() == 4);
    act[1] += 1.0;
    h.increased(1);
    assert(h.removeMax() == 1);
    h.increased(4); // not in heap: no effect
    h.insert(4);
    assert(h.removeMax() == 4);
}

@("insertion order decides ties")
unittest
{
    double[] act = new double[4];
    act[] = 0.0;
    auto h = VarHeap(4, cast(const(double)[]*)&act);
    foreach (v; 0 .. 4)
        h.insert(v);
    assert(h.removeMax() == 0); // first inserted stays on top
}
