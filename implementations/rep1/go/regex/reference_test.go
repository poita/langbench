package regexbt_test

import (
	"math/rand"
	"testing"

	"example.com/regexbt"
	"example.com/regexbt/syntax"
)

// refMatch is a direct, continuation-passing transcription of section 3 of
// the specification, evaluated over the syntax tree. It is slow and uses
// recursion, and serves as an oracle for the compiled engine.
func refMatch(root *syntax.Node, ngroups int, s string) (regexbt.Match, bool) {
	type pair struct{ s, e int }
	caps := make([]*pair, ngroups+1)
	var m func(n *syntax.Node, i int, k func(int) bool) bool
	var rep func(n *syntax.Node, i, count int, k func(int) bool) bool
	rep = func(n *syntax.Node, i, count int, k func(int) bool) bool {
		x := n.Subs[0]
		if count < n.Min {
			return m(x, i, func(j int) bool { return rep(n, j, count+1, k) })
		}
		if count == n.Max {
			return k(i)
		}
		if m(x, i, func(j int) bool {
			if j == i {
				return k(j)
			}
			return rep(n, j, count+1, k)
		}) {
			return true
		}
		return k(i)
	}
	m = func(n *syntax.Node, i int, k func(int) bool) bool {
		switch n.Kind {
		case syntax.KindEmpty:
			return k(i)
		case syntax.KindLiteral:
			return i < len(s) && s[i] == n.Char && k(i+1)
		case syntax.KindAny:
			return i < len(s) && k(i+1)
		case syntax.KindClass:
			return i < len(s) && n.Set.Has(s[i]) && k(i+1)
		case syntax.KindBol:
			return i == 0 && k(i)
		case syntax.KindEol:
			return i == len(s) && k(i)
		case syntax.KindConcat:
			var seq func(idx, i int) bool
			seq = func(idx, i int) bool {
				if idx == len(n.Subs) {
					return k(i)
				}
				return m(n.Subs[idx], i, func(j int) bool { return seq(idx+1, j) })
			}
			return seq(0, i)
		case syntax.KindAlternate:
			for _, b := range n.Subs {
				if m(b, i, k) {
					return true
				}
			}
			return false
		case syntax.KindGroup:
			return m(n.Subs[0], i, func(j int) bool {
				old := caps[n.Group]
				caps[n.Group] = &pair{i, j}
				if k(j) {
					return true
				}
				caps[n.Group] = old
				return false
			})
		case syntax.KindRepeat:
			return rep(n, i, 0, k)
		}
		panic("unknown node")
	}
	for start := 0; start <= len(s); start++ {
		for g := range caps {
			caps[g] = nil
		}
		end := -1
		if m(root, start, func(j int) bool { end = j; return true }) {
			res := regexbt.Match{Start: start, End: end, Groups: make([]regexbt.Span, ngroups)}
			for g := 1; g <= ngroups; g++ {
				res.Groups[g-1] = regexbt.Span{Start: -1, End: -1}
				if caps[g] != nil {
					res.Groups[g-1] = regexbt.Span{Start: caps[g].s, End: caps[g].e}
				}
			}
			return res, true
		}
	}
	return regexbt.Match{}, false
}

// genPattern produces a random valid pattern over a tiny alphabet.
func genPattern(r *rand.Rand, depth int) string {
	var branch func(d int) string
	var atom func(d int) string
	atom = func(d int) string {
		switch c := r.Intn(14); {
		case c < 4:
			return string("abc"[r.Intn(3)])
		case c == 4:
			return "."
		case c == 5:
			return []string{"[ab]", "[^a]", `[a-c]`, `\w`, `\d`, `\S`, `[\da]`}[r.Intn(7)]
		case c == 6 && r.Intn(3) == 0:
			return []string{"^", "$"}[r.Intn(2)]
		case d > 0:
			return "(" + genAlt(r, d-1, branch) + ")"
		}
		return "a"
	}
	branch = func(d int) string {
		s := ""
		for n := r.Intn(3); n > 0; n-- {
			a := atom(d)
			if a != "^" && a != "$" {
				switch r.Intn(8) {
				case 0:
					a += "*"
				case 1:
					a += "+"
				case 2:
					a += "?"
				case 3:
					a += []string{"{0}", "{2}", "{1,}", "{0,2}", "{1,3}", "{2,}"}[r.Intn(6)]
				}
			}
			s += a
		}
		return s
	}
	return genAlt(r, depth, branch)
}

func genAlt(r *rand.Rand, d int, branch func(int) string) string {
	s := branch(d)
	for r.Intn(4) == 0 {
		s += "|" + branch(d)
	}
	return s
}

func TestAgainstReference(t *testing.T) {
	r := rand.New(rand.NewSource(1))
	checked := 0
	for iter := 0; iter < 20000; iter++ {
		pat := genPattern(r, 2)
		tree, ng, err := syntax.Parse(pat)
		if err != nil {
			t.Fatalf("generator produced invalid pattern %q: %v", pat, err)
		}
		re := regexbt.MustCompile(pat)
		for j := 0; j < 8; j++ {
			b := make([]byte, r.Intn(7))
			for i := range b {
				b[i] = "abc1 "[r.Intn(5)]
			}
			s := string(b)
			want, wok := refMatch(tree, ng, s)
			got, gok := re.Find(s)
			if format(got, gok) != format(want, wok) {
				t.Fatalf("%q on %q: got %q, want %q", pat, s, format(got, gok), format(want, wok))
			}
			checked++
		}
	}
	t.Logf("%d comparisons", checked)
}
