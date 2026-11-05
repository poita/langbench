package minisql

import (
	"strings"
	"testing"
)

// run executes a script and returns its output.
func run(t *testing.T, script string) string {
	t.Helper()
	var sb strings.Builder
	if err := New().RunScript(script, &sb); err != nil {
		t.Fatal(err)
	}
	return sb.String()
}

func check(t *testing.T, script, want string) {
	t.Helper()
	if got := run(t, script); got != want {
		t.Errorf("script:\n%s\ngot:\n%s\nwant:\n%s", script, got, want)
	}
}

func TestExample1(t *testing.T) {
	check(t, `
CREATE TABLE emp (id INTEGER, name TEXT, dept TEXT, salary INTEGER);
INSERT INTO emp VALUES (1, 'ann', 'eng', 120), (2, 'bob', 'ops', 90), (3, 'cy', 'eng', NULL), (4, 'dee', NULL, 100);
SELECT name, salary FROM emp WHERE salary >= 100 ORDER BY salary DESC;
SELECT dept, COUNT(*), SUM(salary), AVG(salary) FROM emp GROUP BY dept;
SELECT * FROM nosuch;
UPDATE emp SET salary = salary + 5 WHERE dept = 'eng';
SELECT id, salary FROM emp;`,
		"ann\t120\ndee\t100\n-- 2 rows\n"+
			"NULL\t1\t100\t100.00\neng\t2\t120\t120.00\nops\t1\t90\t90.00\n-- 3 rows\n"+
			"error\n1\t125\n2\t90\n3\tNULL\n4\t100\n-- 4 rows\n")
}

func TestExample2Joins(t *testing.T) {
	check(t, `
CREATE TABLE a (x INTEGER, s TEXT);
CREATE TABLE b (y INTEGER, t TEXT);
INSERT INTO a VALUES (3, 'c'), (1, 'a'), (2, 'b'), (1, 'aa');
INSERT INTO b VALUES (1, 'p'), (2, 'q'), (1, 'r'), (3, 's');
SELECT s, t FROM a, b WHERE x = y AND t != 'p';
SELECT p.s, q.s FROM a p INNER JOIN a q ON p.x = q.x AND p.s < q.s;
SELECT x, COUNT(*) AS n FROM a, b WHERE x = y GROUP BY x ORDER BY n DESC, x LIMIT 2;
SELECT 7 / 2, -7 / 2, 7 % -3, 1 / 0, 'B' < 'a', 1 < 'a', NULL = NULL, 'Ab_c' LIKE 'ab%';`,
		"c\ts\na\tr\nb\tq\naa\tr\n-- 4 rows\n"+
			"a\taa\n-- 1 rows\n1\t4\n2\t1\n-- 2 rows\n"+
			"3\t-3\t1\tNULL\t1\t1\tNULL\t1\n-- 1 rows\n")
}

func TestExample3(t *testing.T) {
	check(t, `
CREATE TABLE t (k INTEGER, v INTEGER);
INSERT INTO t VALUES (2, 10), (NULL, 20), (1, 30), (2, 40), (1, NULL);
SELECT k, v FROM t ORDER BY k;
SELECT k, v FROM t ORDER BY k DESC, v DESC;
SELECT k FROM t GROUP BY k HAVING COUNT(v) = 2;
SELECT k, v FROM t WHERE k = 1 OR v = 20 LIMIT 1 OFFSET 1;
DELETE FROM t WHERE v IS NULL OR k IS NULL;
SELECT COUNT(*), MIN(v), MAX(k), AVG(v) FROM t;
SELECT 1 FROM t WHERE 0;`,
		"NULL\t20\n1\t30\n1\tNULL\n2\t10\n2\t40\n-- 5 rows\n"+
			"2\t40\n2\t10\n1\t30\n1\tNULL\nNULL\t20\n-- 5 rows\n"+
			"2\n-- 1 rows\n1\t30\n-- 1 rows\n3\t10\t2\t26.67\n-- 1 rows\n-- 0 rows\n")
}

func TestAvgRounding(t *testing.T) {
	check(t, `
CREATE TABLE t (g INTEGER, v INTEGER);
INSERT INTO t VALUES (1,1),(1,1),(1,1),(1,1),(1,1),(1,1),(1,1),(1,2),
 (2,-1),(2,-1),(2,-1),(2,-1),(2,-1),(2,-1),(2,-1),(2,-2),(3,1),(3,2),(4,-1),(4,-2);
SELECT g, AVG(v) FROM t GROUP BY g;`,
		"1\t1.13\n2\t-1.13\n3\t1.50\n4\t-1.50\n-- 4 rows\n")
	// An average that rounds to zero from below must print 0.00.
	var sb strings.Builder
	sb.WriteString("CREATE TABLE z (v INTEGER);\nINSERT INTO z VALUES (-1)")
	for i := 0; i < 200; i++ {
		sb.WriteString(", (0)")
	}
	sb.WriteString(";\nSELECT AVG(v) FROM z;")
	check(t, sb.String(), "0.00\n-- 1 rows\n")
}

