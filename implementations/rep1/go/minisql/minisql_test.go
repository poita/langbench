package minisql_test

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"minisql"
)

func run(t *testing.T, script string) string {
	t.Helper()
	var buf bytes.Buffer
	if err := minisql.New().RunScript(script, &buf); err != nil {
		t.Fatal(err)
	}
	return buf.String()
}

// TestGolden runs every testdata/golden/*.in script and compares the output
// with the matching .out file (ignoring trailing whitespace).
func TestGolden(t *testing.T) {
	files, err := filepath.Glob("testdata/golden/*.in")
	if err != nil || len(files) == 0 {
		t.Fatalf("no golden tests found: %v", err)
	}
	norm := func(s string) string {
		lines := strings.Split(strings.ReplaceAll(s, "\r\n", "\n"), "\n")
		for i, l := range lines {
			lines[i] = strings.TrimRight(l, " \t")
		}
		return strings.TrimRight(strings.Join(lines, "\n"), "\n")
	}
	for _, in := range files {
		name := strings.TrimSuffix(filepath.Base(in), ".in")
		t.Run(name, func(t *testing.T) {
			src, err := os.ReadFile(in)
			if err != nil {
				t.Fatal(err)
			}
			want, err := os.ReadFile(strings.TrimSuffix(in, ".in") + ".out")
			if err != nil {
				t.Fatal(err)
			}
			if got := run(t, string(src)); norm(got) != norm(string(want)) {
				t.Errorf("output mismatch\n got: %q\nwant: %q", got, want)
			}
		})
	}
}

func TestStatements(t *testing.T) {
	const setup = `CREATE TABLE a (x INTEGER, s TEXT);
		CREATE TABLE b (y INTEGER, t TEXT);
		INSERT INTO a VALUES (3,'c'),(1,'a'),(2,'b'),(1,'aa');
		INSERT INTO b VALUES (1,'p'),(2,'q'),(1,'r'),(3,'s');`
	tests := []struct{ name, sql, want string }{
		{"no from", "SELECT 1 + 1", "2\n-- 1 rows\n"},
		{"no from where false", "SELECT 1 WHERE 0", "-- 0 rows\n"},
		{"arithmetic", "SELECT 7/2, -7/2, -7%3, 7%-3, 1/0, 1%0, -5 % 3", "3\t-3\t-1\t1\tNULL\tNULL\t-2\n-- 1 rows\n"},
		{"comparison kinds", "SELECT 1 = '1', 1 < 'a', 100 < '0', 'B' < 'a', NULL = NULL", "0\t1\t1\t1\tNULL\n-- 1 rows\n"},
		{"three valued", "SELECT NULL AND 0, NULL AND 1, NULL OR 1, NULL OR 0, NOT NULL, NOT 0", "0\tNULL\t1\tNULL\tNULL\t1\n-- 1 rows\n"},
		{"like", "SELECT 12345 LIKE '12%', 'APPLE' LIKE 'apple', 'É' LIKE 'é', 'a' NOT LIKE 'b'", "1\t1\t0\t1\n-- 1 rows\n"},
		{"comment dashes", "SELECT 5 --5\n", "5\n-- 1 rows\n"},
		{"join order", setup + "SELECT s, t FROM a, b WHERE x = y AND t != 'p'", "c\ts\na\tr\nb\tq\naa\tr\n-- 4 rows\n"},
		{"self join", setup + "SELECT p.s, q.s FROM a p INNER JOIN a q ON p.x = q.x AND p.s < q.s", "a\taa\n-- 1 rows\n"},
		{"join on expression", setup + "SELECT s, t FROM a JOIN b ON x + 1 = y * 1 ORDER BY s, t", "a\tq\naa\tq\nb\ts\n-- 3 rows\n"},
		{"join no equality", setup + "SELECT x, y FROM a, b WHERE x < y AND y < 3", "1\t2\n1\t2\n-- 2 rows\n"},
		{"group order alias", setup + "SELECT x, COUNT(*) AS n FROM a, b WHERE x = y GROUP BY x ORDER BY n DESC, x LIMIT 2", "1\t4\n2\t1\n-- 2 rows\n"},
		{"ordinal with star", setup + "SELECT *, x FROM a ORDER BY 3 DESC, 2 LIMIT 2", "3\tc\t3\n2\tb\t2\n-- 2 rows\n"},
		{"empty aggregate", "CREATE TABLE e (v INTEGER); SELECT COUNT(*), SUM(v), AVG(v), MIN(v) FROM e", "0\tNULL\tNULL\tNULL\n-- 1 rows\n"},
		{"empty group by", "CREATE TABLE e (v INTEGER); SELECT v, COUNT(*) FROM e GROUP BY v", "-- 0 rows\n"},
		{"update swap", "CREATE TABLE t (a INTEGER, b INTEGER); INSERT INTO t VALUES (1,2); UPDATE t SET a = b, b = a; SELECT * FROM t", "2\t1\n-- 1 rows\n"},
		{"delete keeps order", "CREATE TABLE t (a INTEGER); INSERT INTO t VALUES (1),(2),(3),(4); DELETE FROM t WHERE a % 2 = 0; INSERT INTO t VALUES (9); SELECT a FROM t", "1\n3\n9\n-- 3 rows\n"},
		{"avg compare", "CREATE TABLE t (a INTEGER); INSERT INTO t VALUES (1),(3); SELECT AVG(a) = 2, AVG(a) < 3, AVG(a) IS NULL, AVG(a) FROM t", "1\t1\t0\t2.00\n-- 1 rows\n"},
		{"distinct unsupported", "CREATE TABLE t (a INTEGER); SELECT DISTINCT a FROM t", "error\n"},
		{"count as column", "CREATE TABLE t (count INTEGER); INSERT INTO t VALUES (4); SELECT count, count(*) FROM t GROUP BY count", "4\t1\n-- 1 rows\n"},
		{"order by nulls", "CREATE TABLE t (a INTEGER); INSERT INTO t VALUES (2),(NULL),(1); SELECT a FROM t ORDER BY a DESC", "2\n1\nNULL\n-- 3 rows\n"},
		{"order stable desc", "CREATE TABLE t (k INTEGER, v INTEGER); INSERT INTO t VALUES (1,1),(1,2),(1,3); SELECT v FROM t ORDER BY k DESC", "1\n2\n3\n-- 3 rows\n"},
		{"offset past end", "CREATE TABLE t (a INTEGER); INSERT INTO t VALUES (1); SELECT a FROM t LIMIT 5 OFFSET 9", "-- 0 rows\n"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got := run(t, tc.sql)
			if got != tc.want {
				t.Errorf("got %q, want %q", got, tc.want)
			}
		})
	}
}

