package datalog

import (
	"bytes"
	"fmt"
	"strings"
	"testing"
)

// solve runs src and returns the formatted answers of its queries.
func solve(t *testing.T, src string) string {
	t.Helper()
	m, err := mustParse(t, src).Solve()
	if err != nil {
		t.Fatalf("Solve: %v", err)
	}
	var buf bytes.Buffer
	if err := WriteAnswers(&buf, m.Answers()); err != nil {
		t.Fatal(err)
	}
	return buf.String()
}

func TestTransitiveClosure(t *testing.T) {
	got := solve(t, `
edge(1, 2). edge(2, 3). edge(3, 1). edge(3, 4).
path(X, Y) :- edge(X, Y).
path(X, Z) :- edge(X, Y), path(Y, Z).
?- path(1, X).
?- path(4, X).
?- path(X, X).`)
	want := `path(1, 1)
path(1, 2)
path(1, 3)
path(1, 4)
-- 4
-- 0
path(1, 1)
path(2, 2)
path(3, 3)
-- 3
`
	if got != want {
		t.Fatalf("got:\n%s\nwant:\n%s", got, want)
	}
}

func TestNegationComparisonsMixedConstants(t *testing.T) {
	got := solve(t, `
% nodes and links
node(a). node(b). node(c). node(5). node(-2).
link(a, b). link(b, 5). link(5, 5).
reach(X, Y) :- link(X, Y).
reach(X, Z) :- reach(X, Y), link(Y, Z).
sink(X) :- node(X), not hasout(X).
hasout(X) :- link(X, _).
small(X) :- node(X), X < a.
?- sink(X).
?- small(X).
?- reach(a, X).
?- reach(X, X).`)
	want := `sink(-2)
sink(c)
-- 2
small(-2)
small(5)
-- 2
reach(a, 5)
reach(a, b)
-- 2
reach(5, 5)
-- 1
`
	if got != want {
		t.Fatalf("got:\n%s\nwant:\n%s", got, want)
	}
}

func TestNonLinearRecursion(t *testing.T) {
	// link(X,Z) :- link(X,Y), link(Y,Z) needs a delta variant at both positions.
	var sb strings.Builder
	const n = 40
	for i := 0; i < n; i++ {
		fmt.Fprintf(&sb, "link(%d, %d). ", i, i+1)
	}
	sb.WriteString("link(X, Z) :- link(X, Y), link(Y, Z). ?- link(0, X). ?- link(X, X).")
	got := solve(t, sb.String())
	if !strings.Contains(got, "-- 40\n") || !strings.HasSuffix(got, "-- 0\n") {
		t.Fatalf("unexpected result:\n%s", got)
	}
	m, _ := mustParse(t, sb.String()).Solve()
	if rows := m.Relation("link", 2); len(rows) != (n+1)*n/2 {
		t.Fatalf("link has %d tuples, want %d", len(rows), (n+1)*n/2)
	}
}

func TestMutualRecursion(t *testing.T) {
	var sb strings.Builder
	for i := 0; i < 50; i++ {
		fmt.Fprintf(&sb, "succ(%d, %d). ", i, i+1)
	}
	sb.WriteString(`even(0). odd(Y) :- even(X), succ(X, Y). even(Y) :- odd(X), succ(X, Y).
?- even(X).`)
	got := solve(t, sb.String())
	if !strings.HasSuffix(got, "even(50)\n-- 26\n") || !strings.HasPrefix(got, "even(0)\neven(2)\n") {
		t.Fatalf("unexpected result:\n%s", got)
	}
}

func TestMutualNonLinearJoin(t *testing.T) {
	// a and b recurse through each other and are joined in one body.
	got := solve(t, `
s(1). t(2). e(1,2). e(2,3). e(3,4). e(4,5).
a(X) :- s(X).
b(X) :- t(X).
a(Z) :- b(X), a(Y), e(Y, X), e(X, Z).
b(Z) :- a(X), b(Y), e(X, Z), e(Y, Z).
?- a(X).
?- b(X).`)
	// a(1), b(2) ; a(3) from b(2),a(1),e(1,2),e(2,3) ; b(3) from a(1),b(2),e(1,3)? no e(1,3).
	want := "a(1)\na(3)\n-- 2\nb(2)\n-- 1\n"
	if got != want {
		t.Fatalf("got:\n%s\nwant:\n%s", got, want)
	}
}

func TestFactsAndRulesSamePredicate(t *testing.T) {
	got := solve(t, `p(1). p(2) :- q(1). q(1). p(1) :- q(1). ?- p(X).`)
	if got != "p(1)\np(2)\n-- 2\n" {
		t.Fatalf("got %q", got)
	}
}

func TestComparisons(t *testing.T) {
	got := solve(t, `
v(1). v(2). v(a). v(b). v(-1).
lt(X, Y) :- v(X), v(Y), X < Y.
le1(X) :- v(X), X <= 1.
ne(X, Y) :- v(X), v(Y), X != Y, X = 1.
ge(X) :- v(X), X >= b.
?- le1(X).
?- ge(X).
?- ne(X, Y).
?- lt(a, X).
?- lt(b, a).`)
	want := `le1(-1)
le1(1)
-- 2
ge(b)
-- 1
ne(1, -1)
ne(1, 2)
ne(1, a)
ne(1, b)
-- 4
lt(a, b)
-- 1
-- 0
`
	if got != want {
		t.Fatalf("got:\n%s\nwant:\n%s", got, want)
	}
}

