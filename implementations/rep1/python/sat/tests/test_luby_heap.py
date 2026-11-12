import random

from cdcl_sat.heap import VarHeap
from cdcl_sat.luby import luby


def test_luby_sequence():
    seq = [int(luby(2, i)) for i in range(15)]
    assert seq == [1, 1, 2, 1, 1, 2, 4, 1, 1, 2, 1, 1, 2, 4, 8]


def test_heap_pops_in_activity_order():
    rng = random.Random(1)
    act = [rng.random() for _ in range(200)]
    h = VarHeap(act)
    for v in range(200):
        h.insert(v)
    for _ in range(300):
        v = rng.randrange(200)
        act[v] += rng.random()
        h.increased(v)
    out = [h.pop() for _ in range(200)]
    assert [act[v] for v in out] == sorted(act, reverse=True)
    assert len(h) == 0 and 0 not in h


def test_heap_insert_idempotent():
    h = VarHeap([1.0, 2.0])
    h.insert(0)
    h.insert(0)
    assert len(h) == 1
