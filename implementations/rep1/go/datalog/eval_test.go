package datalog

import (
	"fmt"
	"math/rand"
	"sort"
	"strings"
	"testing"
)

func solve(t *testing.T, src string) string {
	t.Helper()
	out, err := SolveString(src)
	if err != nil {
		t.Fatalf("SolveString: %v", err)
	}
	return out
}

func TestSpecExamples(t *testing.T) {
	cases := []struct{ name, in, want string }{
		{"closure", `
edge(1, 2). edge(2, 3). edge(3, 1). edge(3, 4).
path(X, Y) :- edge(X, Y).
path(X, Z) :- edge(X, Y), path(Y, Z).
?- path(1, X).
?- path(4, X).
?- path(X, X).`, `path(1, 1)
path(1, 2)
path(1, 3)
path(1, 4)
-- 4
-- 0
path(1, 1)
path(2, 2)
path(3, 3)
-- 3
`},
		{"negation", `
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
?- reach(X, X).`, `sink(-2)
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
`},
	}
	for _, c := range cases {
		if got := solve(t, c.in); got != c.want {
			t.Errorf("%s:\ngot:\n%s\nwant:\n%s", c.name, got, c.want)
		}
	}
}

func TestSolveErrors(t *testing.T) {
	for _, src := range []string{
		"edge(1, 2). win(X) :- edge(X, Y), not win(Y). ?- win(X).",
		"q(1). ?- q(X). p(X) :- q(Y). ?- p(X).",
	} {
		if _, err := SolveString(src); err == nil {
			t.Errorf("%q: want error", src)
		}
	}
	if _, err := SolveString("p("); err == nil {
		t.Error("want syntax error")
	}
}

func TestNoQueriesNoOutput(t *testing.T) {
	if got := solve(t, "p(1). q(X) :- p(X)."); got != "" {
		t.Errorf("got %q", got)
	}
}

func TestQueriesInOrderRegardlessOfClausePosition(t *testing.T) {
	got := solve(t, "?- p(X). p(1). ?- q(X). p(2).")
	want := "p(1)\np(2)\n-- 2\n-- 0\n"
	if got != want {
		t.Errorf("got %q want %q", got, want)
	}
}

func TestNonLinearRecursion(t *testing.T) {
	var sb strings.Builder
	for i := 0; i < 40; i++ {
		fmt.Fprintf(&sb, "link(%d, %d). ", i, i+1)
	}
	sb.WriteString("path(X, Y) :- link(X, Y). path(X, Z) :- path(X, Y), path(Y, Z). ?- path(X, Y).")
	got := solve(t, sb.String())
	if !strings.HasSuffix(got, "-- 820\n") { // 41*40/2
		t.Errorf("tail: %q", got[max(0, len(got)-20):])
	}
}

func TestMutualRecursion(t *testing.T) {
	src := `
zero(0). succ(0,1). succ(1,2). succ(2,3). succ(3,4). succ(4,5).
even(X) :- zero(X).
even(Y) :- odd(X), succ(X, Y).
odd(Y) :- even(X), succ(X, Y).
?- even(X).
?- odd(X).`
	want := "even(0)\neven(2)\neven(4)\n-- 3\nodd(1)\nodd(3)\nodd(5)\n-- 3\n"
	if got := solve(t, src); got != want {
		t.Errorf("got %q", got)
	}
}

func TestNegationAndComparisons(t *testing.T) {
	src := `
n(1). n(2). n(3). n(b). n(a).
big(X) :- n(X), X >= 2.
notbig(X) :- n(X), not big(X).
pair(X, Y) :- n(X), n(Y), X < Y, X != 2.
eq(X) :- n(X), X = a.
t(yes) :- 1 < 2.
f(yes) :- 2 < 1.
?- notbig(X).
?- eq(X).
?- t(X).
?- f(X).
?- pair(1, Y).
?- pair(a, Y).`
	want := "notbig(1)\n-- 1\neq(a)\n-- 1\nt(yes)\n-- 1\n-- 0\n" +
		"pair(1, 2)\npair(1, 3)\npair(1, a)\npair(1, b)\n-- 4\n" +
		"pair(a, b)\n-- 1\n"
	if got := solve(t, src); got != want {
		t.Errorf("got:\n%s\nwant:\n%s", got, want)
	}
}

func TestQueryPatterns(t *testing.T) {
	src := `
e(1,1,2). e(1,2,2). e(3,3,3). e(1,1,1).
?- e(X, X, Y).
?- e(_, _, _).
?- e(1, _, 2).
?- e(X, Y, X).
?- missing(X).
?- e(1, 2).`
	got := solve(t, src)
	want := "e(1, 1, 1)\ne(1, 1, 2)\ne(3, 3, 3)\n-- 3\n" +
		"e(1, 1, 1)\ne(1, 1, 2)\ne(1, 2, 2)\ne(3, 3, 3)\n-- 4\n" +
		"e(1, 1, 2)\ne(1, 2, 2)\n-- 2\n" +
		"e(1, 1, 1)\ne(3, 3, 3)\n-- 2\n-- 0\n-- 0\n"
	if got != want {
		t.Errorf("got:\n%s\nwant:\n%s", got, want)
	}
}

