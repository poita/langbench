package query

import (
	"reflect"
	"testing"

	"sqlitefile/value"
)

func TestParseGood(t *testing.T) {
	tests := []struct {
		line string
		want Query
	}{
		{".tables", &Tables{}},
		{".schema people", &Schema{Table: "people"}},
		{"COUNT people", &Count{Table: "people"}},
		{"count\tpeople", &Count{Table: "people"}},
		{"SELECT*FROM t", &Select{Star: true, Table: "t"}},
		{"select a,b from t", &Select{Columns: []string{"a", "b"}, Table: "t"}},
		{"SELECT  name ,  age  FROM  t", &Select{Columns: []string{"name", "age"}, Table: "t"}},
		{"SELECT a FROM t WHERE a>=1 AND b IS NOT NULL AND c is 'x''y'", &Select{
			Columns: []string{"a"}, Table: "t",
			Where: []Cond{
				{"a", OpGe, value.NewInt(1)},
				{"b", OpIsNot, value.NullValue},
				{"c", OpIs, value.NewText("x'y")},
			}}},
		{"SELECT a FROM t WHERE a=-2.5e-3 and b!=+7 AND c<1. AND d>x'00fF' AND e<=1E2", &Select{
			Columns: []string{"a"}, Table: "t",
			Where: []Cond{
				{"a", OpEq, value.NewReal(-2.5e-3)},
				{"b", OpNe, value.NewInt(7)},
				{"c", OpLt, value.NewReal(1)},
				{"d", OpGt, value.NewBlob([]byte{0, 0xff})},
				{"e", OpLe, value.NewReal(100)},
			}}},
		{"SELECT a FROM t ORDER BY a DESC LIMIT 3", &Select{Columns: []string{"a"}, Table: "t", OrderBy: "a", Desc: true, Limit: 3, HasLimit: true}},
		{"SELECT a FROM t order by a asc", &Select{Columns: []string{"a"}, Table: "t", OrderBy: "a"}},
		{"SELECT a FROM t LIMIT 0", &Select{Columns: []string{"a"}, Table: "t", HasLimit: true}},
		{"INDEX idx 45", &Index{Name: "idx", Literal: value.NewInt(45)}},
		{"INDEX idx 'a b'", &Index{Name: "idx", Literal: value.NewText("a b")}},
		{"INDEX idx NULL", &Index{Name: "idx", Literal: value.NullValue}},
		{"SELECT a FROM t WHERE a='x'AND b=1", &Select{Columns: []string{"a"}, Table: "t",
			Where: []Cond{{"a", OpEq, value.NewText("x")}, {"b", OpEq, value.NewInt(1)}}}},
	}
	for _, tc := range tests {
		got, err := Parse(tc.line)
		if err != nil {
			t.Errorf("Parse(%q): %v", tc.line, err)
			continue
		}
		if !reflect.DeepEqual(got, tc.want) {
			t.Errorf("Parse(%q) = %+v, want %+v", tc.line, got, tc.want)
		}
	}
}

func TestParseBad(t *testing.T) {
	bad := []string{
		"", ".SCHEMA people", ".TABLES", ".tables extra", ".schema", ".schema a b", ".schema people;",
		".schema 9bad", ".nope",
		"SELECTa FROM t", "SELECT a FROMt", "SELECT a FROM t ORDERBY a", "SELECT a FROM t LIMIT3",
		"SELECT FROM t", "SELECT a, FROM t", "SELECT a FROM", "SELECT a FROM t EXTRA",
		"SELECT a FROM t WHERE", "SELECT a FROM t WHERE a", "SELECT a FROM t WHERE a =", "SELECT a FROM t WHERE a = 1 AND",
		"SELECT a FROM t WHERE a == 1", "SELECT a FROM t WHERE a <> 1", "SELECT a FROM t WHERE a ISNOT NULL",
		"SELECT a FROM t WHERE a = .5", "SELECT a FROM t WHERE a = 1e", "SELECT a FROM t WHERE a = 1abc",
		"SELECT a FROM t WHERE a = 5AND b = 1", "SELECT a FROM t WHERE a = 'abc",
		"SELECT a FROM t WHERE a = X'0'", "SELECT a FROM t WHERE a = X'zz'", "SELECT a FROM t WHERE a = NULLx",
		"SELECT a FROM t ORDER BY a ASC DESC", "SELECT a FROM t ORDER BY", "SELECT a FROM t LIMIT -1",
		"SELECT a FROM t LIMIT 1 ORDER BY a", "SELECT 1a FROM t", "COUNT", "COUNT a b", "COUNT 9t",
		"INDEX", "INDEX idx", "INDEX idx 1 2", "INDEX idx abc",
	}
	for _, line := range bad {
		if q, err := Parse(line); err == nil {
			t.Errorf("Parse(%q) = %+v, want an error", line, q)
		}
	}
}
