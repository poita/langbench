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

func eval(t testing.TB, src string) (*engine.Database, *ast.Program) {
	t.Helper()
	prog, err := parser.Parse(src)
	if err != nil {
		t.Fatal(err)
	}
	if err := analysis.CheckSafety(prog); err != nil {
		t.Fatal(err)
	}
	strata, err := analysis.Stratify(prog)
	if err != nil {
		t.Fatal(err)
	}
	return engine.Evaluate(prog, strata), prog
}

func answers(db *engine.Database, q ast.Atom) []string {
	var out []string
	for _, row := range db.Query(q) {
		parts := make([]string, len(row))
		for i, c := range row {
			parts[i] = c.String()
		}
		out = append(out, q.Pred+"("+strings.Join(parts, ", ")+")")
	}
	return out
}

func TestTransitiveClosure(t *testing.T) {
	db, prog := eval(t, `edge(1,2). edge(2,3). edge(3,1). edge(3,4).
path(X,Y) :- edge(X,Y). path(X,Z) :- edge(X,Y), path(Y,Z).
?- path(1,X). ?- path(4,X). ?- path(X,X).`)
	want := [][]string{
		{"path(1, 1)", "path(1, 2)", "path(1, 3)", "path(1, 4)"},
		nil,
		{"path(1, 1)", "path(2, 2)", "path(3, 3)"},
	}
	for i, q := range prog.Queries {
		if got := answers(db, q); !slices.Equal(got, want[i]) {
			t.Errorf("query %d: got %v, want %v", i, got, want[i])
		}
	}
}

func TestNonLinearRecursion(t *testing.T) {
	// Chain of 40 edges closed with a doubly recursive rule.
	var sb strings.Builder
	for i := 0; i < 40; i++ {
		fmt.Fprintf(&sb, "link(%d, %d). ", i, i+1)
	}
	sb.WriteString("link(X, Z) :- link(X, Y), link(Y, Z).")
	db, _ := eval(t, sb.String())
	if got, want := db.Size(ast.PredID{Name: "link", Arity: 2}), 41*40/2; got != want {
		t.Errorf("link has %d tuples, want %d", got, want)
	}
}

func TestMutualRecursion(t *testing.T) {
	db, prog := eval(t, `succ(0,1). succ(1,2). succ(2,3). succ(3,4).
even(0). odd(Y) :- even(X), succ(X,Y). even(Y) :- odd(X), succ(X,Y).
?- even(X). ?- odd(X).`)
	if got := answers(db, prog.Queries[0]); !slices.Equal(got, []string{"even(0)", "even(2)", "even(4)"}) {
		t.Errorf("even = %v", got)
	}
	if got := answers(db, prog.Queries[1]); !slices.Equal(got, []string{"odd(1)", "odd(3)"}) {
		t.Errorf("odd = %v", got)
	}
}

func TestNegationAndComparison(t *testing.T) {
	db, prog := eval(t, `node(a). node(b). node(c). node(5). node(-2).
link(a, b). link(b, 5). link(5, 5).
sink(X) :- node(X), not hasout(X).
hasout(X) :- link(X, _).
small(X) :- node(X), X < a.
?- sink(X). ?- small(X). ?- node(X).`)
	want := [][]string{
		{"sink(-2)", "sink(c)"},
		{"small(-2)", "small(5)"},
		{"node(-2)", "node(5)", "node(a)", "node(b)", "node(c)"},
	}
	for i, q := range prog.Queries {
		if got := answers(db, q); !slices.Equal(got, want[i]) {
			t.Errorf("query %d: got %v, want %v", i, got, want[i])
		}
	}
}

func TestQueryFeatures(t *testing.T) {
	db, _ := eval(t, "r(1, 1). r(1, 2). r(2, 2). r(a, a).")
	cases := map[string][]string{
		"r(X, X)":   {"r(1, 1)", "r(2, 2)", "r(a, a)"},
		"r(1, _)":   {"r(1, 1)", "r(1, 2)"},
		"r(_, _)":   {"r(1, 1)", "r(1, 2)", "r(2, 2)", "r(a, a)"},
		"r(2, 1)":   nil,
		"r(zzz, X)": nil, // constant unknown to the program
		"nope(X)":   nil,
		"r(X)":      nil, // other arity: empty predicate
	}
	for src, want := range cases {
		q, err := parser.ParseAtom(src)
		if err != nil {
			t.Fatal(err)
		}
		if got := answers(db, q); !slices.Equal(got, want) {
			t.Errorf("%s: got %v, want %v", src, got, want)
		}
	}
}

