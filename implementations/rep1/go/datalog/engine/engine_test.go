package engine_test

import (
	"fmt"
	"math/rand"
	"slices"
	"strings"
	"testing"

	"example.com/datalog/analysis"
	"example.com/datalog/ast"
	"example.com/datalog/engine"
	"example.com/datalog/parser"
)

func eval(t testing.TB, src string) (*engine.DB, *ast.Program) {
	t.Helper()
	p, err := parser.Parse(src)
	if err != nil {
		t.Fatal(err)
	}
	if err := analysis.CheckSafety(p.Rules); err != nil {
		t.Fatal(err)
	}
	comps, err := analysis.Stratify(p.Rules)
	if err != nil {
		t.Fatal(err)
	}
	return engine.Evaluate(p.Rules, comps), p
}

func answers(db *engine.DB, p *ast.Program, q int) []string {
	var out []string
	for _, row := range db.Query(p.Queries[q]) {
		parts := make([]string, len(row))
		for i, v := range row {
			parts[i] = v.String()
		}
		out = append(out, strings.Join(parts, " "))
	}
	return out
}

func check(t *testing.T, src string, want ...[]string) {
	t.Helper()
	db, p := eval(t, src)
	for i, w := range want {
		if got := answers(db, p, i); !slices.Equal(got, w) {
			t.Errorf("query %d (%v): got %q, want %q", i, p.Queries[i], got, w)
		}
	}
}

func TestTransitiveClosure(t *testing.T) {
	check(t, `
		edge(1,2). edge(2,3). edge(3,1). edge(3,4).
		path(X,Y) :- edge(X,Y).
		path(X,Z) :- edge(X,Y), path(Y,Z).
		?- path(1,X). ?- path(4,X). ?- path(X,X).`,
		[]string{"1 1", "1 2", "1 3", "1 4"}, nil, []string{"1 1", "2 2", "3 3"})
}

func TestNonLinearRecursion(t *testing.T) {
	// Both body atoms recursive: each must be usable as the delta atom.
	check(t, `
		link(1,2). link(2,3). link(3,4). link(4,5).
		link(X,Z) :- link(X,Y), link(Y,Z).
		?- link(1,X).`,
		[]string{"1 2", "1 3", "1 4", "1 5"})
}

func TestMutualRecursion(t *testing.T) {
	check(t, `
		zero(0). succ(0,1). succ(1,2). succ(2,3). succ(3,4).
		even(X) :- zero(X).
		even(X) :- succ(Y,X), odd(Y).
		odd(X) :- succ(Y,X), even(Y).
		?- even(X). ?- odd(X).`,
		[]string{"0", "2", "4"}, []string{"1", "3"})
}

func TestFactsInRecursivePredicate(t *testing.T) {
	// Facts of a recursive predicate seed the first delta.
	check(t, `
		r(a, b). r(b, c).
		s(c, d). s(b, e).
		r(X, Z) :- r(X, Y), s(Y, Z).
		?- r(X, Y).`,
		[]string{"a b", "a e", "b c", "b d"})
}

func TestNegationAndComparisons(t *testing.T) {
	check(t, `
		node(a). node(b). node(c). node(5). node(-2).
		link(a,b). link(b,5). link(5,5).
		reach(X,Y) :- link(X,Y).
		reach(X,Z) :- reach(X,Y), link(Y,Z).
		sink(X) :- node(X), not hasout(X).
		hasout(X) :- link(X,_).
		small(X) :- node(X), X < a.
		?- sink(X). ?- small(X). ?- reach(a,X). ?- reach(X,X).`,
		[]string{"-2", "c"}, []string{"-2", "5"}, []string{"a 5", "a b"}, []string{"5 5"})
}

func TestComparisonOperators(t *testing.T) {
	check(t, `
		v(-1). v(0). v(3). v(abc). v(abd).
		lt(X) :- v(X), X < 3.
		le(X) :- v(X), X <= 3.
		gt(X) :- v(X), X > 3.
		ge(X) :- v(X), X >= abc.
		ne(X) :- v(X), X != 0.
		eq(X, Y) :- v(X), v(Y), X = Y, X > 0.
		cc(X) :- v(X), 5 < abc, X = 0.
		?- lt(X). ?- le(X). ?- gt(X). ?- ge(X). ?- ne(X). ?- eq(X,Y). ?- cc(X).`,
		[]string{"-1", "0"}, []string{"-1", "0", "3"}, []string{"abc", "abd"},
		[]string{"abc", "abd"}, []string{"-1", "3", "abc", "abd"},
		[]string{"3 3", "abc abc", "abd abd"}, []string{"0"})
}

