import pytest

from tessera import And, Cmp, Database, TesseraError
from tessera.constants import MAX_DOC, WAL_LIMIT

from helpers import check_database


def kind_of(fn, *args):
    with pytest.raises(TesseraError) as e:
        fn(*args)
    return e.value.kind


def test_crud_roundtrip():
    db = Database.open()
    assert db.put("a", {"x": [1, 2]}) is True
    assert db.put(b"a", {"x": 3}) is False
    assert db.get("a") == {"x": 3} and "a" in db and len(db) == 1
    db.update("a", "y.z", None)
    assert db.get("a") == {"x": 3, "y": {"z": None}}
    db.unset("a", "y.z")
    assert db.get("a") == {"x": 3, "y": {}}
    db.delete("a")
    assert kind_of(db.get, "a") == "not-found"
    assert len(db) == 0


def test_validation_errors_leave_no_trace():
    db = Database.open()
    db.put("a", {"s": "v"})
    before = (db.db_image(), db.wal_image(), db.stat())
    assert kind_of(db.put, "", 1) == "bad-key"
    assert kind_of(db.put, "k" * 129, 1) == "bad-key"
    assert kind_of(db.put, "a", "x" * MAX_DOC) == "doc-too-large"
    deep = []
    for _ in range(32):
        deep = [deep]
    assert kind_of(db.put, "a", deep) == "depth"
    assert kind_of(db.update, "a", "s.x", 1) == "not-object"
    assert kind_of(db.update, "nope", "s", 1) == "not-found"
    assert kind_of(db.unset, "a", "t") == "no-field"
    assert kind_of(db.update, "a", "x" * 31, 1) == "bad-path"
    assert kind_of(db.drop_index, "s") == "index-missing"
    assert kind_of(db.commit) == "no-txn" and kind_of(db.rollback) == "no-txn"
    assert (db.db_image(), db.wal_image(), db.stat()) == before


def test_max_document_size():
    db = Database.open()
    doc = "x" * (MAX_DOC - 5)
    db.put("big", doc)
    assert db.get("big") == doc
    assert db.stat().pages == 1 + 65 + 1                 # header, 65 overflow pages, one leaf
    check_database(db)
    assert kind_of(db.put, "big2", doc + "y") == "doc-too-large"


def test_index_maintenance_and_key_limits():
    db = Database.open()
    db.put("a", {"v": "ada"})
    db.put("b", {"v": [1]})            # lists are not indexed
    db.put("c", {"w": 1})              # missing path: not indexed
    assert db.create_index("v") == 1
    assert kind_of(db.create_index, "v") == "index-exists"
    db.put("b", {"v": "bob"})
    db.update("c", "v", 7)
    db.unset("a", "v")
    assert db.indexes()[0].entries == 2
    assert kind_of(db.put, "k", {"v": "x" * 125}) == "index-key-too-long"   # 3 + 125 + 1 = 129
    db.put("k", {"v": "y" * 124})                                          # exactly 128 bytes
    assert kind_of(db.update, "k", "v", "y" * 125) == "index-key-too-long"
    db.put("z" * 10, {"v": "q" * 114})                                     # 3 + 114 + 10 = 127
    db.delete("b")
    assert [i.entries for i in db.indexes()] == [3]
    check_database(db)
    db.drop_index("v")
    check_database(db)
    assert db.indexes() == []


def test_create_index_refuses_too_long_keys_and_the_seventeenth_index():
    db = Database.open()
    db.put("k", {"v": "y" * 125})
    assert kind_of(db.create_index, "v") == "index-key-too-long"
    assert db.stat().commits == 1
    for i in range(16):
        db.create_index(f"p{i}")
    assert kind_of(db.create_index, "extra") == "index-limit"
    db.drop_index("p3")
    db.create_index("again")
    assert [i.path for i in db.indexes()][3] == "again"      # the lowest free slot is reused
    check_database(db)


