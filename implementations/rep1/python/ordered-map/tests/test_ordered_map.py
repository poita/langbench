import bisect
import random

import pytest

from ordered_map import OrderedMap

INT_MIN, INT_MAX = -(2**63), 2**63 - 1


def make(*keys):
    m = OrderedMap()
    for k in keys:
        m.insert(k, str(k))
    return m


def test_empty():
    m = OrderedMap()
    assert len(m) == 0
    assert m.min() is None and m.max() is None
    assert m.floor(0) is None and m.ceil(0) is None
    assert m.successor(0) is None and m.predecessor(0) is None
    assert m.rank(5) == 0
    assert m.select(0) is None
    assert list(m.range(INT_MIN, INT_MAX)) == []


def test_insert_update_delete():
    m = OrderedMap()
    assert m.insert(5, "a") is True
    assert m.insert(5, "b") is False
    assert m.get(5) == "b" and len(m) == 1
    assert m.delete(5) is True
    assert m.delete(5) is False
    assert m.get(5) is None


def test_mapping_sugar():
    m = OrderedMap()
    m[3] = "x"
    assert m[3] == "x" and 3 in m and 4 not in m
    del m[3]
    with pytest.raises(KeyError):
        m[3]
    with pytest.raises(KeyError):
        del m[3]


def test_neighbours_and_extremes():
    m = make(INT_MIN, 0, INT_MAX)
    assert m.successor(INT_MAX) is None
    assert m.predecessor(INT_MIN) is None
    assert m.floor(INT_MIN + 1) == INT_MIN
    assert m.ceil(1) == INT_MAX
    assert m.successor(INT_MIN) == 0
    assert m.predecessor(INT_MAX) == 0
    assert list(m) == [INT_MIN, 0, INT_MAX]


def test_range_bounds():
    m = make(*range(0, 100, 10))
    assert list(m.range(15, 45)) == [20, 30, 40]
    assert list(m.range(20, 40)) == [20, 30, 40]
    assert list(m.range(50, 40)) == []
    assert list(m.range(None, 20)) == [0, 10, 20]
    assert list(m.range(80, None)) == [80, 90]


def test_sorted_insert_stays_balanced():
    m = OrderedMap()
    for k in range(5000):
        m.insert(k, "v")
    m.check_invariants()
    assert m._root.height <= 1.45 * 13
    for k in range(4999, 100, -1):
        m.delete(k)
    m.check_invariants()
    assert len(m) == 101


def test_items_and_repr():
    m = OrderedMap()
    m.insert(2, "b")
    m.insert(1, "a")
    assert list(m.items()) == [(1, "a"), (2, "b")]
    assert repr(m) == "OrderedMap({1: 'a', 2: 'b'})"


@pytest.mark.parametrize("seed", range(5))
def test_random_against_reference(seed):
    rng = random.Random(seed)
    m = OrderedMap()
    ref = {}
    keys = []  # sorted reference
    for step in range(3000):
        k = rng.randint(-50, 50)
        op = rng.choice(["ins", "del", "q"])
        if op == "ins":
            v = str(rng.random())
            assert m.insert(k, v) == (k not in ref)
            if k not in ref:
                bisect.insort(keys, k)
            ref[k] = v
        elif op == "del":
            assert m.delete(k) == (k in ref)
            if k in ref:
                del ref[k]
                keys.remove(k)
        else:
            i = bisect.bisect_left(keys, k)
            j = bisect.bisect_right(keys, k)
            assert m.rank(k) == i
            assert m.get(k) == ref.get(k)
            assert m.ceil(k) == (keys[i] if i < len(keys) else None)
            assert m.floor(k) == (keys[j - 1] if j > 0 else None)
            assert m.successor(k) == (keys[j] if j < len(keys) else None)
            assert m.predecessor(k) == (keys[i - 1] if i > 0 else None)
            assert m.select(i) == (keys[i] if i < len(keys) else None)
            hi = k + rng.randint(-5, 30)
            assert list(m.range(k, hi)) == [x for x in keys if k <= x <= hi]
        assert len(m) == len(keys)
        if step % 100 == 0:
            m.check_invariants()
    assert list(m) == keys
    assert m.min() == (keys[0] if keys else None)
    assert m.max() == (keys[-1] if keys else None)