func TestRepeatedVariables(t *testing.T) {
	check(t, `
		e(1,1). e(1,2). e(2,2). e(3,1).
		loop(X) :- e(X,X).
		same(X) :- e(X,Y), e(Y,X), X != Y.
		?- loop(X). ?- e(X,X). ?- e(_,_). ?- same(X).`,
		[]string{"1", "2"}, []string{"1 1", "2 2"}, []string{"1 1", "1 2", "2 2", "3 1"}, nil)
}

func TestConstantsInBodiesAndHeads(t *testing.T) {
	check(t, `
		e(a, 1). e(b, 2). e(a, 3).
		p(a, X) :- e(a, X).
		q(Y) :- e(b, Y), not e(a, Y).
		r(done) :- 1 < 2.
		s(done) :- 2 < 1.
		t(x) :- not e(c, 9), 1 = 1.
		?- p(a, X). ?- q(X). ?- r(X). ?- s(X). ?- t(X).`,
		[]string{"a 1", "a 3"}, []string{"2"}, []string{"done"}, nil, []string{"x"})
}

func TestMissingPredicates(t *testing.T) {
	check(t, `
		p(X) :- q(X), not nothing(X).
		q(1).
		?- p(X). ?- nope(X). ?- p(zzz). ?- q(X, Y).`,
		[]string{"1"}, nil, nil, nil)
}

func TestSameNameDifferentArity(t *testing.T) {
	check(t, `
		r(1, 2).
		s(X) :- r(X), not r(X, X).
		t(X) :- r(X, _).
		?- s(X). ?- t(X). ?- r(X).`,
		nil, []string{"1"}, nil)
}

// naive is a straightforward reference evaluator used to cross-check the
// semi-naive engine on random programs. It evaluates the given strata in
// order, each to a fixpoint.
func naive(rules []ast.Rule, comps []analysis.Component) map[ast.Pred]map[string]bool {
	model := map[ast.Pred]map[string]bool{}
	get := func(p ast.Pred) map[string]bool {
		if model[p] == nil {
			model[p] = map[string]bool{}
		}
		return model[p]
	}
	key := func(vs []ast.Value) string {
		parts := make([]string, len(vs))
		for i, v := range vs {
			if v.IsInt() {
				parts[i] = "i" + v.String()
			} else {
				parts[i] = "s" + v.String()
			}
		}
		return strings.Join(parts, ",")
	}
	var solve func(r ast.Rule, i int, env map[string]ast.Value) [][]ast.Value
	val := func(t ast.Term, env map[string]ast.Value) ast.Value {
		if t.IsVar {
			return env[t.Name]
		}
		return t.Value
	}
	solve = func(r ast.Rule, i int, env map[string]ast.Value) [][]ast.Value {
		if i == len(r.Body) {
			var h []ast.Value
			for _, a := range r.Head.Args {
				h = append(h, val(a, env))
			}
			return [][]ast.Value{h}
		}
		l := r.Body[i]
		switch l.Kind {
		case ast.Comparison:
			if l.Op.Holds(ast.Compare(val(l.Left, env), val(l.Right, env))) {
				return solve(r, i+1, env)
			}
			return nil
		case ast.Negative:
			var vs []ast.Value
			for _, a := range l.Atom.Args {
				vs = append(vs, val(a, env))
			}
			if get(l.Atom.Pred())[key(vs)] {
				return nil
			}
			return solve(r, i+1, env)
		}
		var out [][]ast.Value
		for k := range get(l.Atom.Pred()) {
			parts := strings.Split(k, ",")
			ok := true
			env2 := maps(env)
			for j, a := range l.Atom.Args {
				var v ast.Value
				if parts[j][0] == 'i' {
					var n int64
					fmt.Sscan(parts[j][1:], &n)
					v = ast.Int(n)
				} else {
					v = ast.Sym(parts[j][1:])
				}
				if !a.IsVar {
					ok = a.Value == v
				} else if old, bound := env2[a.Name]; bound {
					ok = old == v
				} else {
					env2[a.Name] = v
				}
				if !ok {
					break
				}
			}
			if ok {
				out = append(out, solve(r, i+1, env2)...)
			}
		}
		return out
	}
	for _, c := range comps {
		in := map[ast.Pred]bool{}
		for _, p := range c.Preds {
			in[p] = true
		}
		for changed := true; changed; {
			changed = false
			for _, r := range rules {
				if !in[r.Head.Pred()] {
					continue
				}
				for _, h := range solve(r, 0, map[string]ast.Value{}) {
					if k := key(h); !get(r.Head.Pred())[k] {
						get(r.Head.Pred())[k] = true
						changed = true
					}
				}
			}
		}
	}
	return model
}

