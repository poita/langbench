/**
 * End-to-end tests: whole scripts run through `Database.runScript`.
 *
 * (The module only contributes unit tests; it is empty in a normal build.)
 */
module minisql.tests;

version (unittest)
{
    import minisql;

    private string run(string script)
    {
        return (new Database).runScript(script);
    }

    // Runs `setup` and then one statement, returning only that statement's output.
    private string after(string setup, string stmt)
    {
        auto db = new Database;
        db.runScript(setup);
        return db.runScript(stmt);
    }

    private enum emp = "CREATE TABLE emp (id INTEGER, name TEXT, dept TEXT, salary INTEGER);
        INSERT INTO emp VALUES (1, 'ann', 'eng', 120), (2, 'bob', 'ops', 90),
            (3, 'cy', 'eng', NULL), (4, 'dee', NULL, 100);";

    @("SPEC example 1: filtering, grouping, errors and updates")
    unittest
    {
        auto out_ = run(emp ~ "
            SELECT name, salary FROM emp WHERE salary >= 100 ORDER BY salary DESC;
            SELECT dept, COUNT(*), SUM(salary), AVG(salary) FROM emp GROUP BY dept;
            SELECT * FROM nosuch;
            UPDATE emp SET salary = salary + 5 WHERE dept = 'eng';
            SELECT id, salary FROM emp;");
        assert(out_ == "ann\t120\ndee\t100\n-- 2 rows\n"
                ~ "NULL\t1\t100\t100.00\neng\t2\t120\t120.00\nops\t1\t90\t90.00\n-- 3 rows\n"
                ~ "error\n"
                ~ "1\t125\n2\t90\n3\tNULL\n4\t100\n-- 4 rows\n");
    }

    @("SPEC example 2: joins, self joins and scalar expressions")
    unittest
    {
        auto out_ = run("
            CREATE TABLE a (x INTEGER, s TEXT);
            CREATE TABLE b (y INTEGER, t TEXT);
            INSERT INTO a VALUES (3, 'c'), (1, 'a'), (2, 'b'), (1, 'aa');
            INSERT INTO b VALUES (1, 'p'), (2, 'q'), (1, 'r'), (3, 's');
            SELECT s, t FROM a, b WHERE x = y AND t != 'p';
            SELECT p.s, q.s FROM a p INNER JOIN a q ON p.x = q.x AND p.s < q.s;
            SELECT x, COUNT(*) AS n FROM a, b WHERE x = y GROUP BY x ORDER BY n DESC, x LIMIT 2;
            SELECT 7 / 2, -7 / 2, 7 % -3, 1 / 0, 'B' < 'a', 1 < 'a', NULL = NULL, 'Ab_c' LIKE 'ab%';");
        assert(out_ == "c\ts\na\tr\nb\tq\naa\tr\n-- 4 rows\n"
                ~ "a\taa\n-- 1 rows\n"
                ~ "1\t4\n2\t1\n-- 2 rows\n"
                ~ "3\t-3\t1\tNULL\t1\t1\tNULL\t1\n-- 1 rows\n");
    }

    @("SPEC example 3: ordering, HAVING, LIMIT/OFFSET, DELETE")
    unittest
    {
        auto out_ = run("
            CREATE TABLE t (k INTEGER, v INTEGER);
            INSERT INTO t VALUES (2, 10), (NULL, 20), (1, 30), (2, 40), (1, NULL);
            SELECT k, v FROM t ORDER BY k;
            SELECT k, v FROM t ORDER BY k DESC, v DESC;
            SELECT k FROM t GROUP BY k HAVING COUNT(v) = 2;
            SELECT k, v FROM t WHERE k = 1 OR v = 20 LIMIT 1 OFFSET 1;
            DELETE FROM t WHERE v IS NULL OR k IS NULL;
            SELECT COUNT(*), MIN(v), MAX(k), AVG(v) FROM t;
            SELECT 1 FROM t WHERE 0;");
        assert(out_ == "NULL\t20\n1\t30\n1\tNULL\n2\t10\n2\t40\n-- 5 rows\n"
                ~ "2\t40\n2\t10\n1\t30\n1\tNULL\nNULL\t20\n-- 5 rows\n"
                ~ "2\n-- 1 rows\n"
                ~ "1\t30\n-- 1 rows\n"
                ~ "3\t10\t2\t26.67\n-- 1 rows\n"
                ~ "-- 0 rows\n");
    }

    @("empty and comment-only input produce no output")
    unittest
    {
        assert(run("") == "");
        assert(run("  \n -- c\n ;; ; ") == "");
    }

    @("a final statement may lack its semicolon")
    unittest
    {
        assert(run("SELECT 1 + 1") == "2\n-- 1 rows\n");
    }

    @("an unterminated string swallows the rest of the input")
    unittest
    {
        assert(run("SELECT 1; SELECT 'oops; SELECT 2;") == "1\n-- 1 rows\nerror\n");
    }

    @("a failing statement has no effect")
    unittest
    {
        auto db = new Database;
        db.runScript("CREATE TABLE t (a INTEGER, b INTEGER)");
        assert(db.runScript("INSERT INTO t VALUES (1, 2), (3);") == "error\n");
        assert(db.runScript("SELECT COUNT(*) FROM t") == "0\n-- 1 rows\n");
        assert(db.runScript("INSERT INTO t VALUES (1, 2); UPDATE t SET a = 5, zzz = 1;") == "error\n");
        assert(db.runScript("SELECT a FROM t") == "1\n-- 1 rows\n");
    }

    @("every error condition of the spec prints `error`")
    unittest
    {
        enum setup = "CREATE TABLE t (a INTEGER, b TEXT); CREATE TABLE u (a INTEGER, c TEXT);
            INSERT INTO t VALUES (1, 'x');";
        static immutable bad = [
            "DROP TABLE t",
            "CREATE TABLE t (z INTEGER)",
            "CREATE TABLE v (a INTEGER, A TEXT)",
            "CREATE TABLE v (a REAL)",
            "CREATE TABLE v ()",
            "INSERT INTO t VALUES (1)",
            "INSERT INTO t VALUES (a, 'x')",
            "INSERT INTO t VALUES (COUNT(*), 'x')",
            "SELECT * FROM t, u WHERE a = 1",           // ambiguous
            "SELECT zz FROM t",
            "SELECT t.zz FROM t",
            "SELECT t.a FROM t x",                       // table has an alias
            "SELECT * FROM t, t",
            "SELECT * FROM t x, u x",
            "SELECT * FROM nosuch",
            "SELECT a FROM t WHERE COUNT(*) > 0",
            "SELECT a FROM t, u ON COUNT(*) > 0",
            "DELETE FROM t WHERE SUM(a) > 0",
            "UPDATE t SET a = COUNT(*)",
            "SELECT SUM(COUNT(a)) FROM t",
            "SELECT a, COUNT(*) FROM t",
            "SELECT b FROM t GROUP BY a",
            "SELECT *, COUNT(*) FROM t",
            "SELECT * FROM t GROUP BY a",
            "SELECT a FROM t GROUP BY a HAVING b = 'x'",
            "SELECT a FROM t HAVING a = 1",
            "SELECT a FROM t GROUP BY a + 1",
            "SELECT a FROM t ORDER BY 2",
            "SELECT a FROM t ORDER BY 0",
            "SELECT a FROM t OFFSET 1",
            "SELECT a FROM t LIMIT -1",
            "SELECT a FROM t LEFT JOIN u ON 1",
            "SELECT * FROM t, u, t",
            "SELECT a FROM t WHERE a IN (1)",
            "SELECT DISTINCT a FROM t",
            "SELECT * ",
            "SELECT a AS left FROM t",
            "SELECT 1 @ 2",
            "SELECT 1.5",
            "SELECT \"a\" FROM t",
        ];
        foreach (sql; bad)
            assert(after(setup, sql) == "error\n", sql);
    }

    @("errors are reported even when the tables are empty")
    unittest
    {
        assert(after("CREATE TABLE t (a INTEGER)", "SELECT zz FROM t") == "error\n");
        assert(after("CREATE TABLE t (a INTEGER)", "SELECT a, COUNT(*) FROM t") == "error\n");
    }

    @("aggregate names are plain identifiers unless followed by a parenthesis")
    unittest
    {
        assert(after("CREATE TABLE t (count INTEGER); INSERT INTO t VALUES (4), (5);",
                "SELECT count, count (*) FROM t GROUP BY count") == "4\t1\n5\t1\n-- 2 rows\n");
        assert(after("CREATE TABLE t (count INTEGER); INSERT INTO t VALUES (4), (5);",
                "SELECT SUM -- comment\n (count) FROM t") == "9\n-- 1 rows\n");
    }

    @("aggregates over no rows")
    unittest
    {
        enum setup = "CREATE TABLE t (a INTEGER)";
        assert(after(setup, "SELECT COUNT(*), COUNT(a), SUM(a), MIN(a), MAX(a), AVG(a) FROM t")
                == "0\t0\tNULL\tNULL\tNULL\tNULL\n-- 1 rows\n");
        assert(after(setup, "SELECT a, COUNT(*) FROM t GROUP BY a") == "-- 0 rows\n");
    }

    @("AVG rounds half away from zero to two decimals")
    unittest
    {
        static string avg(string vals)
        {
            return after("CREATE TABLE t (a INTEGER); INSERT INTO t VALUES " ~ vals ~ ";", "SELECT AVG(a) FROM t");
        }

        assert(avg("(1),(2)") == "1.50\n-- 1 rows\n");
        assert(avg("(1),(1),(2)") == "1.33\n-- 1 rows\n");
        assert(avg("(-1),(-2)") == "-1.50\n-- 1 rows\n");
        assert(avg("(1),(1),(1),(1),(1),(1),(1),(2)") == "1.13\n-- 1 rows\n");
        assert(avg("(-1),(-1),(-1),(-1),(-1),(-1),(-1),(-2)") == "-1.13\n-- 1 rows\n");
        assert(avg("(NULL)") == "NULL\n-- 1 rows\n");
        // -1 over 201 rows rounds to zero and prints without a sign.
        string vals = "(-1)";
        foreach (_; 0 .. 200)
            vals ~= ",(0)";
        assert(avg(vals) == "0.00\n-- 1 rows\n");
    }

    @("a REAL compares numerically with INTEGERs")
    unittest
    {
        enum setup = "CREATE TABLE t (a INTEGER); INSERT INTO t VALUES (1), (3);";
        assert(after(setup, "SELECT AVG(a) = 2, AVG(a) < 3, AVG(a) IS NULL FROM t")
                == "1\t1\t0\n-- 1 rows\n");
    }

    @("GROUP BY: NULL groups together, 1 and '1' differ, groups come out sorted")
    unittest
    {
        auto out_ = after("CREATE TABLE t (k INTEGER); INSERT INTO t VALUES (2), (NULL), (1), (NULL), (2);",
                "SELECT k, COUNT(*) FROM t GROUP BY k");
        assert(out_ == "NULL\t2\n1\t1\n2\t2\n-- 3 rows\n");
    }

    @("ORDER BY: aliases, ordinals, stability, NULL placement")
    unittest
    {
        enum setup = "CREATE TABLE t (x INTEGER, y TEXT);
            INSERT INTO t VALUES (2, 'a'), (NULL, 'b'), (1, 'c'), (2, 'd');";
        assert(after(setup, "SELECT y, x AS k FROM t ORDER BY k") == "b\tNULL\nc\t1\na\t2\nd\t2\n-- 4 rows\n");
        assert(after(setup, "SELECT y, x FROM t ORDER BY 2 DESC") == "a\t2\nd\t2\nc\t1\nb\tNULL\n-- 4 rows\n");
        assert(after(setup, "SELECT *, x FROM t ORDER BY 3, 2 DESC")
                == "NULL\tb\tNULL\n1\tc\t1\n2\td\t2\n2\ta\t2\n-- 4 rows\n");
        assert(after(setup, "SELECT * FROM t ORDER BY 1 + 0") == "2\ta\nNULL\tb\n1\tc\n2\td\n-- 4 rows\n");
        assert(after(setup, "SELECT x FROM t ORDER BY 3") == "error\n");
    }

    @("a join keeps nested-loop order and handles NULL keys")
    unittest
    {
        enum setup = "CREATE TABLE a (x INTEGER); CREATE TABLE b (y INTEGER);
            INSERT INTO a VALUES (1), (NULL), (2), (1);
            INSERT INTO b VALUES (NULL), (1), (2), (1);";
        assert(after(setup, "SELECT x, y FROM a JOIN b ON x = y")
                == "1\t1\n1\t1\n2\t2\n1\t1\n1\t1\n-- 5 rows\n");
        assert(after(setup, "SELECT x, y FROM a, b WHERE y + 1 = x + 1 AND x > 1")
                == "2\t2\n-- 1 rows\n");
        assert(after(setup, "SELECT x, y FROM a, b WHERE x < y")
                == "1\t2\n1\t2\n-- 2 rows\n");
    }

    @("UPDATE evaluates every right-hand side against the old row")
    unittest
    {
        auto db = new Database;
        db.runScript("CREATE TABLE t (a INTEGER, b INTEGER); INSERT INTO t VALUES (1, 2), (3, 4);");
        db.runScript("UPDATE t SET a = b, b = a WHERE t.a = 1");
        assert(db.runScript("SELECT a, b FROM t") == "2\t1\n3\t4\n-- 2 rows\n");
    }

    @("DELETE keeps the relative order of the remaining rows")
    unittest
    {
        auto db = new Database;
        db.runScript("CREATE TABLE t (a INTEGER); INSERT INTO t VALUES (1), (2), (3), (4);");
        db.runScript("DELETE FROM t WHERE a % 2 = 0");
        db.runScript("INSERT INTO t VALUES (0)");
        assert(db.runScript("SELECT a FROM t") == "1\n3\n0\n-- 3 rows\n");
    }

    @("LIKE: wildcards, case folding, integers and NULL")
    unittest
    {
        assert(run("SELECT 'APPLE' LIKE 'apple', 'É' LIKE 'é', 12345 LIKE '12%', 'a' NOT LIKE 'b', NULL LIKE 'a', 'a' LIKE NULL;")
                == "1\t0\t1\t1\tNULL\tNULL\n-- 1 rows\n");
    }

    @("three-valued logic and precedence")
    unittest
    {
        assert(run("SELECT NULL AND 0, NULL OR 1, NOT NULL, NOT 1 = 2, 1 < 2 = 1, -5 % 3, 2 + 3 * 4;")
                == "0\t1\tNULL\t1\t1\t-2\t14\n-- 1 rows\n");
    }

    @("SELECT without FROM")
    unittest
    {
        assert(run("SELECT 1 WHERE 0;") == "-- 0 rows\n");
        assert(run("SELECT COUNT(*);") == "1\n-- 1 rows\n");
        assert(run("SELECT a;") == "error\n");
        assert(run("SELECT *;") == "error\n");
    }

    @("the programmatic API reports errors as exceptions and rows as values")
    unittest
    {
        import std.exception : assertThrown;

        auto db = new Database;
        db.execute("CREATE TABLE t (a INTEGER, b TEXT)");
        db.execute("INSERT INTO t VALUES (1, 'x'), (2, NULL)");
        auto r = db.execute("SELECT b, a FROM t ORDER BY a DESC");
        assert(r.isQuery && r.rows.length == 2);
        assert(r.rows[0][0].isNull && r.rows[0][1].num == 2);
        assert(r.rows[1][0].str == "x");
        assertThrown!SqlError(db.execute("SELECT nope FROM t"));
        assertThrown!SqlError(db.execute("SELECT 1; SELECT 2"));
        assert(db.table("T").rows.length == 2);
        assert(db.table("missing") is null);
    }
}
