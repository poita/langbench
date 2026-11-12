import pytest

from sqlitefile.errors import QueryError
from sqlitefile.query import (
    Condition, CountQuery, IndexQuery, OrderBy, SchemaQuery, SelectQuery, TablesQuery, parse_query,
)  # fmt: skip


def test_dot_commands():
    assert parse_query(".tables") == TablesQuery()
    assert parse_query(".schema people") == SchemaQuery("people")


def test_full_select_with_odd_spacing():
    q = parse_query("select a ,b\tFROM  t where a>=1 AND b IS\tnot NULL and c!='it''s' order by a desc LIMIT 3")
    assert q == SelectQuery(
        "t", ("a", "b"),
        (Condition("a", ">=", 1), Condition("b", "IS NOT", None), Condition("c", "!=", "it's")),
        OrderBy("a", True), 3,
    )  # fmt: skip


def test_star_without_spaces():
    assert parse_query("SELECT*FROM t") == SelectQuery("t", None)


def test_literals():
    lit = lambda s: parse_query(f"INDEX i {s}").literal  # noqa: E731
    assert lit("-5") == -5 and type(lit("+7")) is int
    assert lit("1.") == 1.0 and type(lit("1.")) is float
    assert lit("-2.5e-3") == -0.0025
    assert lit("X'0aFF'") == b"\x0a\xff" and lit("x''") == b""
    assert lit("null") is None
    assert lit("''''") == "'"
    assert lit("-9223372036854775808") == -(2**63)


@pytest.mark.parametrize(
    "line",
    [
        "", "SELECTa", "SELECT * FROM", "SELECT FROM t", "SELECT a, FROM t", "SELECT * FROM t WHERE",
        "SELECT * FROM t WHERE a == 1", "SELECT * FROM t WHERE a <> 1", "SELECT * FROM t WHERE a = .5",
        "SELECT * FROM t WHERE a = 1e", "SELECT * FROM t WHERE a = 'x", "SELECT * FROM t WHERE a = x'abc'",
        "SELECT * FROM t WHERE a = X'zz'", "SELECT * FROM t WHERE a = 1AND b = 2",
        "SELECT * FROM t WHERE a ISNOT 1", "SELECT * FROM t ORDERBY a", "SELECT * FROM t ORDER BY a ASC DESC",
        "SELECT * FROM t LIMIT -1", "SELECT * FROM t LIMIT3", "SELECT * FROM t LIMIT 1 2",
        "SELECT * FROM 9t", "COUNT", "COUNT a b", "INDEX i", "INDEX i 1 2",
        ".SCHEMA t", ".TABLES", ".tables x", ".schema", ".schema a b", ".schema 9bad", ".schema t;", ".dump",
        "DROP TABLE t",
    ],
)  # fmt: skip
def test_malformed(line):
    with pytest.raises(QueryError):
        parse_query(line)


def test_count_and_index():
    assert parse_query("COUNT t") == CountQuery("t")
    assert parse_query("INDEX idx'abc'") == IndexQuery("idx", "abc")
