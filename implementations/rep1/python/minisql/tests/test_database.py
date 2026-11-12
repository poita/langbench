import pytest

from minisql import Database, Real, SqlSemanticError, SqlSyntaxError, format_results

SETUP = """
CREATE TABLE emp (id INTEGER, name TEXT, dept TEXT, salary INTEGER);
INSERT INTO emp VALUES (1,'ann','eng',120),(2,'bob','ops',90),
                       (3,'cy','eng',NULL),(4,'dee',NULL,100);
"""


@pytest.fixture
def emp(db):
    db.execute(SETUP)
    return db


def test_query_returns_python_values(emp):
    assert emp.query("SELECT name, salary FROM emp WHERE id < 3") == [
        ("ann", 120), ("bob", 90)]


def test_avg_returns_real(emp):
    (row,) = emp.query("SELECT AVG(salary) FROM emp")
    assert row == (Real(10333),)


def test_failed_statement_has_no_effect(emp):
    results = emp.execute("INSERT INTO emp VALUES (9,'x','y',1),(10);")
    assert isinstance(results[0].error, SqlSemanticError)
    assert emp.query("SELECT COUNT(*) FROM emp") == [(4,)]


def test_query_raises_on_error(emp):
    with pytest.raises(SqlSemanticError):
        emp.query("SELECT nosuch FROM emp")
    with pytest.raises(SqlSyntaxError):
        emp.query("SELECT FROM")
    with pytest.raises(ValueError):
        emp.query("DELETE FROM emp")


def test_table_names(emp):
    assert emp.table_names() == ["emp"]


def test_update_swaps_using_old_values(db):
    db.execute("CREATE TABLE t (a INTEGER, b INTEGER); INSERT INTO t VALUES (1, 2);")
    db.execute("UPDATE t SET a = b, b = a;")
    assert db.query("SELECT a, b FROM t") == [(2, 1)]


def test_update_and_delete_keep_row_order(db):
    db.execute("CREATE TABLE t (a INTEGER); INSERT INTO t VALUES (1),(2),(3),(4);")
    db.execute("UPDATE t SET a = a * 10 WHERE a = 2; DELETE FROM t WHERE a = 3;")
    assert db.query("SELECT a FROM t") == [(1,), (20,), (4,)]


def test_qualified_names_in_update_and_delete(db):
    db.execute("CREATE TABLE acct (bal INTEGER); INSERT INTO acct VALUES (1),(2);")
    db.execute("UPDATE acct SET bal = acct.bal + 5 WHERE acct.bal = 1;")
    db.execute("DELETE FROM acct WHERE acct.bal = 6;")
    assert db.query("SELECT bal FROM acct") == [(2,)]


def test_hash_join_preserves_nested_loop_order(db):
    db.execute("""
        CREATE TABLE a (x INTEGER, s TEXT); CREATE TABLE b (y INTEGER, t TEXT);
        INSERT INTO a VALUES (3,'c'),(1,'a'),(2,'b'),(1,'aa'),(NULL,'n');
        INSERT INTO b VALUES (1,'p'),(2,'q'),(1,'r'),(3,'s'),(NULL,'m');
    """)
    rows = db.query("SELECT s, t FROM a, b WHERE x = y AND t != 'p'")
    assert rows == [("c", "s"), ("a", "r"), ("b", "q"), ("aa", "r")]
    same = db.query("SELECT s, t FROM a JOIN b ON x = y WHERE t != 'p'")
    assert same == rows


def test_join_with_expression_keys_and_residual(db):
    db.execute("""
        CREATE TABLE a (x INTEGER); CREATE TABLE b (y INTEGER);
        INSERT INTO a VALUES (1),(2),(3); INSERT INTO b VALUES (2),(3),(4);
    """)
    rows = db.query("SELECT x, y FROM a, b WHERE x + 1 = y AND x + y > 4")
    assert rows == [(2, 3), (3, 4)]
    assert db.query("SELECT x, y FROM a, b WHERE x < y AND y < 4") == [
        (1, 2), (1, 3), (2, 3)]