func TestRealComparison(t *testing.T) {
	check(t, `
CREATE TABLE t (v INTEGER);
INSERT INTO t VALUES (1), (3);
SELECT AVG(v) = 2, AVG(v) > 1, AVG(v) IS NULL FROM t;`,
		"1\t1\t0\n-- 1 rows\n")
}

func TestErrorsLeaveDatabaseUnchanged(t *testing.T) {
	check(t, `
CREATE TABLE t (a INTEGER, b TEXT);
INSERT INTO t VALUES (1, 'x'), (2);
INSERT INTO t VALUES (1, 'x'), (a, 'y');
UPDATE t SET a = 1, nosuch = 2;
SELECT COUNT(*) FROM t;`,
		"error\nerror\nerror\n0\n-- 1 rows\n")
}

func TestStatementErrors(t *testing.T) {
	bad := []string{
		"SELECT * FROM nosuch",
		"CREATE TABLE t (a INTEGER, A TEXT)",
		"CREATE TABLE t (text TEXT)",
		"CREATE TABLE t (a REAL)",
		"CREATE TABLE t ()",
		"SELECT 1 +",
		"SELECT 1.5",
		"SELECT \"a\"",
		"SELECT * ",
		"SELECT a",
		"SELECT 1 OFFSET 1",
		"SELECT 1 LIMIT -1",
		"SELECT 1 FROM",
		"SELECT COUNT(COUNT(*))",
		"SELECT 1 WHERE COUNT(*) > 0",
		"SELECT foo(1)",
		"SELECT 1 ORDER BY 2",
		"SELECT 1 ORDER BY 0",
		"SELECT 1 HAVING 1",
		"SELECT DISTINCT 1",
		"DROP TABLE t",
		"SELECT 'unterminated",
	}
	for _, sql := range bad {
		if _, err := New().Exec(sql); err == nil {
			t.Errorf("%q: expected an error", sql)
		}
	}
}

func TestSchemaErrors(t *testing.T) {
	db := New()
	for _, s := range []string{
		"CREATE TABLE t (a INTEGER, b TEXT)",
		"CREATE TABLE u (a INTEGER)",
		"INSERT INTO t VALUES (1, 'x')",
	} {
		if _, err := db.Exec(s); err != nil {
			t.Fatalf("%s: %v", s, err)
		}
	}
	for _, sql := range []string{
		"CREATE TABLE T (z INTEGER)",
		"SELECT c FROM t",
		"SELECT a FROM t, u",         // ambiguous
		"SELECT a FROM t x, t x",     // same effective name
		"SELECT t.a FROM t x",        // table name hidden by alias
		"SELECT b FROM t GROUP BY a", // non-grouped column
		"SELECT a, COUNT(*) FROM t",  // column in no-GROUP BY aggregate query
		"INSERT INTO t VALUES (1)",   // arity
		"INSERT INTO t VALUES (COUNT(*), 'x')",
		"DELETE FROM t WHERE SUM(a) > 1", // aggregate in DELETE
		"UPDATE t SET a = MAX(a)",
	} {
		if _, err := db.Exec(sql); err == nil {
			t.Errorf("%q: expected an error", sql)
		} else if e, ok := err.(*Error); !ok || e.Kind != SemanticError && !strings.HasPrefix(sql, "SELECT a, COUNT") {
			// every statement above is well-formed
			t.Errorf("%q: got %v, want a semantic error", sql, err)
		}
	}
}

func TestOrderBy(t *testing.T) {
	check(t, `
CREATE TABLE a (x INTEGER, y INTEGER);
INSERT INTO a VALUES (1, 3), (2, 1), (3, 2);
SELECT *, x FROM a ORDER BY 3 DESC;
SELECT y AS z FROM a ORDER BY z;
SELECT x FROM a ORDER BY 1 + 0 DESC;
SELECT x FROM a ORDER BY -y;
SELECT x FROM a ORDER BY y DESC LIMIT 2 OFFSET 1;`,
		"3\t2\t3\n2\t1\t2\n1\t3\t1\n-- 3 rows\n"+
			"1\n2\n3\n-- 3 rows\n"+
			"1\n2\n3\n-- 3 rows\n"+
			"1\n3\n2\n-- 3 rows\n"+
			"3\n2\n-- 2 rows\n")
}

func TestOrderStableAndNullPlacement(t *testing.T) {
	check(t, `
CREATE TABLE t (k INTEGER, tag TEXT);
INSERT INTO t VALUES (1,'a'),(NULL,'b'),(1,'c'),(NULL,'d');
SELECT tag FROM t ORDER BY k;
SELECT tag FROM t ORDER BY k DESC;`,
		"b\nd\na\nc\n-- 4 rows\na\nc\nb\nd\n-- 4 rows\n")
}

