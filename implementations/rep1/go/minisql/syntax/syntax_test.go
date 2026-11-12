package syntax

import (
	"reflect"
	"testing"
)

func kinds(toks []Token) []TokenKind {
	var out []TokenKind
	for _, t := range toks {
		out = append(out, t.Kind)
	}
	return out
}

func TestLex(t *testing.T) {
	toks := Lex("SeLeCt a1, 'it''s' -- comment ; x\n <= <> != == 007")
	want := []Token{
		{Kind: TokKeyword, Text: "SELECT"},
		{Kind: TokIdent, Text: "a1"},
		{Kind: TokPunct, Text: ","},
		{Kind: TokString, Text: "it's"},
		{Kind: TokPunct, Text: "<="},
		{Kind: TokPunct, Text: "<>"},
		{Kind: TokPunct, Text: "!="},
		{Kind: TokPunct, Text: "=="},
		{Kind: TokInt, Text: "007", Int: 7},
	}
	if !reflect.DeepEqual(toks, want) {
		t.Errorf("got %+v\nwant %+v", toks, want)
	}
}

func TestLexInvalid(t *testing.T) {
	for _, src := range []string{`"x"`, "@", "a $ b", "é", "!", "\\"} {
		found := false
		for _, tok := range Lex(src) {
			found = found || tok.Kind == TokInvalid
		}
		if !found {
			t.Errorf("Lex(%q) has no invalid token", src)
		}
	}
	toks := Lex("select 'abc")
	if k := kinds(toks); k[len(k)-1] != TokUnterminated {
		t.Errorf("want unterminated string, got %v", k)
	}
}

func TestDotSeparated(t *testing.T) {
	got := kinds(Lex("1.5"))
	want := []TokenKind{TokInt, TokPunct, TokInt}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("got %v want %v", got, want)
	}
}

func TestSplitStatements(t *testing.T) {
	stmts := SplitStatements(Lex(";; select 1; -- c\n ; select ';' ; select 2"))
	if len(stmts) != 3 {
		t.Fatalf("got %d statements, want 3", len(stmts))
	}
}

func TestParseOK(t *testing.T) {
	ok := []string{
		"CREATE TABLE t (a INTEGER, b TEXT)",
		"INSERT INTO t VALUES (1, 'a'), (2, NULL)",
		"DELETE FROM t",
		"DELETE FROM t WHERE a = 1",
		"UPDATE t SET a = a + 1, b = 'x' WHERE t.a > 0",
		"SELECT 1",
		"SELECT * FROM t",
		"SELECT a AS x, b y, count(*) FROM t e WHERE a IS NOT NULL GROUP BY a HAVING COUNT(b) > 1 ORDER BY x DESC, 1 LIMIT 3 OFFSET 1",
		"SELECT * FROM a, b",
		"SELECT * FROM a INNER JOIN b ON a.x = b.y",
		"SELECT * FROM a JOIN b ON a.x = b.y",
		"SELECT count FROM t",
		"SELECT count (*) FROM t",
		"SELECT NOT a = 1 AND b NOT LIKE 'x%' FROM t",
		"SELECT - -5, 1 - -1",
	}
	for _, src := range ok {
		parsed := ParseScript(src)
		if len(parsed) != 1 || parsed[0].Err != nil {
			t.Errorf("%q: %+v", src, parsed)
		}
	}
}

func TestParseErrors(t *testing.T) {
	bad := []string{
		"DROP TABLE t",
		"CREATE TABLE t (text TEXT)",
		"CREATE TABLE t (a REAL)",
		"CREATE TABLE t ()",
		"CREATE TABLE t (a)",
		"INSERT INTO t (a) VALUES (1)",
		"SELECT a AS left FROM t",
		"SELECT * FROM a LEFT JOIN b ON a.x = b.y",
		"SELECT * FROM a, b, c",
		"SELECT * FROM a, b JOIN c ON 1",
		"SELECT a IN (1) FROM t",
		"SELECT a BETWEEN 1 AND 2 FROM t",
		"SELECT 'a' || 'b'",
		"SELECT (SELECT 1)",
		"SELECT foo(1)",
		"SELECT 1.5",
		"SELECT * FROM t LIMIT -1",
		"SELECT * FROM t OFFSET 1",
		"SELECT * FROM t HAVING 1",
		"SELECT a FROM t GROUP BY a + 1",
		"SELECT * x FROM t",
		"SELECT 1 FROM t WHERE",
		"SELECT \"a\"",
		"SELECT 'open",
		"SELECT SUM(*) FROM t",
		"SELECT a NOT 1 FROM t",
		"SELECT 1 2",
		"",
	}
	for _, src := range bad {
		parsed := ParseScript(src)
		if src == "" {
			if len(parsed) != 0 {
				t.Errorf("empty input parsed to %d statements", len(parsed))
			}
			continue
		}
		if len(parsed) != 1 || parsed[0].Err == nil {
			t.Errorf("%q should be a syntax error, got %+v", src, parsed)
		}
	}
}

func TestPrecedence(t *testing.T) {
	st, err := ParseTokens(Lex("SELECT 1 < 2 = 1, -5 % 3, a + 1 IS NULL, NOT a = 1"))
	if err != nil {
		t.Fatal(err)
	}
	items := st.(*Select).Items
	if e := items[0].Expr; e.Kind != ExprBinary || e.Op != "=" || e.Left.Op != "<" {
		t.Errorf("1 < 2 = 1 mis-parsed: %+v", e)
	}
	if e := items[1].Expr; e.Op != "%" || e.Left.Kind != ExprNeg {
		t.Errorf("-5 %% 3 mis-parsed: %+v", e)
	}
	if e := items[2].Expr; e.Kind != ExprIsNull || e.Left.Op != "+" {
		t.Errorf("a + 1 IS NULL mis-parsed: %+v", e)
	}
	if e := items[3].Expr; e.Kind != ExprNot || e.Left.Op != "=" {
		t.Errorf("NOT a = 1 mis-parsed: %+v", e)
	}
}
