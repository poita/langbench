package depresolve

import (
	"errors"
	"fmt"
	"math/rand"
	"sort"
	"strings"
	"testing"
)

func solve(t *testing.T, input string) (string, error) {
	t.Helper()
	p, err := ParseBytes([]byte(input))
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	res, err := p.Resolve()
	return res.String(), err
}

func TestSpecExamples(t *testing.T) {
	tests := []struct{ name, in, want string }{
		{"diamond backtracking", "a 1.0.0: c ^1.0.0\nb 1.0.0: c ~1.2.0\nc 1.1.0:\nc 1.2.5:\nc 1.3.0:\nroot: a *, b *\n",
			"a 1.0.0\nb 1.0.0\nc 1.2.5\n"},
		{"first solution", "a 2.0.0: b ~1.0.0\na 1.0.0:\nb 1.0.0:\nb 1.0.5:\nb 1.5.0:\nb 2.0.0:\nroot: a *, b *\n",
			"a 2.0.0\nb 1.0.5\n"},
		{"conflicting majors", "a 1.0.0: c ^1.0.0\nb 1.0.0: c ^2.0.0\nc 1.0.0:\nc 2.0.0:\nroot: a *, b *\n", ""},
		{"order a b", "a 2.0.0: c ^2.0.0\na 1.0.0: c ^1.0.0\nb 2.0.0: c ^1.0.0\nb 1.0.0: c ^2.0.0\nc 1.0.0:\nc 2.0.0:\nroot: a *, b *\n",
			"a 2.0.0\nb 1.0.0\nc 2.0.0\n"},
		{"order b a", "a 2.0.0: c ^2.0.0\na 1.0.0: c ^1.0.0\nb 2.0.0: c ^1.0.0\nb 1.0.0: c ^2.0.0\nc 1.0.0:\nc 2.0.0:\nroot: b *, a *\n",
			"a 1.0.0\nb 2.0.0\nc 1.0.0\n"},
	}
	for _, tc := range tests {
		got, err := solve(t, tc.in)
		if tc.want == "" {
			if !errors.Is(err, ErrUnsatisfiable) {
				t.Errorf("%s: err = %v, want ErrUnsatisfiable", tc.name, err)
			}
			continue
		}
		if err != nil || got != tc.want {
			t.Errorf("%s: got %q, %v; want %q", tc.name, got, err, tc.want)
		}
	}
}

func TestEdgeCases(t *testing.T) {
	tests := []struct {
		name, in string
		want     string // "" means unsatisfiable
	}{
		{"unknown package", "root: ghost *\n", ""},
		{"unknown after known", "a 1.0.0:\nroot: a *, ghost 1.0.0\n", ""},
		{"empty range", "a 1.0.0:\nroot: a >=2.0.0 <1.0.0\n", ""},
		{"self requirement ok", "a 2.0.0: a ^2.0.0\nroot: a *\n", "a 2.0.0\n"},
		{"self requirement conflict falls back", "a 2.0.0: a ^1.0.0\na 1.0.0:\nroot: a *\n", "a 1.0.0\n"},
		{"cycle", "a 1.0.0: b *\nb 1.0.0: a *\nroot: a *\n", "a 1.0.0\nb 1.0.0\n"},
		{"numeric order", "a 1.9.0:\na 1.10.0:\nroot: a *\n", "a 1.10.0\n"},
		{"name order", "mylib 1.0.0:\nmy-lib2 1.0.0:\nmy-lib 1.0.0:\nroot: mylib *, my-lib2 *, my-lib *\n",
			"my-lib 1.0.0\nmy-lib2 1.0.0\nmylib 1.0.0\n"},
		{"unchosen versions ignored", "a 2.0.0: ghost *\na 1.0.0:\nroot: a *\n", "a 1.0.0\n"},
		{"max components", "a 1000000.1000000.1000000:\nroot: a ^1000000.0.0\n", "a 1000000.1000000.1000000\n"},
		{"exclusive bound at max", "a 1000000.1000000.1000000:\nroot: a ~1000000.1000000.0\n", "a 1000000.1000000.1000000\n"},
		{"unrelated backtrack", "x 2.0.0:\nx 1.0.0:\na 1.0.0: x ^1.0.0\nroot: x *, a *\n", "a 1.0.0\nx 1.0.0\n"},
	}
	for _, tc := range tests {
		got, err := solve(t, tc.in)
		if tc.want == "" {
			if !errors.Is(err, ErrUnsatisfiable) {
				t.Errorf("%s: got %q, %v; want unsatisfiable", tc.name, got, err)
			}
		} else if err != nil || got != tc.want {
			t.Errorf("%s: got %q, %v; want %q", tc.name, got, err, tc.want)
		}
	}
}

func TestResolutionGet(t *testing.T) {
	p, _ := ParseBytes([]byte("a 1.0.0:\nb 2.0.0:\nroot: b *, a *\n"))
	res, err := p.Resolve()
	if err != nil {
		t.Fatal(err)
	}
	if v, ok := res.Get("b"); !ok || v.String() != "2.0.0" {
		t.Errorf("Get(b) = %v, %v", v, ok)
	}
	if _, ok := res.Get("c"); ok {
		t.Error("Get(c) should be absent")
	}
}

