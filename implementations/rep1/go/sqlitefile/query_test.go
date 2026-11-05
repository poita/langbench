package sqlitefile

import (
	"errors"
	"testing"
)

func TestParseQueryValid(t *testing.T) {
	good := []string{
		".tables", ".schema people", "COUNT people", "count People",
		"SELECT * FROM t", "SELECT*FROM t", "select a,b from t", "SELECT  name ,  age  FROM  t",
		"SELECT a FROM t WHERE a>=1", "SELECT a FROM t WHERE a IS NOT NULL", "SELECT a FROM t WHERE a is\tnot\tnull",
		"SELECT a FROM t WHERE a=1.AND b=2",
		"SELECT a FROM t WHERE a = 1. AND b = -2.5e-3 AND c = +7", "SELECT a FROM t WHERE a = 'it''s'",
		"SELECT a FROM t WHERE a = x'00fF' AND b != X''", "SELECT a FROM t ORDER BY a DESC LIMIT 3",
		"SELECT a FROM t ORDER BY a asc", "SELECT a FROM t LIMIT 0", "INDEX ix 5", "INDEX ix 'a'", "INDEX ix x'00'",
		"INDEX ix NULL", "INDEX ix-5", "SELECT a FROM t WHERE a IS'x'",
	}
	for _, s := range good {
		if _, err := ParseQuery(s); err != nil {
			t.Errorf("%q: unexpected error %v", s, err)
		}
	}
}

func TestParseQueryInvalid(t *testing.T) {
	bad := []string{
		"", ".SCHEMA people", ".TABLES", ".tables extra", ".schema", ".schema people notes", ".schema 9bad",
		".schema people;", ".schema people.notes", ".dump", "DROP TABLE t", "SELECTa", "SELECT a FROMt",
		"SELECT FROM t", "SELECT name, FROM t", "SELECT a FROM t EXTRA", "SELECT a FROM t WHERE",
		"SELECT a FROM t WHERE a", "SELECT a FROM t WHERE a ==1", "SELECT a FROM t WHERE a <> 1",
		"SELECT a FROM t WHERE a = .5", "SELECT a FROM t WHERE a = 1e", "SELECT a FROM t WHERE a = 1AND",
		"SELECT a FROM t WHERE a = 'abc", "SELECT a FROM t WHERE a = X'0'", "SELECT a FROM t WHERE a = X'zz'",
		"SELECT a FROM t WHERE a = 1 AND", "SELECT a FROM t WHERE a IS NOTNULL", "SELECT a FROM t WHERE a ! 1",
		"SELECT a FROM t ORDER a", "SELECT a FROM t ORDERBY a", "SELECT a FROM t ORDER BY a ASC DESC",
		"SELECT a FROM t LIMIT -1", "SELECT a FROM t LIMIT3", "SELECT a FROM t LIMIT 1x", "SELECT a FROM t LIMIT",
		"SELECT a FROM t LIMIT 3 ORDER BY a", "SELECT a FROM t ORDER BY a WHERE a = 1", "SELECT a FROM t LIMIT 9223372036854775808",
		"COUNT", "COUNT a b", "COUNT 9a", "INDEX", "INDEX ix", "INDEX ix 5 6", "INDEXix 5", "SELECT a, FROM t",
		"SELECT * , a FROM t", "SELECT a FROM t WHERE a = x'0g'", "SELECT a FROM t WHERE a = nul",
	}
	for _, s := range bad {
		if _, err := ParseQuery(s); !errors.Is(err, ErrQuery) {
			t.Errorf("%q: expected ErrQuery, got %v", s, err)
		}
	}
}

func TestParseQueryContents(t *testing.T) {
	q, err := ParseQuery("SELECT name, rowid FROM People WHERE age >= 40 AND name IS NOT NULL ORDER BY age DESC LIMIT 7")
	if err != nil {
		t.Fatal(err)
	}
	if q.Command != CmdSelect || q.Table != "People" || q.Star || len(q.Columns) != 2 || q.Limit != 7 ||
		q.OrderBy != "age" || !q.Desc || len(q.Where) != 2 {
		t.Fatalf("unexpected parse: %+v", q)
	}
	if q.Where[0].Op != OpGe || q.Where[0].Value.Kind != KindInteger || q.Where[0].Value.I != 40 {
		t.Errorf("cond 0: %+v", q.Where[0])
	}
	if q.Where[1].Op != OpIsNot || !q.Where[1].Value.IsNull() {
		t.Errorf("cond 1: %+v", q.Where[1])
	}
	q, _ = ParseQuery("SELECT * FROM t WHERE a = 1.5 AND b = 'it''s' AND c = x'0aFF'")
	if q.Limit != -1 || q.Where[0].Value.Kind != KindReal || string(q.Where[1].Value.B) != "it's" ||
		q.Where[2].Value.Kind != KindBlob || q.Where[2].Value.B[1] != 0xff {
		t.Errorf("literal parse: %+v", q)
	}
	q, _ = ParseQuery("INDEX ix 'k'")
	if q.Command != CmdIndex || q.IndexName != "ix" || string(q.Key.B) != "k" {
		t.Errorf("index parse: %+v", q)
	}
}
