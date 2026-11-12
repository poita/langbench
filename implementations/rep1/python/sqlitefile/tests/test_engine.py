import pytest

from dbbuilder import DbBuilder
from sqlitefile import Database, QueryError

import conftest


def test_spec_worked_example(mini):
    assert mini.run(".tables") == ["people"]
    assert mini.run("SELECT * FROM people") == [
        "1\tAda\t36\t1.65\t000102",
        "2\tGrace\t45\t1.7\tNULL",
        "3\tAlan\tNULL\t1.8\t",
        "6\t\t0\t0.0\t7F",
    ]
    assert mini.run("SELECT name,height FROM people ORDER BY height DESC LIMIT 2") == [
        "Alan\t1.8",
        "Grace\t1.7",
    ]
    assert mini.run("SELECT name FROM people WHERE age IS NULL") == ["Alan"]
    assert mini.run("SELECT name FROM people WHERE age > 40") == ["Grace"]
    assert mini.run("SELECT rowid,name FROM people WHERE photo IS NOT NULL") == [
        "1\tAda", "3\tAlan", "6\t",
    ]  # fmt: skip
    assert mini.run("INDEX people_age 45") == ["2\tGrace\t45\t1.7\tNULL"]
    assert mini.run("COUNT people") == ["4"]


def test_schema_output_is_sql_plus_semicolon(mini):
    # A multi-line statement is a single entry containing embedded newlines.
    assert mini.run(".schema people") == [
        conftest.PEOPLE_SQL + ";",
        "CREATE INDEX people_age ON people(age);",
    ]
    assert mini.run(".schema people_age") == []
    assert mini.run(".schema nosuch") == []


@pytest.mark.parametrize(
    "line",
    [
        "SELECT nope FROM people", "SELECT * FROM nosuch", "COUNT nosuch", "INDEX nosuch 1",
        "SELECT * FROM sqlite_schema", "COUNT people_age", "SELECT * FROM people_age",
        "SELECT _rowid_ FROM people", "SELECT oid FROM people", "INDEX people 1",
    ],
)
def test_query_errors(mini, line):
    with pytest.raises(QueryError):
        mini.run(line)


def test_where_semantics(mini):
    assert mini.run("SELECT id FROM people WHERE age = 0") == ["6"]
    assert mini.run("SELECT id FROM people WHERE age != 0") == ["1", "2"]  # NULL is never != 0
    assert mini.run("SELECT id FROM people WHERE age IS NOT 0") == ["1", "2", "3"]
    assert mini.run("SELECT id FROM people WHERE age = NULL") == []
    assert mini.run("SELECT id FROM people WHERE age >= '36'") == ["1", "2"]  # '36' -> 36
    assert mini.run("SELECT id FROM people WHERE name > 5") == ["1", "2", "3"]  # 5 -> '5' for TEXT
    assert mini.run("SELECT id FROM people WHERE height = 0") == ["6"]
    assert mini.run("SELECT id FROM people WHERE photo = X''") == ["3"]
    assert mini.run("SELECT id FROM people WHERE age > 10 AND age < 40") == ["1"]


def test_order_by_ties_break_by_rowid_both_ways():
    b = DbBuilder()
    b.add_table("t", "CREATE TABLE t(k)", [(i, [i % 2 or None]) for i in range(1, 8)])
    db = Database(b.build())
    assert db.run("SELECT rowid FROM t ORDER BY k") == ["2", "4", "6", "1", "3", "5", "7"]
    assert db.run("SELECT rowid FROM t ORDER BY k DESC") == ["1", "3", "5", "7", "2", "4", "6"]
    assert db.run("SELECT rowid FROM t ORDER BY k DESC LIMIT 2") == ["1", "3"]
    assert db.run("SELECT rowid FROM t LIMIT 0") == []


def test_negative_and_extreme_rowids_in_multi_level_tree():
    b = DbBuilder(512)
    ids = [-(2**63), -1000, -1, 0, 1, 127, 128, 2**31, 2**40, 2**63 - 1] + list(range(200, 260))
    b.add_table("t", "CREATE TABLE t(v)", [(i, [i]) for i in sorted(ids)])
    db = Database(b.build())
    assert db.run("COUNT t") == [str(len(ids))]
    assert db.run("SELECT rowid FROM t")[:3] == [str(-(2**63)), "-1000", "-1"]
    assert db.run("SELECT rowid FROM t")[-1] == str(2**63 - 1)
    assert db.run("SELECT v FROM t WHERE v = 9223372036854775807") == [str(2**63 - 1)]
    assert db.run("SELECT v FROM t WHERE v = '9223372036854775806'") == []