func TestResolveRepeatable(t *testing.T) {
	p, _ := ParseBytes([]byte("a 1.0.0: b *\nb 1.0.0:\nb 2.0.0:\nroot: a *\n"))
	r1, _ := p.Resolve()
	r2, _ := p.Resolve()
	if r1.String() != r2.String() || r1.String() != "a 1.0.0\nb 2.0.0\n" {
		t.Errorf("%q vs %q", r1, r2)
	}
}

// TestDeepChain checks that a very deep chain neither overflows the stack nor
// is slow, including a tail that forces a retry from the root.
func TestDeepChain(t *testing.T) {
	const n = 5000
	var b strings.Builder
	for i := 0; i < n; i++ {
		if i+1 < n {
			fmt.Fprintf(&b, "p%d 2.0.0: p%d *\n", i, i+1)
		} else {
			fmt.Fprintf(&b, "p%d 2.0.0: leaf ^2.0.0\n", i)
		}
		fmt.Fprintf(&b, "p%d 1.0.0: leaf ^1.0.0\n", i)
	}
	b.WriteString("leaf 1.0.0:\nroot: p0 *\n")
	// p0 2.0.0 ... p4999 2.0.0 all fail at leaf; the search unwinds to a
	// version of p4999 that works: p4999 1.0.0.
	got, err := solve(t, b.String())
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(got, "leaf 1.0.0\n") || !strings.Contains(got, "p4999 1.0.0\n") || !strings.Contains(got, "p0 2.0.0\n") {
		t.Errorf("unexpected resolution head: %.200q", got)
	}
}

// reference is a direct transcription of the recursive pseudocode in the
// specification, used to cross-check the optimised iterative search.
func reference(reg map[string]map[Version][]Requirement, pending []Requirement, chosen map[string]Version) (map[string]Version, bool) {
	if len(pending) == 0 {
		return chosen, true
	}
	q, rest := pending[0], pending[1:]
	if v, ok := chosen[q.Name]; ok {
		if q.Range.Contains(v) {
			return reference(reg, rest, chosen)
		}
		return nil, false
	}
	var cands []Version
	for v := range reg[q.Name] {
		if q.Range.Contains(v) {
			cands = append(cands, v)
		}
	}
	sort.Slice(cands, func(i, j int) bool { return cands[i].Compare(cands[j]) > 0 })
	for _, v := range cands {
		next := make(map[string]Version, len(chosen)+1)
		for k, x := range chosen {
			next[k] = x
		}
		next[q.Name] = v
		np := append(append([]Requirement{}, reg[q.Name][v]...), rest...)
		if res, ok := reference(reg, np, next); ok {
			return res, true
		}
	}
	return nil, false
}

func TestAgainstReference(t *testing.T) {
	rng := rand.New(rand.NewSource(1))
	names := []string{"a", "b", "c", "d", "e", "f", "ghost"}
	ranges := []string{"*", "^1.0.0", "^0.1.0", "^0.0.2", "~1.1.0", "~0.0.1", "1.0.0", "2.1.0", ">=1.0.0 <2.0.0", ">0.1.0", "<=1.1.0", "<1.0.0", ">=2.0.0 <1.0.0"}
	randVersion := func() Version {
		return Version{uint32(rng.Intn(3)), uint32(rng.Intn(3)), uint32(rng.Intn(3))}
	}
	randReqs := func() []Requirement {
		n := rng.Intn(4)
		var out []Requirement
		for _, i := range rng.Perm(len(names))[:n] {
			out = append(out, Requirement{names[i], MustParseRange(ranges[rng.Intn(len(ranges))])})
		}
		return out
	}
	unsat, sat := 0, 0
	for iter := 0; iter < 3000; iter++ {
		reg := map[string]map[Version][]Requirement{}
		r := NewRegistry()
		for i := rng.Intn(30); i > 0; i-- {
			name, v := names[rng.Intn(len(names)-1)], randVersion()
			if _, dup := reg[name][v]; dup {
				continue
			}
			if reg[name] == nil {
				reg[name] = map[Version][]Requirement{}
			}
			reqs := randReqs()
			reg[name][v] = reqs
			if err := r.Add(name, v, reqs); err != nil {
				t.Fatal(err)
			}
		}
		root := randReqs()
		want, ok := reference(reg, root, map[string]Version{})
		got, err := r.Resolve(root)
		if !ok {
			unsat++
			if !errors.Is(err, ErrUnsatisfiable) {
				t.Fatalf("iter %d: got %v, %v; want unsatisfiable", iter, got, err)
			}
			continue
		}
		sat++
		if err != nil || len(got) != len(want) {
			t.Fatalf("iter %d: got %v, %v; want %v", iter, got, err, want)
		}
		for _, p := range got {
			if want[p.Name] != p.Version {
				t.Fatalf("iter %d: %s = %s, want %s", iter, p.Name, p.Version, want[p.Name])
			}
		}
		if !sort.SliceIsSorted(got, func(i, j int) bool { return got[i].Name < got[j].Name }) {
			t.Fatalf("iter %d: unsorted %v", iter, got)
		}
	}
	if sat < 200 || unsat < 200 {
		t.Errorf("weak coverage: %d satisfiable, %d unsatisfiable", sat, unsat)
	}
}

func TestRegistryDuplicate(t *testing.T) {
	r := NewRegistry()
	if err := r.Add("a", Version{1, 0, 0}, nil); err != nil {
		t.Fatal(err)
	}
	if err := r.Add("a", Version{1, 0, 0}, nil); err == nil {
		t.Error("expected duplicate error")
	}
}