func TestErrorsHaveNoEffect(t *testing.T) {
	script := `
CREATE TABLE t (a INTEGER, b TEXT);
INSERT INTO t VALUES (1, 'x');
INSERT INTO t VALUES (2, 'y'), (3);
INSERT INTO t VALUES (a, 'z');
INSERT INTO t VALUES (SUM(1), 'z');
CREATE TABLE t (c INTEGER);
CREATE TABLE u (a INTEGER, A TEXT);
UPDATE t SET a = 9, nosuch = 1;
UPDATE t SET a = COUNT(*);
DELETE FROM t WHERE SUM(a) > 0;
SELECT * FROM t;
SELECT a FROM nosuch;
SELECT nosuch FROM t;
SELECT a FROM t x, t y;
SELECT t.a FROM t x;
SELECT * FROM t, t;
SELECT a, COUNT(*) FROM t;
SELECT b FROM t GROUP BY a;
SELECT COUNT(SUM(a)) FROM t;
SELECT a FROM t WHERE COUNT(*) > 0;
SELECT a FROM t ORDER BY 2;
SELECT a FROM t ORDER BY 0;
SELECT *;
SELECT x;
SELECT 1 +;
SELECT 'unterminated;
SELECT 2;
`
	got := run(t, script)
	// Only `SELECT * FROM t` succeeds, and it must still see the one row from
	// the first INSERT. The unterminated string swallows the final `SELECT 2`.
	lines := strings.Split(strings.TrimRight(got, "\n"), "\n")
	if lines[8] != "1\tx" || lines[9] != "-- 1 rows" {
		t.Fatalf("table content changed by failing statements:\n%s", got)
	}
	errs := 0
	for _, l := range lines {
		if l == "error" {
			errs++
		}
	}
	if errs != 23 || len(lines) != 25 {
		t.Errorf("got %d errors in %d lines, want 23 in 25:\n%s", errs, len(lines), got)
	}
}

func TestExec(t *testing.T) {
	db := minisql.New()
	if _, err := db.Exec("CREATE TABLE t (a INTEGER, b TEXT)"); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec("INSERT INTO t VALUES (1, 'x'), (2, 'y');"); err != nil {
		t.Fatal(err)
	}
	res, err := db.Exec("SELECT b FROM t WHERE a > 1")
	if err != nil {
		t.Fatal(err)
	}
	if len(res.Rows) != 1 || res.Rows[0][0].String() != "y" {
		t.Errorf("unexpected result %v", res.Rows)
	}
	if _, err := db.Exec("SELECT 1; SELECT 2"); err != minisql.ErrNotOneStatement {
		t.Errorf("want ErrNotOneStatement, got %v", err)
	}
	if _, err := db.Exec("SELEC 1"); err == nil {
		t.Error("want syntax error")
	}
}

func ExampleDB_RunScript() {
	db := minisql.New()
	var out bytes.Buffer
	db.RunScript(`
		CREATE TABLE emp (name TEXT, dept TEXT, salary INTEGER);
		INSERT INTO emp VALUES ('ann','eng',120), ('bob','ops',90), ('cy','eng',100);
		SELECT dept, COUNT(*), AVG(salary) FROM emp GROUP BY dept;
		SELECT nope FROM emp;`, &out)
	fmt.Print(out.String())
	// Output:
	// eng	2	110.00
	// ops	1	90.00
	// -- 2 rows
	// error
}

// largeScript builds the two-table workload used by the benchmark.
func largeScript() string {
	var sb strings.Builder
	sb.WriteString("CREATE TABLE a (id INTEGER, k INTEGER); CREATE TABLE b (id INTEGER, k INTEGER);\n")
	for _, tbl := range []struct {
		name string
		n    int
	}{{"a", 2000}, {"b", 20000}} {
		for lo := 0; lo < tbl.n; lo += 500 {
			fmt.Fprintf(&sb, "INSERT INTO %s VALUES ", tbl.name)
			for i := lo; i < lo+500; i++ {
				if i > lo {
					sb.WriteString(",")
				}
				fmt.Fprintf(&sb, "(%d, %d)", i, i%2000)
			}
			sb.WriteString(";\n")
		}
	}
	sb.WriteString("SELECT COUNT(*) FROM a, b WHERE a.k = b.k;\n")
	return sb.String()
}

func TestLargeJoin(t *testing.T) {
	got := run(t, largeScript())
	if got != "20000\n-- 1 rows\n" {
		t.Errorf("got %q", got)
	}
}

func BenchmarkJoin(b *testing.B) {
	script := largeScript()
	for i := 0; i < b.N; i++ {
		minisql.New().RunScript(script, &bytes.Buffer{})
	}
}