def test_find_plans_and_range_operators():
    db = Database.open()
    docs = {"a": {"n": None}, "b": {"n": False}, "c": {"n": True}, "d": {"n": -5}, "e": {"n": 5},
            "f": {"n": "s"}, "g": {"n": [1]}, "h": {"m": 1}}
    for k, d in docs.items():
        db.put(k, d)
    db.create_index("n")
    db.create_index("m")
    for pred in ["n == 5", "n < 5", "n <= 5", "n > -5", "n >= -5", "n > 5", 'n >= "a"', 'n < "t"',
                 "n == null", "n <= null", "n >= false", "n < true", "n != 5", "n > 1 and m == 1"]:
        res = db.find(pred)
        expect = [k for k, d in sorted(docs.items()) if _eval(pred, d)]
        assert [k.decode() for k, _ in res.rows] == expect, pred
    assert str(db.find("n == 5").plan) == "index n"
    assert str(db.find("n != 5").plan) == "scan"
    assert str(db.find("n > 1 and m == 1").plan) == "index m"        # '==' beats a range
    assert str(db.find("n > 1 and m > 0").plan) == "index m"         # then the smaller path text
    assert str(db.find("exists n").plan) == "scan"
    assert db.find("n >= -100", limit=2).rows == [(b"d", docs["d"]), (b"e", docs["e"])]
    assert db.find("n >= -100", limit=0).rows == []
    assert db.find(And(Cmp(("n",), "==", 5), Cmp(("m",), "==", 1))).rows == []


def _eval(pred, doc):
    """A tiny independent oracle for the single-comparison predicates used above."""
    parts = [p.split() for p in pred.split(" and ")]
    ok = True
    for path, op, lit in parts:
        if path not in doc:
            return False
        x = doc[path]
        v = {"null": None, "true": True, "false": False}.get(lit)
        if lit not in ("null", "true", "false"):
            v = lit.strip('"') if lit.startswith('"') else int(lit)
        same = type(x) is type(v)
        if op == "==":
            r = same and x == v
        elif op == "!=":
            r = not (same and x == v)
        elif not same or isinstance(x, list):
            r = False
        elif x is None:
            r = op in ("<=", ">=")
        else:
            r = {"<": x < v, "<=": x <= v, ">": x > v, ">=": x >= v}[op]
        ok = ok and r
    return ok


def test_transactions_commit_and_rollback():
    db = Database.open()
    db.begin()
    assert kind_of(db.begin) == "txn-active" and kind_of(db.checkpoint) == "txn-active"
    db.put("a", 1)
    db.create_index("x")
    db.rollback()
    assert db.stat().pages == 1 and db.indexes() == [] and len(db) == 0
    db.begin()
    db.put("a", 1)
    assert db.commit() == (1, 2)
    assert len(db.wal_image()) == 2152


def test_automatic_checkpoint_at_the_wal_limit():
    db = Database.open()
    n = 0
    while db.stat().wal != 32 or n == 0:
        db.put("k", n)
        n += 1
        assert n < 1000
    # each commit appends 2120 bytes; the commit that reached the limit checkpointed at once
    assert n == -(-(WAL_LIMIT - 32) // 2120)
    assert len(db.db_image()) == 2048
    assert db.get("k") == n - 1


def test_reopen_from_files(tmp_path):
    db = Database.open()
    db.put("a", {"x": 1})
    db.create_index("x")
    db.save(tmp_path / "main.tdb", tmp_path / "main.twal")
    again = Database.open_files(str(tmp_path / "main.tdb"))
    assert again.get("a") == {"x": 1} and again.indexes()[0].entries == 1
    assert Database.open_files(str(tmp_path / "missing.tdb")).stat().pages == 1


def test_replace_frees_the_old_chain_before_allocating_the_new_one():
    doc = "x" * (2005 - 5)                        # serialises to 2005 bytes: two overflow pages
    db = Database.open()
    db.put("a", doc)
    assert (db.stat().pages, db.stat().root) == (4, 4)
    db.put("a", doc)
    assert (db.stat().pages, db.stat().free) == (4, 0)
    cell = db._primary().get(b"a")
    assert cell[1] == 3                             # the chain now starts at page 3 and runs 3 -> 2
    check_database(db)
