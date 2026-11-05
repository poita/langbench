module tests.database_test;

import minisql;

private string run(string script)
{
    return (new Database).run(script);
}

unittest // library example from the README
{
    auto db = new Database;
    db.execute("CREATE TABLE t (a INTEGER, b TEXT)");
    db.execute("INSERT INTO t VALUES (1, 'x'), (2, 'y')");
    auto res = db.execute("SELECT b FROM t WHERE a > 1");
    assert(res.isQuery && res.rowCount == 1 && res.row(0)[0].str == "y");
}

unittest // execute throws on bad statements and leaves the database intact
{
    auto db = new Database;
    db.execute("CREATE TABLE t (a INTEGER)");
    bool threw = false;
    try
        db.execute("INSERT INTO t VALUES (1), (2, 3)");
    catch (SqlException)
        threw = true;
    assert(threw);
    assert(db.execute("SELECT COUNT(*) FROM t").row(0)[0].num == 0);
    assert(db.hasTable("T"));
    assert(!db.hasTable("u"));
}

unittest // spec example 1
{
    immutable script = "
CREATE TABLE emp (id INTEGER, name TEXT, dept TEXT, salary INTEGER);
INSERT INTO emp VALUES (1, 'ann', 'eng', 120), (2, 'bob', 'ops', 90), (3, 'cy', 'eng', NULL), (4, 'dee', NULL, 100);
SELECT name, salary FROM emp WHERE salary >= 100 ORDER BY salary DESC;
SELECT dept, COUNT(*), SUM(salary), AVG(salary) FROM emp GROUP BY dept;
SELECT * FROM nosuch;
UPDATE emp SET salary = salary + 5 WHERE dept = 'eng';
SELECT id, salary FROM emp;
";
    assert(run(script) == "ann\t120\ndee\t100\n-- 2 rows\n" ~
            "NULL\t1\t100\t100.00\neng\t2\t120\t120.00\nops\t1\t90\t90.00\n-- 3 rows\n" ~
            "error\n1\t125\n2\t90\n3\tNULL\n4\t100\n-- 4 rows\n");
}

unittest // spec example 2: joins, ordering, arithmetic
{
    immutable script = "
CREATE TABLE a (x INTEGER, s TEXT);
CREATE TABLE b (y INTEGER, t TEXT);
INSERT INTO a VALUES (3, 'c'), (1, 'a'), (2, 'b'), (1, 'aa');
INSERT INTO b VALUES (1, 'p'), (2, 'q'), (1, 'r'), (3, 's');
SELECT s, t FROM a, b WHERE x = y AND t != 'p';
SELECT p.s, q.s FROM a p INNER JOIN a q ON p.x = q.x AND p.s < q.s;
SELECT x, COUNT(*) AS n FROM a, b WHERE x = y GROUP BY x ORDER BY n DESC, x LIMIT 2;
SELECT 7 / 2, -7 / 2, 7 % -3, 1 / 0, 'B' < 'a', 1 < 'a', NULL = NULL, 'Ab_c' LIKE 'ab%';
";
    assert(run(script) == "c\ts\na\tr\nb\tq\naa\tr\n-- 4 rows\n" ~
            "a\taa\n-- 1 rows\n1\t4\n2\t1\n-- 2 rows\n" ~
            "3\t-3\t1\tNULL\t1\t1\tNULL\t1\n-- 1 rows\n");
}

unittest // three-valued logic
{
    assert(run("SELECT NULL AND 0, NULL AND 1, NULL OR 1, NULL OR 0, NOT NULL, 0 AND NULL;") ==
            "0\tNULL\t1\tNULL\tNULL\t0\n-- 1 rows\n");
}

unittest // hash join keeps nested-loop order, skips NULL keys, keeps types apart
{
    immutable script = "
CREATE TABLE a (k INTEGER, v TEXT);
CREATE TABLE b (k INTEGER, w TEXT);
INSERT INTO a VALUES (1, 'a1'), (NULL, 'an'), (2, 'a2'), (1, 'a3'), (3, '1');
INSERT INTO b VALUES (1, 'b1'), (NULL, 'bn'), (1, 'b2'), (2, 'b3');
SELECT v, w FROM a, b WHERE a.k = b.k;
SELECT v, w FROM a JOIN b ON a.k + 1 = b.k AND w != 'b1';
SELECT v, w FROM a, b WHERE a.v = b.k;
";
    assert(run(script) == "a1\tb1\na1\tb2\na2\tb3\na3\tb1\na3\tb2\n-- 5 rows\n" ~
            "a1\tb3\na3\tb3\n-- 2 rows\n" ~ "-- 0 rows\n" ~ "");
}

