import pytest

from minisql.errors import SqlSyntaxError
from minisql.lexer import split_statements
from minisql.parser import parse_statement
from minisql import syntax as sx


def parse(sql):
    (tokens,) = split_statements(sql)
    return parse_statement(tokens)


def where(sql):
    return parse(f"select 1 from t where {sql}").where


def test_precedence_not_binds_looser_than_equality():
    node = where("not a = 1")
    assert isinstance(node, sx.Not) and isinstance(node.operand, sx.Bin)


def test_is_null_binds_looser_than_addition():
    node = where("a + 1 is null")
    assert isinstance(node, sx.IsNull) and node.operand.op == "+"


def test_relational_binds_tighter_than_equality():
    node = where("1 < 2 = 1")
    assert node.op == "=" and node.left.op == "<"


def test_unary_minus_binds_tighter_than_modulo():
    node = where("-5 % 3")
    assert node.op == "%" and isinstance(node.left, sx.Neg)


def test_not_like():
    node = where("a not like 'x%'")
    assert isinstance(node, sx.Like) and node.negated


def test_aggregate_name_is_identifier_without_paren():
    assert isinstance(where("count = 1").left, sx.Col)
    assert isinstance(parse("select count (*) from t").items[0].expr, sx.Agg)


def test_aliases_with_and_without_as():
    sel = parse("select a x, b as y from t u, v as w")
    assert [i.alias for i in sel.items] == ["x", "y"]
    assert [t.alias for t in sel.tables] == ["u", "w"]


def test_order_term_ordinal_and_alias_detection():
    sel = parse("select a from t order by 1, a, (1), 1 + 0 desc")
    assert [(t.ordinal, t.alias) for t in sel.order_by] == [
        (1, None), (None, "a"), (None, None), (None, None)]
    assert sel.order_by[3].descending


def test_join_on_is_recorded():
    sel = parse("select * from a inner join b on a.x = b.y")
    assert len(sel.tables) == 2 and sel.on is not None


@pytest.mark.parametrize(
    "sql",
    [
        "drop table t",
        "select",
        "select 1 from",
        "select a as left from t",
        "create table t (text text)",
        "create table t (a real)",
        "create table t (a)",
        "create table t ()",
        "insert into t (a) values (1)",
        "select a from t left join u on 1",
        "select a from t, u, v",
        "select a from t join u",
        "select a from t where a in (1)",
        "select a from t where a between 1 and 2",
        "select 'a' || 'b'",
        "select (select 1)",
        "select a from t limit -1",
        "select a from t offset 1",
        "select a from t having a > 1",
        "select a from t group by a + 1",
        "select foo(1)",
        "select * as x from t",
        "select 1.5",
        "select a b c from t",
        "select a from t where a is 1",
        "select a from t where a not 1",
        "update t set a.b = 1",
        "select $",
        "select 'abc",
        "select sum(*) from t",
    ],
)
def test_syntax_errors(sql):
    with pytest.raises(SqlSyntaxError):
        parse(sql)