func TestRepeatedVariableInAtom(t *testing.T) {
	got := solve(t, `
e(1,1). e(1,2). e(2,2). e(2,1,1).
loop(X) :- e(X, X).
?- loop(X).
?- e(X, X).
?- e(X, Y, X).
?- e(_, _).`)
	want := `loop(1)
loop(2)
-- 2
e(1, 1)
e(2, 2)
-- 2
-- 0
e(1, 1)
e(1, 2)
e(2, 2)
-- 3
`
	if got != want {
		t.Fatalf("got:\n%s\nwant:\n%s", got, want)
	}
}

func TestConstantsInRulesAndHeads(t *testing.T) {
	got := solve(t, `
e(1, a). e(2, b). e(3, a).
tag(X, found) :- e(X, a).
none(7) :- not e(0, z).
yes(0) :- 1 < 2.
no(0) :- 2 < 1.
?- tag(X, Y).
?- none(X).
?- yes(X).
?- no(X).`)
	want := "tag(1, found)\ntag(3, found)\n-- 2\nnone(7)\n-- 1\nyes(0)\n-- 1\n-- 0\n"
	if got != want {
		t.Fatalf("got:\n%s\nwant:\n%s", got, want)
	}
}

func TestStrataChain(t *testing.T) {
	got := solve(t, `
n(1). n(2). n(3). n(4).
e(1, 2). e(2, 3).
a(X) :- e(X, _).
b(X) :- n(X), not a(X).
c(X) :- n(X), not b(X).
?- b(X).
?- c(X).`)
	if got != "b(3)\nb(4)\n-- 2\nc(1)\nc(2)\n-- 2\n" {
		t.Fatalf("got %q", got)
	}
}

func TestUndefinedPredicatesAndArity(t *testing.T) {
	got := solve(t, `
r(1). q(X) :- r(X), not nothing(X).
?- missing(X).
?- r(X, Y).
?- q(X).`)
	if got != "-- 0\n-- 0\nq(1)\n-- 1\n" {
		t.Fatalf("got %q", got)
	}
}

func TestNoQueriesNoOutput(t *testing.T) {
	if got := solve(t, "p(1). q(X) :- p(X)."); got != "" {
		t.Fatalf("got %q", got)
	}
	if got := solve(t, ""); got != "" {
		t.Fatalf("got %q", got)
	}
}

func TestQueriesAnsweredInOrder(t *testing.T) {
	got := solve(t, "?- p(X). p(1). ?- p(2). q(1). ?- q(X).")
	if got != "p(1)\n-- 1\n-- 0\nq(1)\n-- 1\n" {
		t.Fatalf("got %q", got)
	}
}

func TestRelationAccessor(t *testing.T) {
	m, err := mustParse(t, "p(b, 2). p(a, 3). p(a, -1).").Solve()
	if err != nil {
		t.Fatal(err)
	}
	rows := m.Relation("p", 2)
	var got []string
	for _, r := range rows {
		got = append(got, fmt.Sprint(r))
	}
	if len(rows) != 3 || rows[0][0].String() != "a" || rows[0][1].Int() != -1 || rows[2][0].Name() != "b" {
		t.Fatalf("rows = %v", got)
	}
	if m.Relation("p", 1) != nil || m.Relation("zzz", 2) != nil {
		t.Fatal("unknown predicate should be empty")
	}
}

// TestAgainstNaive cross-checks semi-naive evaluation against a tiny naive
// transitive closure on random graphs, with a non-linear rule.
func TestAgainstNaive(t *testing.T) {
	for seed := 0; seed < 20; seed++ {
		const n = 12
		adj := [n][n]bool{}
		var sb strings.Builder
		x := uint32(seed*7919 + 13)
		for i := 0; i < 25; i++ {
			x = x*1664525 + 1013904223
			a, b := (x>>8)%n, (x>>16)%n
			adj[a][b] = true
			fmt.Fprintf(&sb, "e(%d, %d). ", a, b)
		}
		sb.WriteString("t(X, Y) :- e(X, Y). t(X, Z) :- t(X, Y), t(Y, Z). ?- t(X, Y).")
		reach := adj
		for k := 0; k < n; k++ {
			for i := 0; i < n; i++ {
				for j := 0; j < n; j++ {
					if reach[i][k] && reach[k][j] {
						reach[i][j] = true
					}
				}
			}
		}
		cnt := 0
		for i := range reach {
			for j := range reach[i] {
				if reach[i][j] {
					cnt++
				}
			}
		}
		got := solve(t, sb.String())
		if !strings.HasSuffix(got, fmt.Sprintf("-- %d\n", cnt)) {
			t.Fatalf("seed %d: want %d tuples, got tail %q", seed, cnt, got[max(0, len(got)-12):])
		}
	}
}