def test_self_join_needs_aliases(db):
    db.execute("CREATE TABLE a (x INTEGER); INSERT INTO a VALUES (1),(2);")
    assert db.query("SELECT p.x, q.x FROM a p, a q WHERE p.x < q.x") == [(1, 2)]
    for bad in ("SELECT * FROM a, a", "SELECT x FROM a p, a q",
                "SELECT a.x FROM a p"):
        with pytest.raises(SqlSemanticError):
            db.query(bad)


def test_group_by_orders_groups_nulls_first(emp):
    rows = emp.query("SELECT dept, COUNT(*), SUM(salary) FROM emp GROUP BY dept")
    assert rows == [(None, 1, 100), ("eng", 2, 120), ("ops", 1, 90)]


def test_one_and_text_one_are_different_groups(db):
    db.execute("CREATE TABLE t (a INTEGER, b TEXT);")
    db.execute("INSERT INTO t VALUES (1, '1'), (1, '1');")
    assert db.query("SELECT a, COUNT(*) FROM t GROUP BY a") == [(1, 2)]


def test_aggregate_over_empty_table(db):
    db.execute("CREATE TABLE t (a INTEGER);")
    assert db.query("SELECT COUNT(*), SUM(a), MIN(a), AVG(a) FROM t") == [
        (0, None, None, None)]
    assert db.query("SELECT a FROM t GROUP BY a") == []


def test_min_max_on_text(emp):
    assert emp.query("SELECT MIN(name), MAX(name) FROM emp") == [("ann", "dee")]


def test_having_and_order_by_aggregate(emp):
    rows = emp.query(
        "SELECT dept, COUNT(*) AS n FROM emp GROUP BY dept HAVING COUNT(*) >= 1 "
        "ORDER BY n DESC, dept")
    assert rows == [("eng", 2), (None, 1), ("ops", 1)]


def test_order_by_nulls_and_stability(db):
    db.execute("""CREATE TABLE t (k INTEGER, v INTEGER);
        INSERT INTO t VALUES (2,10),(NULL,20),(1,30),(2,40),(1,NULL);""")
    assert db.query("SELECT k, v FROM t ORDER BY k") == [
        (None, 20), (1, 30), (1, None), (2, 10), (2, 40)]
    assert db.query("SELECT k, v FROM t ORDER BY k DESC") == [
        (2, 10), (2, 40), (1, 30), (1, None), (None, 20)]


def test_order_by_ordinal_alias_and_constant_expression(db):
    db.execute("CREATE TABLE a (x INTEGER, y INTEGER); INSERT INTO a VALUES (2,1),(1,2);")
    assert db.query("SELECT *, x FROM a ORDER BY 3") == [(1, 2, 1), (2, 1, 2)]
    assert db.query("SELECT y AS z FROM a ORDER BY z") == [(1,), (2,)]
    assert db.query("SELECT x FROM a ORDER BY 1 + 0") == [(2,), (1,)]
    assert db.query("SELECT x FROM a ORDER BY -y") == [(1,), (2,)]
    for k in (0, 3):
        with pytest.raises(SqlSemanticError):
            db.query(f"SELECT x, y FROM a ORDER BY {k}")


def test_limit_offset(db):
    db.execute("CREATE TABLE t (a INTEGER); INSERT INTO t VALUES (1),(2),(3),(4);")
    assert db.query("SELECT a FROM t LIMIT 2 OFFSET 1") == [(2,), (3,)]
    assert db.query("SELECT a FROM t LIMIT 0") == []
    assert db.query("SELECT a FROM t ORDER BY a DESC LIMIT 1") == [(4,)]


def test_select_without_from(db):
    assert db.query("SELECT 1 + 1, -7 / 2, -7 % 3, 7 % -3, 1 / 0, 5 % 0") == [
        (2, -3, -1, 1, None, None)]
    assert db.query("SELECT 1 WHERE 0") == []
    for bad in ("SELECT a", "SELECT *"):
        with pytest.raises(SqlSemanticError):
            db.query(bad)