func TestJoinOrderMatchesNestedLoop(t *testing.T) {
	check(t, `
CREATE TABLE a (k INTEGER, n TEXT);
CREATE TABLE b (k INTEGER, m TEXT);
INSERT INTO a VALUES (1,'a1'),(2,'a2'),(1,'a3'),(NULL,'a4');
INSERT INTO b VALUES (1,'b1'),(1,'b2'),(2,'b3'),(NULL,'b4');
SELECT n, m FROM a, b WHERE a.k = b.k;
SELECT n, m FROM a JOIN b ON a.k + 0 = b.k AND m != 'b2' WHERE n != 'a2';
SELECT n, m FROM a, b WHERE a.k < b.k;`,
		"a1\tb1\na1\tb2\na2\tb3\na3\tb1\na3\tb2\n-- 5 rows\n"+
			"a1\tb1\na3\tb1\n-- 2 rows\n"+
			"a1\tb3\na3\tb3\n-- 2 rows\n")
}

func TestJoinTypeSeparation(t *testing.T) {
	check(t, `
CREATE TABLE a (v INTEGER);
CREATE TABLE b (v TEXT);
INSERT INTO a VALUES (1);
INSERT INTO b VALUES ('1');
SELECT * FROM a, b WHERE a.v = b.v;`,
		"-- 0 rows\n")
}

func TestGroupBy(t *testing.T) {
	check(t, `
CREATE TABLE t (g TEXT, v INTEGER);
SELECT COUNT(*), SUM(v), MIN(v), MAX(g) FROM t;
SELECT g, COUNT(*) FROM t GROUP BY g;
INSERT INTO t VALUES ('b', 1), (NULL, 2), ('a', NULL), ('b', 3), (NULL, 4);
SELECT g, COUNT(*), COUNT(v), SUM(v), MIN(v), MAX(v) FROM t GROUP BY g;
SELECT g FROM t GROUP BY g HAVING SUM(v) > 3 ORDER BY g DESC;`,
		"0\tNULL\tNULL\tNULL\n-- 1 rows\n-- 0 rows\n"+
			"NULL\t2\t2\t6\t2\t4\na\t1\t0\tNULL\tNULL\tNULL\nb\t2\t2\t4\t1\t3\n-- 3 rows\n"+
			"b\nNULL\n-- 2 rows\n")
}

func TestThreeValuedLogic(t *testing.T) {
	check(t, `
SELECT NULL AND 0, NULL AND 1, NULL OR 1, NULL OR 0, NOT NULL, 1 AND 1, 0 OR 0, NOT 5;
SELECT NOT 1 = 2, 1 < 2 = 1, -5 % 3, 1 IS NULL, NULL IS NOT NULL, 'a' NOT LIKE 'b', 12345 LIKE '12%';`,
		"0\tNULL\t1\tNULL\tNULL\t1\t0\t0\n-- 1 rows\n"+
			"1\t1\t-2\t0\t0\t1\t1\n-- 1 rows\n")
}

func TestKeywordsAndAggregateNamesAsIdentifiers(t *testing.T) {
	check(t, `
CREATE TABLE count (count INTEGER, sum TEXT);
INSERT INTO count VALUES (4, 'x');
SELECT count, count(*) FROM count GROUP BY count;
SELECT count (*) FROM count;`,
		"4\t1\n-- 1 rows\n1\n-- 1 rows\n")
}

func TestExecAPI(t *testing.T) {
	db := New()
	if r, err := db.Exec("CREATE TABLE t (a INTEGER);"); err != nil || r != nil {
		t.Fatalf("CREATE: %v %v", r, err)
	}
	db.Exec("INSERT INTO t VALUES (1), (2)")
	r, err := db.Exec("SELECT a * 10 FROM t")
	if err != nil {
		t.Fatal(err)
	}
	if len(r.Rows) != 2 || r.Rows[1][0].Integer() != 20 {
		t.Errorf("unexpected rows %v", r.Rows)
	}
	if _, err := db.Exec("SELECT 1; SELECT 2"); err == nil {
		t.Error("Exec of two statements should fail")
	}
	outs := db.ExecScript("SELECT 1; SELECT x; SELECT 3")
	if len(outs) != 3 || outs[0].Err != nil || outs[1].Err == nil || outs[2].Result.Rows[0][0].Integer() != 3 {
		t.Errorf("unexpected outcomes %+v", outs)
	}
}

func TestUpdateSwapAndRowOrder(t *testing.T) {
	check(t, `
CREATE TABLE t (a INTEGER, b INTEGER);
INSERT INTO t VALUES (1, 2), (3, 4), (5, 6);
UPDATE t SET a = b, b = a WHERE t.a > 1;
DELETE FROM t WHERE a = 4;
INSERT INTO t VALUES (7, 8);
SELECT * FROM t;
DELETE FROM t;
SELECT COUNT(*) FROM t;`,
		"1\t2\n6\t5\n7\t8\n-- 3 rows\n0\n-- 1 rows\n")
}

func TestUnterminatedStringStopsExecution(t *testing.T) {
	check(t, "SELECT 1; SELECT 'oops; SELECT 2;", "1\n-- 1 rows\nerror\n")
}

func TestEmptyInput(t *testing.T) {
	check(t, "", "")
	check(t, "  -- nothing\n ;; ", "")
}
