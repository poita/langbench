/// Unit tests for the query-line parser.
module test_query;

import sqlitefile;
import std.exception : assertThrown;

private bool bad(string line) @safe
{
    try
    {
        parseQuery(line);
        return false;
    }
    catch (QueryException)
        return true;
}

@safe unittest // dot commands and COUNT
{
    assert(parseQuery(".tables").kind == QueryKind.tables);
    auto s = parseQuery(".schema people");
    assert(s.kind == QueryKind.schema && s.name == "people");
    assert(bad(".SCHEMA people"));
    assert(bad(".schema"));
    assert(bad(".schema a b"));
    assert(bad(".schema people;"));
    assert(bad(".schema 9bad"));
    assert(bad(".tables x"));
    assert(bad(".nope"));
    auto c = parseQuery("count  People");
    assert(c.kind == QueryKind.count && c.name == "People");
    assert(bad("COUNT"));
    assert(bad("COUNT a b"));
    assert(bad("COUNTa"));
    assert(bad("DROP t"));
}

@safe unittest // SELECT shapes
{
    auto q = parseQuery("SELECT*FROM t");
    assert(q.star && q.name == "t" && q.where.length == 0);
    q = parseQuery("select  a ,b\t,c from t where a>=1 AND b IS NOT NULL and c = 'it''s' order by a desc limit 3");
    assert(!q.star && q.columns == ["a", "b", "c"]);
    assert(q.where.length == 3);
    assert(q.where[0].op == CmpOp.ge && q.where[0].literal.i == 1);
    assert(q.where[1].op == CmpOp.isNot && q.where[1].literal.isNull);
    assert(q.where[2].op == CmpOp.eq && cast(const(char)[]) q.where[2].literal.bytes == "it's");
    assert(q.hasOrder && q.orderColumn == "a" && q.descending);
    assert(q.hasLimit && q.limit == 3);
    q = parseQuery("SELECT a FROM t WHERE a='x'AND b=X'0aFF'");
    assert(q.where.length == 2 && q.where[1].literal.bytes == [0x0a, 0xff]);
    q = parseQuery("SELECT a FROM t WHERE a=-2.5e-3 AND b IS 1. AND c<+7");
    assert(q.where[0].literal.kind == ValueKind.real_);
    assert(q.where[1].op == CmpOp.is_ && q.where[1].literal.kind == ValueKind.real_);
    assert(q.where[2].op == CmpOp.lt && q.where[2].literal.i == 7);
}

@safe unittest // malformed SELECTs
{
    foreach (l; ["SELECT", "SELECT * t", "SELECTa FROM t", "SELECT a FROM", "SELECT a, FROM t",
            "SELECT a FROM t WHERE a == 1", "SELECT a FROM t WHERE a <> 1",
            "SELECT a FROM t WHERE a = .5", "SELECT a FROM t WHERE a = 1e",
            "SELECT a FROM t WHERE a = 'x", "SELECT a FROM t WHERE a = X'abc'",
            "SELECT a FROM t WHERE a = X'zz'", "SELECT a FROM t WHERE a = 1AND b = 2",
            "SELECT a FROM t WHERE a ISNULL", "SELECT a FROM t WHERE a = 1 AND",
            "SELECT a FROM t ORDERBY a", "SELECT a FROM t ORDER BY a ASC DESC",
            "SELECT a FROM t LIMIT -1", "SELECT a FROM t LIMIT3", "SELECT a FROM t LIMIT 3 x",
            "SELECT a FROM t LIMIT 3 ORDER BY a", "SELECT 1a FROM t"])
        assert(bad(l), l);
}

@safe unittest // INDEX
{
    auto q = parseQuery("INDEX ix 45");
    assert(q.kind == QueryKind.index && q.name == "ix" && q.literal.i == 45);
    q = parseQuery("INDEX ix 'abc'");
    assert(q.literal.kind == ValueKind.text);
    q = parseQuery("index ix null");
    assert(q.literal.isNull);
    assert(bad("INDEX ix"));
    assert(bad("INDEX ix 1 2"));
    assert(bad("INDEX ix .5"));
}
