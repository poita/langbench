package regex_test

import (
	"math/rand"
	"testing"

	"regex"
	"regex/syntax"
)

// refMatch is a direct transcription of the continuation-passing definition
// in the specification (section 3), used as an oracle for the VM.
type refMatcher struct {
	s    string
	caps []int // 2 per group, -1 unset
}

func (r *refMatcher) m(n *syntax.Node, i int, k func(int) bool) bool {
	switch n.Kind {
	case syntax.KindLiteral:
		return i < len(r.s) && r.s[i] == n.Char && k(i+1)
	case syntax.KindAny:
		return i < len(r.s) && k(i+1)
	case syntax.KindClass:
		return i < len(r.s) && n.Set[r.s[i]] && k(i+1)
	case syntax.KindBOL:
		return i == 0 && k(i)
	case syntax.KindEOL:
		return i == len(r.s) && k(i)
	case syntax.KindSeq:
		return r.seq(n.Subs, i, k)
	case syntax.KindAlt:
		for _, b := range n.Subs {
			if r.m(b, i, k) {
				return true
			}
		}
		return false
	case syntax.KindGroup:
		g := n.Index - 1
		return r.m(n.Subs[0], i, func(j int) bool {
			os, oe := r.caps[2*g], r.caps[2*g+1]
			r.caps[2*g], r.caps[2*g+1] = i, j
			if k(j) {
				return true
			}
			r.caps[2*g], r.caps[2*g+1] = os, oe
			return false
		})
	case syntax.KindRep:
		return r.rep(n, i, 0, k)
	}
	panic("bad node")
}

func (r *refMatcher) seq(xs []*syntax.Node, i int, k func(int) bool) bool {
	if len(xs) == 0 {
		return k(i)
	}
	return r.m(xs[0], i, func(j int) bool { return r.seq(xs[1:], j, k) })
}

func (r *refMatcher) rep(n *syntax.Node, i, count int, k func(int) bool) bool {
	x := n.Subs[0]
	if count < n.Min {
		return r.m(x, i, func(j int) bool { return r.rep(n, j, count+1, k) })
	}
	if count == n.Max {
		return k(i)
	}
	if r.m(x, i, func(j int) bool {
		if j == i {
			return k(j)
		}
		return r.rep(n, j, count+1, k)
	}) {
		return true
	}
	return k(i)
}

func refFind(t *syntax.Tree, s string) []int {
	for start := 0; start <= len(s); start++ {
		r := &refMatcher{s: s, caps: make([]int, 2*t.NumGroups)}
		for i := range r.caps {
			r.caps[i] = -1
		}
		end := -1
		if r.m(t.Root, start, func(j int) bool { end = j; return true }) {
			return append([]int{start, end}, r.caps...)
		}
	}
	return nil
}

func randPattern(rng *rand.Rand, depth int) string {
	atoms := []string{"a", "b", "c", ".", "[ab]", "[^a]", `\w`, `\D`, "^", "$"}
	var gen func(d int) string
	gen = func(d int) string {
		switch r := rng.Intn(10); {
		case r < 4 || d == 0:
			a := atoms[rng.Intn(len(atoms))]
			if a == "^" || a == "$" {
				return a
			}
			return a + quant(rng)
		case r < 7:
			return gen(d-1) + gen(d-1)
		case r < 9:
			return "(" + gen(d-1) + ")" + quant(rng)
		default:
			return "(" + gen(d-1) + "|" + gen(d-1) + ")" + quant(rng)
		}
	}
	return gen(depth)
}

func quant(rng *rand.Rand) string {
	qs := []string{"", "", "", "*", "+", "?", "{2}", "{0,2}", "{1,}", "{0}", "{2,3}"}
	return qs[rng.Intn(len(qs))]
}

func TestAgainstReference(t *testing.T) {
	rng := rand.New(rand.NewSource(1))
	for iter := 0; iter < 30000; iter++ {
		pat := randPattern(rng, 3)
		tree, err := syntax.Parse(pat)
		if err != nil {
			continue
		}
		re, err := regex.Compile(pat)
		if err != nil {
			t.Fatalf("Compile(%q): %v", pat, err)
		}
		for j := 0; j < 5; j++ {
			b := make([]byte, rng.Intn(7))
			for i := range b {
				b[i] = "abc"[rng.Intn(3)]
			}
			want := refFind(tree, string(b))
			got := re.FindSubmatchIndex(b)
			if !equalInts(want, got) {
				t.Fatalf("pattern %q subject %q: got %v, want %v\n%s", pat, b, got, want, re.Program())
			}
		}
	}
}

func equalInts(a, b []int) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
