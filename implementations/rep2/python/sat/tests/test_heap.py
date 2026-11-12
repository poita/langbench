import random

from cdcl_sat.heap import ActivityHeap
from cdcl_sat.luby import luby


def test_pops_in_activity_order():
    act = [3.0, 1.0, 4.0, 1.5, 9.0, 2.6]
    h = ActivityHeap(act)
    for v in range(len(act)):
        h.insert(v)
    out = [h.pop_max() for _ in range(len(act))]
    assert out == sorted(range(len(act)), key=lambda v: -act[v])
    assert len(h) == 0


def test_increase_key_and_membership():
    act = [1.0, 2.0, 3.0]
    h = ActivityHeap(act)
    for v in range(3):
        h.insert(v)
    h.insert(1)  # duplicate insert is a no-op
    assert len(h) == 3
    act[0] = 10.0
    h.increased(0)
    assert h.pop_max() == 0
    assert 0 not in h and 1 in h
    h.increased(0)  # absent var: ignored


def test_random_against_sorted():
    rng = random.Random(1)
    act = [rng.random() for _ in range(200)]
    h = ActivityHeap(act)
    for v in range(200):
        h.insert(v)
    for _ in range(300):
        v = rng.randrange(200)
        act[v] += rng.random()
        h.increased(v)
    out = [h.pop_max() for _ in range(200)]
    assert [act[v] for v in out] == sorted(act, reverse=True)


def test_rebuild():
    act = [5.0, 1.0, 3.0]
    h = ActivityHeap(act)
    h.insert(0)
    h.rebuild([1, 2])
    assert 0 not in h
    assert h.pop_max() == 2


def test_luby_sequence():
    assert [luby(2, i) for i in range(15)] == [
        1, 1, 2, 1, 1, 2, 4, 1, 1, 2, 1, 1, 2, 4, 8,
    ]
