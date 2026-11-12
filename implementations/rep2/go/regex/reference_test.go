package regex

import (
	"fmt"
	"math/rand"
	"strings"
	"testing"

	"example.com/regex/syntax"
)

// refMatch is a direct transcription of the continuation-passing definition
// of matching, evaluated over the syntax tree with no optimisation. It serves
// as an oracle for the compiled matcher.
type refMatch struct {
	s    string
	caps [][2]int // -1 = unset
}

func (r *refMatch) m(n *syntax.Node, i int, k func(int) bool) bool {
	switch n.Kind {
	case syntax.Empty:
		return k(i)
	case syntax.Literal:
		return i < len(r.s) && r.s[i] == n.Char && k(i+1)
	case syntax.AnyChar:
		return i < len(r.s) && k(i+1)
	case syntax.Class:
		return i < len(r.s) && n.Set.Has(r.s[i]) && k(i+1)
	case syntax.StartAnchor:
		return i == 0 && k(i)
	case syntax.EndAnchor:
		return i == len(r.s) && k(i)
	case syntax.Concat:
		return r.seq(n.Subs, i, k)
	case syntax.Alternate:
		for _, b := range n.Subs {
			if r.m(b, i, k) {
				return true
			}
		}
		return false
	case syntax.Group:
		return r.m(n.Subs[0], i, func(j int) bool {
			old := r.caps[n.Index]
			r.caps[n.Index] = [2]int{i, j}
			if k(j) {
				return true
			}
			r.caps[n.Index] = old
			return false
		})
	case syntax.Repeat:
		return r.rep(n.Subs[0], n.Min, n.Max, i, 0, k)
	}
	panic("unreachable")
}

func (r *refMatch) seq(xs []*syntax.Node, i int, k func(int) bool) bool {
	if len(xs) == 0 {
		return k(i)
	}
	return r.m(xs[0], i, func(j int) bool { return r.seq(xs[1:], j, k) })
}

func (r *refMatch) rep(x *syntax.Node, min, max, i, count int, k func(int) bool) bool {
	if count < min {
		return r.m(x, i, func(j int) bool { return r.rep(x, min, max, j, count+1, k) })
	}
	if count == max {
		return k(i)
	}
	if r.m(x, i, func(j int) bool {
		if j == i {
			return k(j)
		}
		return r.rep(x, min, max, j, count+1, k)
	}) {
		return true
	}
	return k(i)
}

func refFind(root *syntax.Node, groups int, s string) string {
	r := &refMatch{s: s}
	for start := 0; start <= len(s); start++ {
		r.caps = make([][2]int, groups+1)
		for g := range r.caps {
			r.caps[g] = [2]int{-1, -1}
		}
		end := -1
		if r.m(root, start, func(j int) bool { end = j; return true }) {
			var b strings.Builder
			fmt.Fprintf(&b, "match %d %d", start, end)
			for g := 1; g <= groups; g++ {
				if r.caps[g][0] < 0 {
					b.WriteString("|-")
				} else {
					fmt.Fprintf(&b, "|%d,%d", r.caps[g][0], r.caps[g][1])
				}
			}
			return b.String()
		}
	}
	return "no"
}

// genPattern builds a random valid pattern over a tiny alphabet.
func genPattern(rng *rand.Rand, depth int) string {
	var b strings.Builder
	branches := 1
	if rng.Intn(4) == 0 {
		branches = 2 + rng.Intn(2)
	}
	for br := 0; br < branches; br++ {
		if br > 0 {
			b.WriteByte('|')
		}
		for n := rng.Intn(4); n > 0; n-- {
			b.WriteString(genPiece(rng, depth))
		}
	}
	return b.String()
}

func genPiece(rng *rand.Rand, depth int) string {
	var atom string
	quantifiable := true
	switch k := rng.Intn(12); {
	case k < 4:
		atom = string("abc"[rng.Intn(3)])
	case k == 4:
		atom = "."
	case k == 5:
		atom = []string{"[ab]", "[^a]", `\w`, `\d`, "[a-b]", `\S`, `[b-]`}[rng.Intn(7)]
	case k == 6:
		atom = []string{"^", "$"}[rng.Intn(2)]
		quantifiable = false
	default:
		if depth == 0 {
			atom = "a"
		} else {
			atom = "(" + genPattern(rng, depth-1) + ")"
		}
	}
	if !quantifiable || rng.Intn(2) == 0 {
		return atom
	}
	q := []string{"*", "+", "?", "{0}", "{2}", "{1,}", "{0,2}", "{1,3}", "{2,}"}
	return atom + q[rng.Intn(len(q))]
}

func genSubject(rng *rand.Rand) string {
	b := make([]byte, rng.Intn(9))
	for i := range b {
		b[i] = "aabbc1 "[rng.Intn(7)]
	}
	return string(b)
}

func TestAgainstReference(t *testing.T) {
	rng := rand.New(rand.NewSource(1))
	iterations := 3000
	if testing.Short() {
		iterations = 500
	}
	for it := 0; it < iterations; it++ {
		pat := genPattern(rng, 2)
		root, groups, err := syntax.Parse(pat)
		if err != nil {
			t.Fatalf("generator produced invalid pattern %q: %v", pat, err)
		}
		re, err := Compile(pat)
		if err != nil {
			t.Fatalf("Compile(%q): %v", pat, err)
		}
		for j := 0; j < 8; j++ {
			s := genSubject(rng)
			want := refFind(root, groups, s)
			if got := format(re.Find(s)); got != want {
				t.Fatalf("pattern %q subject %q: got %s, want %s", pat, s, got, want)
			}
		}
	}
}
