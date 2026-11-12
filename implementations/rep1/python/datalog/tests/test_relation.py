from datalog.relation import Relation


def test_add_all_returns_delta_and_dedups():
    r = Relation("p", 2)
    assert r.add_all([(1, 2), (1, 2), (3, 4)]) == [(1, 2), (3, 4)]
    assert r.add_all([(1, 2), (5, 6)]) == [(5, 6)]
    assert len(r) == 3 and (5, 6) in r


def test_index_built_lazily_and_maintained():
    r = Relation("p", 2)
    r.add_all([(1, 2), (1, 3)])
    idx = r.index((0,))
    assert sorted(idx[1]) == [(1, 2), (1, 3)]
    r.add_all([(1, 4), (2, 2)])
    assert r.index((0,)) is idx
    assert sorted(idx[1]) == [(1, 2), (1, 3), (1, 4)]
    assert idx[2] == [(2, 2)]


def test_multi_position_index_and_lookup():
    r = Relation("p", 3)
    r.add_all([(1, 2, 3), (1, 2, 4), (1, 5, 3)])
    assert sorted(r.lookup((0, 1), (1, 2))) == [(1, 2, 3), (1, 2, 4)]
    assert list(r.lookup((0, 1), (9, 9))) == []
    assert len(list(r.lookup((), None))) == 3