unittest // aggregates and AVG rounding
{
    immutable script = "
CREATE TABLE t (g INTEGER, v INTEGER);
INSERT INTO t VALUES (1,1),(1,1),(1,1),(1,1),(1,1),(1,1),(1,1),(1,2);
INSERT INTO t VALUES (2,-1),(2,-2),(3,NULL);
SELECT g, AVG(v), SUM(v), COUNT(v), COUNT(*), MIN(v), MAX(v) FROM t GROUP BY g;
SELECT AVG(v) FROM t WHERE g = 1 AND v = 1;
SELECT COUNT(*), SUM(v), AVG(v), MIN(v) FROM t WHERE g = 99;
SELECT g FROM t GROUP BY g HAVING 1.13 = AVG(v);
";
    assert(run(script) ==
            "1\t1.13\t9\t8\t8\t1\t2\n2\t-1.50\t-3\t2\t2\t-2\t-1\n3\tNULL\tNULL\t0\t1\tNULL\tNULL\n-- 3 rows\n" ~
            "1.00\n-- 1 rows\n0\tNULL\tNULL\tNULL\n-- 1 rows\n" ~ "error\n");
}

unittest // average that rounds to zero prints 0.00
{
    string s = "CREATE TABLE t (v INTEGER);";
    foreach (i; 0 .. 200)
        s ~= "INSERT INTO t VALUES (0);";
    s ~= "INSERT INTO t VALUES (-1); SELECT AVG(v) FROM t;";
    assert(run(s) == "0.00\n-- 1 rows\n");
}

unittest // ORDER BY: aliases, ordinals, NULL placement, stability
{
    immutable script = "
CREATE TABLE t (k INTEGER, v INTEGER);
INSERT INTO t VALUES (2, 10), (NULL, 20), (1, 30), (2, 40), (1, NULL);
SELECT k, v FROM t ORDER BY k;
SELECT k, v FROM t ORDER BY k DESC, v DESC;
SELECT v AS w FROM t ORDER BY w DESC LIMIT 2;
SELECT *, k FROM t ORDER BY 3, 2 LIMIT 2 OFFSET 1;
SELECT k FROM t ORDER BY 1 + 0;
SELECT k FROM t ORDER BY 2;
";
    assert(run(script) ==
            "NULL\t20\n1\t30\n1\tNULL\n2\t10\n2\t40\n-- 5 rows\n" ~
            "2\t40\n2\t10\n1\t30\n1\tNULL\nNULL\t20\n-- 5 rows\n" ~
            "40\n30\n-- 2 rows\n" ~
            "1\tNULL\t1\n1\t30\t1\n-- 2 rows\n" ~
            "2\nNULL\n1\n2\n1\n-- 5 rows\n" ~ "error\n");
}

unittest // UPDATE reads old values; DELETE keeps order; failed statements change nothing
{
    immutable script = "
CREATE TABLE t (a INTEGER, b INTEGER);
INSERT INTO t VALUES (1, 2), (3, 4), (5, 6);
UPDATE t SET a = b, b = a WHERE t.a < 4;
DELETE FROM t WHERE a = 4;
UPDATE t SET a = COUNT(*);
UPDATE t SET nope = 1;
SELECT a, b FROM t;
";
    assert(run(script) == "error\nerror\n2\t1\n5\t6\n-- 2 rows\n");
}

unittest // errors
{
    immutable script = "
CREATE TABLE t (a INTEGER, b TEXT);
SELECT c FROM t;
SELECT a FROM t, t;
SELECT t.a FROM t x;
SELECT b, COUNT(*) FROM t;
SELECT COUNT(COUNT(*)) FROM t;
SELECT a FROM t WHERE SUM(a) > 1;
SELECT a FROM t GROUP BY b;
INSERT INTO t VALUES (a, 'x');
CREATE TABLE T (z INTEGER);
CREATE TABLE u (q INTEGER, Q TEXT);
SELECT * ;
";
    assert(run(script) == "error\nerror\nerror\nerror\nerror\nerror\nerror\nerror\nerror\nerror\nerror\n");
}

unittest // an unterminated string poisons the rest of the input
{
    assert(run("SELECT 1; SELECT 'oops; SELECT 2;") == "1\n-- 1 rows\nerror\n");
    assert(run("SELECT 1 @ 2; SELECT 3") == "error\n3\n-- 1 rows\n");
}

unittest // empty input and comments
{
    assert(run("") == "");
    assert(run("  -- just a comment ; \n ;; ") == "");
}

unittest // SELECT without FROM
{
    assert(run("SELECT 1 + 1; SELECT 1 WHERE 0; SELECT COUNT(*);") ==
            "2\n-- 1 rows\n-- 0 rows\n1\n-- 1 rows\n");
}

unittest // LIKE converts integers to text
{
    assert(run("SELECT 12345 LIKE '12%', 'É' LIKE 'é', 'abc' NOT LIKE 'a_c', NULL LIKE 'a';") ==
            "1\t0\t0\tNULL\n-- 1 rows\n");
}

unittest // text order and the type order
{
    assert(run("SELECT 1 = '1', 100 < '0', 'Z' < 'z', '' < 'a', 'ab' < 'b';") ==
            "0\t1\t1\t1\t1\n-- 1 rows\n");
}