func maps(m map[string]ast.Value) map[string]ast.Value {
	c := make(map[string]ast.Value, len(m)+4)
	for k, v := range m {
		c[k] = v
	}
	return c
}

// randomProgram builds a stratified program: stratum 0 has recursive and
// non-linear rules over e/2 and u/1, stratum 1 negates stratum 0.
func randomProgram(rng *rand.Rand) string {
	var sb strings.Builder
	consts := []string{"a", "b", "c", "d", "0", "1", "-3", "zz"}
	c := func() string { return consts[rng.Intn(len(consts))] }
	for i := 0; i < 12; i++ {
		fmt.Fprintf(&sb, "e(%s, %s).\n", c(), c())
	}
	for i := 0; i < 5; i++ {
		fmt.Fprintf(&sb, "u(%s).\n", c())
	}
	sb.WriteString("p(X, Y) :- e(X, Y).\n")
	rules0 := []string{
		"p(X, Z) :- p(X, Y), p(Y, Z).",
		"p(X, Z) :- e(X, Y), p(Y, Z).",
		"q(X, Y) :- p(X, Y), u(X).",
		"q(X, Z) :- q(X, Y), e(Y, Z), X != Z.",
		"p(X, Y) :- q(Y, X), X < Y.",
		"r(X) :- p(X, X).",
		"r(X) :- q(X, _), u(X).",
		"q(X, a) :- r(X).",
	}
	for _, r := range rules0 {
		if rng.Intn(3) > 0 {
			sb.WriteString(r + "\n")
		}
	}
	rules1 := []string{
		"s(X) :- u(X), not r(X).",
		"s(X) :- p(X, _), not q(X, X).",
		"w(X, Y) :- s(X), s(Y), not p(X, Y), X <= Y.",
		"w(X, X) :- e(X, _), not s(X).",
	}
	for _, r := range rules1 {
		if rng.Intn(3) > 0 {
			sb.WriteString(r + "\n")
		}
	}
	return sb.String()
}

func TestAgainstNaive(t *testing.T) {
	rng := rand.New(rand.NewSource(1))
	for iter := 0; iter < 300; iter++ {
		src := randomProgram(rng)
		p, err := parser.Parse(src)
		if err != nil {
			t.Fatal(err)
		}
		if err := analysis.CheckSafety(p.Rules); err != nil {
			t.Fatalf("%v\n%s", err, src)
		}
		comps, err := analysis.Stratify(p.Rules)
		if err != nil {
			t.Fatalf("%v\n%s", err, src)
		}
		db := engine.Evaluate(p.Rules, comps)
		want := naive(p.Rules, comps)
		for _, c := range comps {
			for _, pr := range c.Preds {
				if got := db.Size(pr); got != len(want[pr]) {
					t.Fatalf("iter %d: |%v| = %d, want %d\n%s", iter, pr, got, len(want[pr]), src)
				}
			}
		}
	}
}

func BenchmarkChainClosure(b *testing.B) {
	var sb strings.Builder
	for i := 1; i < 500; i++ {
		fmt.Fprintf(&sb, "edge(%d, %d).\n", i, i+1)
	}
	sb.WriteString("path(X,Y) :- edge(X,Y).\npath(X,Z) :- edge(X,Y), path(Y,Z).\n")
	p, _ := parser.Parse(sb.String())
	comps, _ := analysis.Stratify(p.Rules)
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		engine.Evaluate(p.Rules, comps)
	}
}
