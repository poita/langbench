module tests.parser_test;

import minisql.ast;
import minisql.errors;
import minisql.lexer;
import minisql.parser;

private Statement parse(string s)
{
    return parseStatement(tokenize(s));
}

private bool rejects(string s)
{
    try
    {
        parse(s);
        return false;
    }
    catch (SqlException)
        return true;
}

unittest // precedence: NOT binds looser than =, IS NULL looser than +
{
    auto st = cast(SelectStmt) parse("SELECT NOT a = 1");
    auto e = st.items[0].expr;
    assert(e.kind == ExprKind.not && e.lhs.kind == ExprKind.binary && e.lhs.op == BinOp.eq);

    st = cast(SelectStmt) parse("SELECT a + 1 IS NULL");
    assert(st.items[0].expr.kind == ExprKind.isNull);

    st = cast(SelectStmt) parse("SELECT 1 < 2 = 1");
    e = st.items[0].expr;
    assert(e.op == BinOp.eq && e.lhs.op == BinOp.lt);

    st = cast(SelectStmt) parse("SELECT -5 % 3");
    e = st.items[0].expr;
    assert(e.op == BinOp.mod && e.lhs.kind == ExprKind.neg);
}

unittest // select clauses
{
    auto st = cast(SelectStmt) parse(
        "SELECT a x, b AS y, * FROM emp e INNER JOIN dept AS d ON e.d = d.id " ~
        "WHERE a > 1 GROUP BY a, e.b HAVING COUNT(*) > 1 ORDER BY 1 DESC, x LIMIT 5 OFFSET 2");
    assert(st.items.length == 3 && st.items[0].alias_ == "x" && st.items[2].star);
    assert(st.from.length == 2 && st.from[0].effective == "e" && st.from[1].effective == "d");
    assert(st.on !is null && st.where_ !is null && st.having !is null);
    assert(st.groupBy.length == 2 && st.groupBy[1].qualifier == "e");
    assert(st.orderBy.length == 2 && st.orderBy[0].desc && !st.orderBy[1].desc);
    assert(st.hasLimit && st.limit == 5 && st.offset == 2);
}

unittest // other statements
{
    auto c = cast(CreateStmt) parse("create table T (A integer, b text)");
    assert(c.table == "t" && c.columns == ["a", "b"]);
    auto i = cast(InsertStmt) parse("INSERT INTO t VALUES (1, 'x'), (2, NULL)");
    assert(i.rows.length == 2 && i.rows[1].length == 2);
    auto u = cast(UpdateStmt) parse("UPDATE t SET a = 1, b = 2 WHERE a = 0");
    assert(u.columns.length == 2 && u.where_ !is null);
    auto d = cast(DeleteStmt) parse("DELETE FROM t");
    assert(d.where_ is null);
}

unittest // aggregate names are only functions when followed by `(`
{
    auto st = cast(SelectStmt) parse("SELECT count FROM t");
    assert(st.items[0].expr.kind == ExprKind.column);
    st = cast(SelectStmt) parse("SELECT count (*) FROM t");
    assert(st.items[0].expr.kind == ExprKind.aggregate && st.items[0].expr.star);
}

unittest // syntax errors
{
    foreach (bad; [
        "", "DROP TABLE t", "SELECT", "SELECT a FROM", "SELECT a FROM t LEFT JOIN u ON 1",
        "SELECT * FROM a, b, c", "SELECT a FROM t WHERE a IN (1)", "SELECT a FROM t HAVING a",
        "SELECT a FROM t LIMIT -1", "SELECT a FROM t GROUP BY a + 1", "SELECT foo(1)",
        "SELECT SUM(*)", "SELECT a AS left FROM t", "CREATE TABLE t (text TEXT)",
        "CREATE TABLE t (a REAL)", "CREATE TABLE t ()", "INSERT INTO t (a) VALUES (1)",
        "SELECT 1.5", "SELECT * AS x FROM t", "SELECT a NOT 1", "SELECT 'abc",
        "SELECT a FROM t JOIN u", "SELECT a b c FROM t", "SELECT \"a\"", "SELECT 1 || 2",
        "SELECT a FROM t OFFSET 1",
    ])
        assert(rejects(bad), bad);
}