def test_short_records_read_missing_columns_as_null():
    b = DbBuilder()
    b.add_table("t", "CREATE TABLE t(a, b DEFAULT NULL)", [(1, ["x"]), (2, ["y", "z"])])
    assert Database(b.build()).run("SELECT a,b FROM t") == ["x\tNULL", "y\tz"]


@pytest.mark.parametrize("page_size", [512, 1024, 4096, 65536])
def test_overflow_text_blob_and_index_keys(page_size):
    b = DbBuilder(page_size)
    u = page_size
    x_table = u - 35
    x_index = ((u - 12) * 64) // 255 - 23
    sizes = [10, x_table - 20, x_table, x_table + 1, 3 * u + 17]
    rows = [(i + 1, [None, "t" * n, bytes(range(256)) * (n // 256) + bytes(n % 256)]) for i, n in enumerate(sizes)]
    b.add_table("t", "CREATE TABLE t(id INTEGER PRIMARY KEY, s TEXT, b BLOB)", rows)
    keys = sorted(["k" * n for n in (5, x_index - 8, x_index, x_index + 1, 2 * u)])
    kt = [(i + 1, [k]) for i, k in enumerate(keys)]
    b.add_table("kt", "CREATE TABLE kt(k TEXT)", kt)
    b.add_index("kt_k", "kt", "CREATE INDEX kt_k ON kt(k)", [[k, rowid] for rowid, (k,) in kt])
    db = Database(b.build())
    for rowid, (_, s, blob) in rows:
        assert db.run(f"SELECT s FROM t WHERE rowid = {rowid}") == [s]
        assert db.run(f"SELECT b FROM t WHERE rowid = {rowid}") == [blob.hex().upper()]
    for rowid, (k,) in kt:
        assert db.run(f"INDEX kt_k '{k}'") == [k]
    assert db.run(f"INDEX kt_k '{'z' * 4}'") == []


def test_index_lookup_spans_interior_cells():
    b = DbBuilder(1024)
    rows = [(i, [i % 3, f"r{i}"]) for i in range(1, 40)]
    b.add_table("t", "CREATE TABLE t(g INTEGER, n TEXT)", rows)
    entries = sorted([g, rowid] for rowid, (g, _) in rows)
    b.add_index("t_g", "t", "CREATE INDEX t_g ON t(g)", entries)
    db = Database(b.build())
    for g in (0, 1, 2):
        expected = [f"{g}\tr{i}" for i in range(1, 40) if i % 3 == g]
        assert db.run(f"INDEX t_g {g}") == expected
        assert db.run(f"INDEX t_g '{g}'") == expected  # text literal gets INTEGER affinity
    assert db.run("INDEX t_g 7") == []
    assert db.run("INDEX t_g NULL") == []


def test_index_error_cases():
    b = DbBuilder()
    b.add_table("t", "CREATE TABLE t(a PRIMARY KEY, b, c)", [(1, [1, 2, 3])])
    b.add_index("sqlite_autoindex_t_1", "t", None, [[1, 1]])
    b.add_index("t_bc", "t", "CREATE INDEX t_bc ON t(b, c)", [[2, 3, 1]])
    b.add_schema_only("view", "v", "v", "CREATE VIEW v AS SELECT * FROM t")
    db = Database(b.build())
    for line in ("INDEX sqlite_autoindex_t_1 1", "INDEX t_bc 2", "INDEX t 1", "INDEX v 1", "SELECT * FROM v"):
        with pytest.raises(QueryError):
            db.run(line)
    assert db.run(".tables") == ["t"]
    assert db.run(".schema v") == ["CREATE VIEW v AS SELECT * FROM t;"]


def test_tables_sorted_and_filters_sqlite_prefix():
    b = DbBuilder()
    for name in ("b", "B2", "sqlite_sequence", "SQLite_x", "a"):
        b.add_table(name, f"CREATE TABLE {name}(x)", [])
    db = Database(b.build())
    assert db.run(".tables") == ["B2", "a", "b"]
    assert db.run("COUNT sqlite_sequence") == ["0"]
    assert db.run("SELECT * FROM SQLITE_SEQUENCE") == []
