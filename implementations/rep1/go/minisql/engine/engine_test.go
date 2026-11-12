package engine

import (
	"fmt"
	"math/rand"
	"strings"
	"testing"

	"minisql/syntax"
	"minisql/value"
)

func exec(t *testing.T, db *Database, sql string) *Result {
	t.Helper()
	parsed := syntax.ParseScript(sql)
	if len(parsed) != 1 || parsed[0].Err != nil {
		t.Fatalf("parse %q: %+v", sql, parsed)
	}
	res, err := db.Exec(parsed[0].Stmt)
	if err != nil {
		t.Fatalf("exec %q: %v", sql, err)
	}
	return res
}

func render(res *Result) string {
	var sb strings.Builder
	for _, row := range res.Rows {
		for i, v := range row {
			if i > 0 {
				sb.WriteByte('|')
			}
			sb.WriteString(v.String())
		}
		sb.WriteByte('\n')
	}
	return sb.String()
}

// TestHashJoinMatchesNestedLoop checks that the hash-join path emits exactly
// the pairs, in the same order, as a plain nested loop (forced by writing the
// equality in a form that is not a cross-table "=").
func TestHashJoinMatchesNestedLoop(t *testing.T) {
	db := New()
	exec(t, db, "CREATE TABLE a (x INTEGER, s TEXT)")
	exec(t, db, "CREATE TABLE b (y INTEGER, t TEXT)")
	rng := rand.New(rand.NewSource(1))
	lit := func() string {
		switch rng.Intn(6) {
		case 0:
			return "NULL"
		case 1:
			return fmt.Sprintf("'%d'", rng.Intn(4))
		}
		return fmt.Sprint(rng.Intn(4))
	}
	for i := 0; i < 60; i++ {
		exec(t, db, fmt.Sprintf("INSERT INTO a VALUES (%s, '%d')", lit(), i))
		exec(t, db, fmt.Sprintf("INSERT INTO b VALUES (%s, '%d')", lit(), i))
	}
	pairs := [][2]string{
		{"x = y", "NOT (x != y)"},
		{"x = y AND s < t", "NOT (x != y) AND s < t"},
		{"x + 1 = y * 1 AND a.s = a.s", "NOT (x + 1 != y * 1)"},
		{"y = x AND x = x", "NOT (y != x)"},
	}
	for _, p := range pairs {
		q := "SELECT s, t FROM a, b WHERE "
		if got, want := render(exec(t, db, q+p[0])), render(exec(t, db, q+p[1])); got != want || got == "" {
			t.Errorf("%s: hash join and nested loop differ\n%s\nvs\n%s", p[0], got, want)
		}
	}
}

func TestExecDoesNotMutateOnError(t *testing.T) {
	db := New()
	exec(t, db, "CREATE TABLE t (a INTEGER)")
	parsed := syntax.ParseScript("INSERT INTO t VALUES (1), (2, 3)")
	if _, err := db.Exec(parsed[0].Stmt); err == nil {
		t.Fatal("expected arity error")
	}
	if n := len(db.Table("T").Rows); n != 0 {
		t.Errorf("table has %d rows after failed insert", n)
	}
}

func TestGroupKeysDistinguishTypes(t *testing.T) {
	db := New()
	exec(t, db, "CREATE TABLE t (a INTEGER)")
	exec(t, db, "INSERT INTO t VALUES (1), ('1'), (NULL), (1), (NULL)")
	got := render(exec(t, db, "SELECT a, COUNT(*) FROM t GROUP BY a"))
	if want := "NULL|2\n1|2\n1|1\n"; got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestAppendKey(t *testing.T) {
	k1 := string(appendKey(appendKey(nil, value.Text("a")), value.Text("bc")))
	k2 := string(appendKey(appendKey(nil, value.Text("ab")), value.Text("c")))
	if k1 == k2 {
		t.Error("composite keys must be unambiguous")
	}
}