def test_three_valued_logic(db):
    row, = db.query(
        "SELECT NULL AND 0, NULL AND 1, NULL OR 1, NULL OR 0, NOT NULL, "
        "NULL = NULL, NULL IS NULL, 1 IS NOT NULL")
    assert row == (0, None, 1, None, None, None, 1, 1)


def test_comparison_across_types(db):
    row, = db.query("SELECT 1 = '1', 1 < 'a', 100 < '0', 'B' < 'a', '' < 'a'")
    assert row == (0, 1, 1, 1, 1)


def test_like_on_integers_and_case(db):
    row, = db.query("SELECT 12345 LIKE '12%', 'APPLE' LIKE 'apple', 'a' NOT LIKE 'b'")
    assert row == (1, 1, 1)


def test_semantic_errors(emp):
    bad = [
        "SELECT * FROM nosuch",
        "SELECT nosuch FROM emp",
        "SELECT emp.nosuch FROM emp",
        "SELECT x.id FROM emp",
        "SELECT name FROM emp GROUP BY dept",
        "SELECT name, COUNT(*) FROM emp",
        "SELECT * FROM emp WHERE COUNT(*) > 1",
        "SELECT SUM(COUNT(*)) FROM emp",
        "UPDATE emp SET salary = COUNT(*)",
        "UPDATE emp SET nosuch = 1",
        "DELETE FROM emp WHERE SUM(id) > 1",
        "INSERT INTO emp VALUES (id, 'a', 'b', 1)",
        "INSERT INTO emp VALUES (COUNT(*), 'a', 'b', 1)",
        "INSERT INTO nosuch VALUES (1)",
        "CREATE TABLE emp (a INTEGER)",
        "CREATE TABLE t2 (a INTEGER, A TEXT)",
        "SELECT DISTINCT id FROM emp",  # 'distinct' is just an unknown column
    ]
    for sql in bad:
        with pytest.raises(SqlSemanticError):
            emp.query(sql) if sql.startswith("SELECT") else _raise(emp, sql)


def _raise(db, sql):
    (result,) = db.execute(sql)
    raise result.error


def test_errors_reported_even_on_empty_tables(db):
    db.execute("CREATE TABLE t (a INTEGER);")
    with pytest.raises(SqlSemanticError):
        db.query("SELECT b FROM t")


def test_ambiguous_column(db):
    db.execute("CREATE TABLE a (x INTEGER); CREATE TABLE b (x INTEGER);")
    with pytest.raises(SqlSemanticError):
        db.query("SELECT x FROM a, b")
    assert db.query("SELECT a.x, b.x FROM a, b") == []


def test_case_insensitive_names(db):
    db.execute("create table Emp (Id integer); insert into EMP values (1);")
    assert db.query("SELECT EMP.id FROM emp") == [(1,)]


def test_column_may_be_named_like_an_aggregate(db):
    db.execute("CREATE TABLE t (count INTEGER); INSERT INTO t VALUES (5);")
    assert db.query("SELECT count, COUNT(count) FROM t GROUP BY count") == [(5, 1)]


def test_format_results():
    out = format_results(Database().execute(
        "SELECT 1, 'a', NULL; SELECT nosuch; CREATE TABLE t (a INTEGER); SELECT * FROM t;"))
    assert out == "1\ta\tNULL\n-- 1 rows\nerror\n-- 0 rows\n"


def test_avg_formatting_never_negative_zero(db):
    db.execute("CREATE TABLE t (a INTEGER);")
    db.execute("INSERT INTO t VALUES (-1)," + ",".join(["(0)"] * 200) + ";")
    assert format_results(db.execute("SELECT AVG(a) FROM t;")) == "0.00\n-- 1 rows\n"


def test_avg_compares_with_integers(db):
    db.execute("CREATE TABLE t (a INTEGER); INSERT INTO t VALUES (1),(3);")
    assert db.query("SELECT AVG(a) = 2, AVG(a) > 1, AVG(a) IS NULL FROM t") == [(1, 1, 0)]