func TestBodyWithoutPositiveAtoms(t *testing.T) {
	db, prog := eval(t, "p(a) :- 1 < 2. q(a) :- 2 < 1. s(a) :- not t(b). ?- p(X). ?- q(X). ?- s(X).")
	for i, want := range []int{1, 0, 1} {
		if got := len(db.Query(prog.Queries[i])); got != want {
			t.Errorf("query %d: %d answers, want %d", i, got, want)
		}
	}
}

// naive is a reference evaluator: repeatedly apply all rules to the whole
// database until nothing changes, stratum by stratum.
func naive(prog *ast.Program, strata [][]ast.PredID) map[string]map[string]bool {
	model := map[ast.PredID]map[string]bool{}
	rel := func(id ast.PredID) map[string]bool {
		if model[id] == nil {
			model[id] = map[string]bool{}
		}
		return model[id]
	}
	key := func(cs []ast.Constant) string { return fmt.Sprint(cs) }
	for _, comp := range strata {
		in := map[ast.PredID]bool{}
		for _, id := range comp {
			in[id] = true
		}
		for changed := true; changed; {
			changed = false
			for _, r := range prog.Rules {
				if !in[r.Head.ID()] {
					continue
				}
				var rec func(i int, env map[string]ast.Constant)
				rec = func(i int, env map[string]ast.Constant) {
					if i == len(r.Body) {
						t := make([]ast.Constant, len(r.Head.Args))
						for k, a := range r.Head.Args {
							t[k] = valueOf(a, env)
						}
						if !rel(r.Head.ID())[key(t)] {
							rel(r.Head.ID())[key(t)] = true
							changed = true
						}
						return
					}
					l := r.Body[i]
					switch l.Kind {
					case ast.Comparison:
						if l.Op.Holds(ast.Compare(valueOf(l.Left, env), valueOf(l.Right, env))) {
							rec(i+1, env)
						}
					case ast.Negative:
						t := make([]ast.Constant, len(l.Atom.Args))
						for k, a := range l.Atom.Args {
							t[k] = valueOf(a, env)
						}
						if !rel(l.Atom.ID())[key(t)] {
							rec(i+1, env)
						}
					case ast.Positive:
						for _, tup := range candidates(prog, rel(l.Atom.ID()), len(l.Atom.Args)) {
							env2 := maps(env)
							ok := true
							for k, a := range l.Atom.Args {
								if a.IsVar {
									if v, bound := env2[a.Var]; bound && v != tup[k] {
										ok = false
									}
									env2[a.Var] = tup[k]
								} else if a.Const != tup[k] {
									ok = false
								}
							}
							if ok {
								rec(i+1, env2)
							}
						}
					}
				}
				rec(0, map[string]ast.Constant{})
			}
		}
	}
	out := map[string]map[string]bool{}
	for id, m := range model {
		out[id.String()] = m
	}
	return out
}

func maps(m map[string]ast.Constant) map[string]ast.Constant {
	c := make(map[string]ast.Constant, len(m)+2)
	for k, v := range m {
		c[k] = v
	}
	return c
}

func valueOf(t ast.Term, env map[string]ast.Constant) ast.Constant {
	if t.IsVar {
		return env[t.Var]
	}
	return t.Const
}

// candidates decodes the string-keyed tuples of a naive relation.
func candidates(_ *ast.Program, m map[string]bool, arity int) [][]ast.Constant {
	var out [][]ast.Constant
	for k := range m {
		fields := strings.Fields(strings.Trim(k, "[]"))
		row := make([]ast.Constant, len(fields))
		for i, f := range fields {
			var n int64
			if _, err := fmt.Sscan(f, &n); err == nil && fmt.Sprint(n) == f {
				row[i] = ast.Int(n)
			} else {
				row[i] = ast.Sym(f)
			}
		}
		if len(row) == arity {
			out = append(out, row)
		}
	}
	return out
}

