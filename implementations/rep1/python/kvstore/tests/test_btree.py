"""Randomised model checks of the B+tree, free list, overflow chains and indexes."""

import random

import pytest

from tessera import Database, TesseraError

from helpers import check_database


def doc_of(rng: random.Random):
    kind = rng.random()
    if kind < 0.4:
        return rng.randint(-5, 5)
    if kind < 0.6:
        return "s" * rng.choice([0, 3, 50, 190, 400])
    if kind < 0.8:
        return {"n": rng.randint(0, 20), "tag": rng.choice(["a", "b", "c"]), "pad": "p" * rng.choice([0, 100, 300])}
    return list(range(rng.choice([1, 20, 100, 300, 1500])))     # up to ~13 KB, several overflow pages


@pytest.mark.parametrize("seed", range(6))
def test_random_operations_match_a_dict(seed):
    rng = random.Random(seed)
    db = Database.open()
    db.create_index("n")
    model: dict[bytes, object] = {}
    keyspace = [("k%04d" % i + "x" * rng.choice([0, 0, 40, 100])).encode() for i in range(160)]
    for step in range(900):
        key = rng.choice(keyspace)
        op = rng.random()
        if op < 0.45:
            doc = doc_of(rng)
            assert db.put(key, doc) == (key not in model)
            model[key] = doc
        elif op < 0.8:
            if key in model:
                db.delete(key)
                del model[key]
            else:
                with pytest.raises(TesseraError):
                    db.delete(key)
        elif op < 0.9 and isinstance(model.get(key), dict):
            db.update(key, "n", step)
            model[key] = {**model[key], "n": step}
        elif isinstance(model.get(key), dict) and "n" in model[key]:
            db.unset(key, "n")
            model[key] = {k: v for k, v in model[key].items() if k != "n"}
        if step % 150 == 0:
            check_database(db)
    check_database(db)
    assert [k for k, _ in db.scan()] == sorted(model)
    assert dict(db.scan()) == model
    assert [k for k, _ in db.scan(reverse=True)] == sorted(model, reverse=True)
    lo, hi = keyspace[20], keyspace[100]
    assert db.scan(lo, hi, keys_only=True) == [k for k in sorted(model) if lo <= k < hi]
    assert db.scan(lo, hi, limit=5, reverse=True, keys_only=True) == \
        [k for k in sorted(model, reverse=True) if lo <= k < hi][:5]
    expected = sorted(k for k, d in model.items() if isinstance(d, dict) and d.get("n", -1) >= 10)
    res = db.find("n >= 10")
    assert res.plan.kind == "index"
    assert [k for k, _ in res.rows] == expected
    for k in list(model):
        db.delete(k)
    check_database(db)
    assert len(db) == 0 and db.stat().height == 0
    assert db.indexes()[0].entries == 0


def test_free_list_reuse_and_a_checkpointed_copy_agree():
    rng = random.Random(7)
    db = Database.open()
    for i in range(200):
        db.put("k%d" % i, doc_of(rng))
    for i in range(0, 200, 2):
        db.delete("k%d" % i)
    before = dict(db.scan())
    db.checkpoint()
    check_database(db)
    again = Database.open(db.db_image(), db.wal_image())
    assert dict(again.scan()) == before
    assert again.db_image() == db.db_image()
