package regex_test

import (
	"math/rand"
	"reflect"
	"testing"

	"example.com/regex"
)

// A deliberately naive continuation-passing matcher written directly from the
// definition in section 3 of the specification, over a tiny pattern AST, used
// to cross-check the virtual machine on random patterns.

type rnode struct {
	kind     string // lit any cls bol eol seq alt grp rep
	ch       byte
	set      string
	subs     []*rnode
	g        int
	min, max int
}

func (n *rnode) String() string {
	switch n.kind {
	case "lit":
		return string(n.ch)
	case "any":
		return "."
	case "cls":
		return "[" + n.set + "]"
	case "bol":
		return "^"
	case "eol":
		return "$"
	case "seq":
		s := ""
		for _, c := range n.subs {
			s += c.String()
		}
		return s
	case "alt":
		s := ""
		for i, c := range n.subs {
			if i > 0 {
				s += "|"
			}
			s += c.String()
		}
		return s
	case "grp":
		return "(" + n.subs[0].String() + ")"
	}
	inner := n.subs[0].String()
	q := ""
	switch {
	case n.min == 0 && n.max < 0:
		q = "*"
	case n.min == 1 && n.max < 0:
		q = "+"
	case n.min == 0 && n.max == 1:
		q = "?"
	case n.max < 0:
		q = "{" + itoa(n.min) + ",}"
	case n.min == n.max:
		q = "{" + itoa(n.min) + "}"
	default:
		q = "{" + itoa(n.min) + "," + itoa(n.max) + "}"
	}
	return inner + q
}

func itoa(v int) string { return string(rune('0' + v)) }

type refMatcher struct {
	s    string
	caps [][2]int
}

func (r *refMatcher) m(n *rnode, i int, k func(int) bool) bool {
	switch n.kind {
	case "lit":
		return i < len(r.s) && r.s[i] == n.ch && k(i+1)
	case "any":
		return i < len(r.s) && k(i+1)
	case "cls":
		in := false
		if i < len(r.s) {
			for j := 0; j < len(n.set); j++ {
				if n.set[j] == r.s[i] {
					in = true
				}
			}
		}
		return in && k(i+1)
	case "bol":
		return i == 0 && k(i)
	case "eol":
		return i == len(r.s) && k(i)
	case "seq":
		return r.seq(n.subs, i, k)
	case "alt":
		for _, b := range n.subs {
			if r.m(b, i, k) {
				return true
			}
		}
		return false
	case "grp":
		return r.m(n.subs[0], i, func(j int) bool {
			old := r.caps[n.g]
			r.caps[n.g] = [2]int{i, j}
			if k(j) {
				return true
			}
			r.caps[n.g] = old
			return false
		})
	}
	return r.rep(n, i, 0, k)
}

func (r *refMatcher) seq(xs []*rnode, i int, k func(int) bool) bool {
	if len(xs) == 0 {
		return k(i)
	}
	return r.m(xs[0], i, func(j int) bool { return r.seq(xs[1:], j, k) })
}

func (r *refMatcher) rep(n *rnode, i, count int, k func(int) bool) bool {
	x := n.subs[0]
	if count < n.min {
		return r.m(x, i, func(j int) bool { return r.rep(n, j, count+1, k) })
	}
	if count == n.max {
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

func (r *refMatcher) find(root *rnode, ngroups int) []int {
	for start := 0; start <= len(r.s); start++ {
		r.caps = make([][2]int, ngroups+1)
		for g := range r.caps {
			r.caps[g] = [2]int{-1, -1}
		}
		end := -1
		if r.m(root, start, func(j int) bool { end = j; return true }) {
			out := []int{start, end}
			for g := 1; g <= ngroups; g++ {
				out = append(out, r.caps[g][0], r.caps[g][1])
			}
			return out
		}
	}
	return nil
}

type gen struct {
	rng    *rand.Rand
	groups int
}

func (g *gen) atom(depth int) *rnode {
	switch c := g.rng.Intn(10); {
	case c < 4:
		return &rnode{kind: "lit", ch: "abc"[g.rng.Intn(3)]}
	case c == 4:
		return &rnode{kind: "any"}
	case c == 5:
		return &rnode{kind: "cls", set: []string{"ab", "bc", "a", "ac"}[g.rng.Intn(4)]}
	case c == 6:
		if g.rng.Intn(2) == 0 {
			return &rnode{kind: "bol"}
		}
		return &rnode{kind: "eol"}
	default:
		if depth <= 0 {
			return &rnode{kind: "lit", ch: 'a'}
		}
		g.groups++
		id := g.groups
		return &rnode{kind: "grp", g: id, subs: []*rnode{g.alt(depth - 1)}}
	}
}

func (g *gen) seq(depth int) *rnode {
	n := &rnode{kind: "seq"}
	for i, cnt := 0, g.rng.Intn(4); i < cnt; i++ {
		a := g.atom(depth)
		if a.kind != "bol" && a.kind != "eol" && g.rng.Intn(2) == 0 {
			lo, hi := 0, -1
			switch g.rng.Intn(6) {
			case 0:
				lo, hi = 1, -1
			case 1:
				lo, hi = 0, 1
			case 2:
				lo = g.rng.Intn(3)
				hi = lo + g.rng.Intn(3)
			case 3:
				lo, hi = g.rng.Intn(3), -1
			}
			a = &rnode{kind: "rep", subs: []*rnode{a}, min: lo, max: hi}
		}
		n.subs = append(n.subs, a)
	}
	return n
}

func (g *gen) alt(depth int) *rnode {
	if g.rng.Intn(3) > 0 {
		return g.seq(depth)
	}
	n := &rnode{kind: "alt"}
	for i, cnt := 0, 2+g.rng.Intn(2); i < cnt; i++ {
		n.subs = append(n.subs, g.seq(depth))
	}
	return n
}

func TestAgainstReferenceMatcher(t *testing.T) {
	rng := rand.New(rand.NewSource(1))
	for iter := 0; iter < 5000; iter++ {
		g := &gen{rng: rng}
		root := g.alt(2)
		pat := root.String()
		re, err := regex.Compile(pat)
		if err != nil {
			t.Fatalf("Compile(%q): %v", pat, err)
		}
		for j := 0; j < 5; j++ {
			b := make([]byte, rng.Intn(6))
			for i := range b {
				b[i] = "abcd"[rng.Intn(4)]
			}
			want := (&refMatcher{s: string(b)}).find(root, g.groups)
			got := re.FindStringSubmatchIndex(string(b))
			if want != nil {
				for i := 2; i < len(want); i++ {
					if want[i] < 0 {
						want[i] = -1
					}
				}
			}
			if !reflect.DeepEqual(got, want) {
				t.Fatalf("%q on %q = %v, want %v", pat, b, got, want)
			}
		}
	}
}