// randomProgram generates a small program over a few predicates with
// recursion, negation of lower predicates and comparisons.
func randomProgram(rng *rand.Rand) string {
	consts := []string{"1", "2", "3", "-1", "a", "b", "c"}
	pick := func() string { return consts[rng.Intn(len(consts))] }
	vars := []string{"X", "Y", "Z", "W"}
	var sb strings.Builder
	for i := 0; i < 12; i++ {
		fmt.Fprintf(&sb, "e%d(%s, %s).\n", rng.Intn(2), pick(), pick())
	}
	// Predicates p0..p3 (binary); pi may use pj for j<=i positively
	// (recursion allowed) and pj for j<i negatively.
	for i := 0; i < 4; i++ {
		for r := 0; r < 1+rng.Intn(3); r++ {
			n := 1 + rng.Intn(3)
			var body []string
			used := []string{}
			for k := 0; k < n; k++ {
				var name string
				if rng.Intn(2) == 0 {
					name = fmt.Sprintf("e%d", rng.Intn(2))
				} else {
					name = fmt.Sprintf("p%d", rng.Intn(i+1))
				}
				a, b := vars[rng.Intn(3)], vars[rng.Intn(3)]
				if rng.Intn(6) == 0 {
					b = pick()
				}
				body = append(body, fmt.Sprintf("%s(%s, %s)", name, a, b))
				used = append(used, a, b)
			}
			bound := map[string]bool{}
			for _, u := range used {
				bound[u] = true
			}
			var vs []string
			for _, v := range vars {
				if bound[v] {
					vs = append(vs, v)
				}
			}
			if len(vs) == 0 {
				continue
			}
			v := func() string { return vs[rng.Intn(len(vs))] }
			if i > 0 && rng.Intn(3) == 0 {
				body = append(body, fmt.Sprintf("not p%d(%s, %s)", rng.Intn(i), v(), v()))
			}
			if rng.Intn(3) == 0 {
				ops := []string{"<", "<=", ">", ">=", "=", "!="}
				body = append(body, fmt.Sprintf("%s %s %s", v(), ops[rng.Intn(len(ops))], v()))
			}
			fmt.Fprintf(&sb, "p%d(%s, %s) :- %s.\n", i, v(), v(), strings.Join(body, ", "))
		}
	}
	return sb.String()
}

func TestAgainstNaiveEvaluator(t *testing.T) {
	rng := rand.New(rand.NewSource(1))
	for iter := 0; iter < 300; iter++ {
		src := randomProgram(rng)
		prog, err := parser.Parse(src)
		if err != nil {
			t.Fatalf("%v\n%s", err, src)
		}
		if err := analysis.CheckSafety(prog); err != nil {
			continue
		}
		strata, err := analysis.Stratify(prog)
		if err != nil {
			continue
		}
		db := engine.Evaluate(prog, strata)
		want := naive(prog, strata)
		for i := 0; i < 4; i++ {
			id := ast.PredID{Name: fmt.Sprintf("p%d", i), Arity: 2}
			q := ast.Atom{Pred: id.Name, Args: []ast.Term{ast.V("A"), ast.V("B")}}
			got := db.Query(q)
			if len(got) != len(want[id.String()]) {
				t.Fatalf("%s: engine %d tuples, naive %d\n%s", id, len(got), len(want[id.String()]), src)
			}
			for _, row := range got {
				if !want[id.String()][fmt.Sprint([]ast.Constant(row))] {
					t.Fatalf("%s: engine has extra tuple %v\n%s", id, row, src)
				}
			}
		}
	}
}

func BenchmarkChainClosure(b *testing.B) {
	var sb strings.Builder
	for i := 0; i < 500; i++ {
		fmt.Fprintf(&sb, "edge(%d, %d).\n", i, i+1)
	}
	sb.WriteString("path(X,Y) :- edge(X,Y). path(X,Z) :- edge(X,Y), path(Y,Z).\n")
	for i := 0; i < b.N; i++ {
		eval(b, sb.String())
	}
}