func TestRepeatedVariableInBody(t *testing.T) {
	got := solve(t, "edge(1,1). edge(1,2). edge(2,2). loop(X) :- edge(X, X). ?- loop(X).")
	if got != "loop(1)\nloop(2)\n-- 2\n" {
		t.Errorf("got %q", got)
	}
}

func TestSameNameDifferentArity(t *testing.T) {
	got := solve(t, "r(1). s(X, Y) :- r(X), r(Y). ?- r(X, Y). ?- s(X, Y).")
	if got != "-- 0\ns(1, 1)\n-- 1\n" {
		t.Errorf("got %q", got)
	}
}

func TestModelAPI(t *testing.T) {
	prog, err := Parse([]byte("p(b, 2). p(a, 1). p(a, -1). ?- p(a, X)."))
	if err != nil {
		t.Fatal(err)
	}
	m, err := Evaluate(prog)
	if err != nil {
		t.Fatal(err)
	}
	rel := m.Relation("p", 2)
	if len(rel) != 3 || rel[0][0] != Sym("a") || rel[0][1] != Int(-1) || rel[2][0] != Sym("b") {
		t.Errorf("Relation = %v", rel)
	}
	if m.Relation("p", 3) != nil {
		t.Error("unknown predicate should be empty")
	}
	ans := m.Answers()
	if len(ans) != 1 || ans[0].Pred.Name != "p" || len(ans[0].Tuples) != 2 {
		t.Errorf("Answers = %+v", ans)
	}
}

// naiveClosure computes the transitive closure of edges by naive iteration;
// it is the reference for the randomized test.
func naiveClosure(edges [][2]int) map[[2]int]bool {
	set := map[[2]int]bool{}
	for _, e := range edges {
		set[e] = true
	}
	for changed := true; changed; {
		changed = false
		for a := range set {
			for b := range set {
				if a[1] == b[0] && !set[[2]int{a[0], b[1]}] {
					set[[2]int{a[0], b[1]}] = true
					changed = true
				}
			}
		}
	}
	return set
}

func TestRandomGraphsAgainstNaive(t *testing.T) {
	rng := rand.New(rand.NewSource(1))
	for iter := 0; iter < 30; iter++ {
		n := 3 + rng.Intn(12)
		var edges [][2]int
		var sb strings.Builder
		for i := 0; i < n*2; i++ {
			e := [2]int{rng.Intn(n), rng.Intn(n)}
			edges = append(edges, e)
			fmt.Fprintf(&sb, "edge(%d, %d).\n", e[0], e[1])
		}
		// Left-, right- and doubly-recursive formulations must agree.
		sb.WriteString(`
p1(X, Y) :- edge(X, Y). p1(X, Z) :- p1(X, Y), edge(Y, Z).
p2(X, Y) :- edge(X, Y). p2(X, Z) :- edge(X, Y), p2(Y, Z).
p3(X, Y) :- edge(X, Y). p3(X, Z) :- p3(X, Y), p3(Y, Z).
unreach(X, Y) :- node(X), node(Y), not p3(X, Y).
node(X) :- edge(X, _). node(X) :- edge(_, X).
?- p1(X, Y). ?- p2(X, Y). ?- p3(X, Y). ?- unreach(X, Y).`)
		prog, err := Parse([]byte(sb.String()))
		if err != nil {
			t.Fatal(err)
		}
		m, err := Evaluate(prog)
		if err != nil {
			t.Fatal(err)
		}
		want := naiveClosure(edges)
		for _, name := range []string{"p1", "p2", "p3"} {
			got := m.Relation(name, 2)
			if len(got) != len(want) {
				t.Fatalf("iter %d %s: %d tuples, want %d", iter, name, len(got), len(want))
			}
			for _, tu := range got {
				if !want[[2]int{int(tu[0].Int), int(tu[1].Int)}] {
					t.Fatalf("iter %d %s: spurious %v", iter, name, tu)
				}
			}
			if !sort.SliceIsSorted(got, func(i, j int) bool {
				if got[i][0] != got[j][0] {
					return got[i][0].Compare(got[j][0]) < 0
				}
				return got[i][1].Compare(got[j][1]) < 0
			}) {
				t.Fatalf("%s not sorted", name)
			}
		}
		nodes := map[int]bool{}
		for _, e := range edges {
			nodes[e[0]], nodes[e[1]] = true, true
		}
		if got := len(m.Relation("unreach", 2)); got != len(nodes)*len(nodes)-len(want) {
			t.Fatalf("iter %d: unreach has %d tuples", iter, got)
		}
	}
}
