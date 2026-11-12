package resolve_test

import (
	"errors"
	"fmt"
	"math/rand"
	"sort"
	"strings"
	"testing"

	"depresolve/registry"
	"depresolve/resolve"
	"depresolve/semver"
)

func solve(t *testing.T, src string) (string, error) {
	t.Helper()
	in, err := registry.Parse(strings.NewReader(src))
	if err != nil {
		t.Fatal(err)
	}
	res, err := resolve.Resolve(in.Registry, in.Root)
	return format(res), err
}

func format(res resolve.Resolution) string {
	var sb strings.Builder
	for _, p := range res {
		fmt.Fprintf(&sb, "%s %s\n", p.Package, p.Version)
	}
	return sb.String()
}

func TestSpecExamples(t *testing.T) {
	tests := []struct {
		name, in, want string
		unsat          bool
	}{
		{"diamond backtracking", "a 1.0.0: c ^1.0.0\nb 1.0.0: c ~1.2.0\nc 1.1.0:\nc 1.2.5:\nc 1.3.0:\nroot: a *, b *\n",
			"a 1.0.0\nb 1.0.0\nc 1.2.5\n", false},
		{"first solution not newest set", "a 2.0.0: b ~1.0.0\na 1.0.0:\nb 1.0.0:\nb 1.0.5:\nb 1.5.0:\nb 2.0.0:\nroot: a *, b *\n",
			"a 2.0.0\nb 1.0.5\n", false},
		{"conflicting majors", "a 1.0.0: c ^1.0.0\nb 1.0.0: c ^2.0.0\nc 1.0.0:\nc 2.0.0:\nroot: a *, b *\n", "", true},
		{"order a b", "a 2.0.0: c ^2.0.0\na 1.0.0: c ^1.0.0\nb 2.0.0: c ^1.0.0\nb 1.0.0: c ^2.0.0\nc 1.0.0:\nc 2.0.0:\nroot: a *, b *\n",
			"a 2.0.0\nb 1.0.0\nc 2.0.0\n", false},
		{"order b a", "a 2.0.0: c ^2.0.0\na 1.0.0: c ^1.0.0\nb 2.0.0: c ^1.0.0\nb 1.0.0: c ^2.0.0\nc 1.0.0:\nc 2.0.0:\nroot: b *, a *\n",
			"a 1.0.0\nb 2.0.0\nc 1.0.0\n", false},
		{"empty root", "root:\n", "", false},
		{"missing package", "root: ghost *\n", "", true},
		{"empty range", "a 1.0.0:\nroot: a >=2.0.0 <1.0.0\n", "", true},
		{"self cycle", "a 2.0.0: a ^2.0.0\na 1.0.0: a ^1.0.0\nroot: a *\n", "a 2.0.0\n", false},
		{"self conflict backtracks", "a 2.0.0: a ^1.0.0\na 1.0.0:\nroot: a *\n", "a 1.0.0\n", false},
		{"cycle", "a 1.0.0: b *\nb 1.0.0: a *\nroot: a *\n", "a 1.0.0\nb 1.0.0\n", false},
		{"sorted by bytes", "mylib 1.0.0:\nmy-lib2 1.0.0:\nmy-lib 1.0.0:\nroot: mylib *, my-lib2 *, my-lib *\n",
			"my-lib 1.0.0\nmy-lib2 1.0.0\nmylib 1.0.0\n", false},
		{"unchosen requirements ignored", "a 2.0.0: ghost *\na 1.0.0:\nroot: a *\n", "a 1.0.0\n", false},
	}
	for _, tc := range tests {
		got, err := solve(t, tc.in)
		if tc.unsat {
			if !errors.Is(err, resolve.ErrUnsatisfiable) {
				t.Errorf("%s: got %q, %v; want ErrUnsatisfiable", tc.name, got, err)
			}
			continue
		}
		if err != nil || got != tc.want {
			t.Errorf("%s: got %q, %v; want %q", tc.name, got, err, tc.want)
		}
	}
}

// A chain 3000 packages deep exercises the explicit stack: a recursive
// implementation would need a very deep call stack.
func TestDeepChain(t *testing.T) {
	const n = 3000
	var sb strings.Builder
	for i := 0; i < n; i++ {
		if i+1 < n {
			fmt.Fprintf(&sb, "p%d 1.0.0: p%d *\n", i, i+1)
		} else {
			fmt.Fprintf(&sb, "p%d 1.0.0:\n", i)
		}
	}
	sb.WriteString("root: p0 *\n")
	got, err := solve(t, sb.String())
	if err != nil || strings.Count(got, "\n") != n {
		t.Fatalf("chain: %d lines, err %v", strings.Count(got, "\n"), err)
	}
}

// ---- reference implementation: SPEC.md's pseudocode, transcribed literally ----

type refSolver struct{ in *registry.Input }

func (s refSolver) resolve(pending []registry.Requirement, chosen map[string]semver.Version) (map[string]semver.Version, bool) {
	if len(pending) == 0 {
		return chosen, true
	}
	req, rest := pending[0], pending[1:]
	if v, ok := chosen[req.Package]; ok {
		if req.Range.Contains(v) {
			return s.resolve(rest, chosen)
		}
		return nil, false
	}
	for _, rel := range s.in.Registry.Releases(req.Package) { // newest first
		if !req.Range.Contains(rel.Version) {
			continue
		}
		next := make(map[string]semver.Version, len(chosen)+1)
		for k, v := range chosen {
			next[k] = v
		}
		next[req.Package] = rel.Version
		newPending := append(append([]registry.Requirement{}, rel.Requires...), rest...)
		if res, ok := s.resolve(newPending, next); ok {
			return res, true
		}
	}
	return nil, false
}

func randomInput(rng *rand.Rand) string {
	nPkg := 1 + rng.Intn(7)
	name := func(i int) string { return fmt.Sprintf("p%d", i) }
	ver := func() string { return fmt.Sprintf("%d.%d.%d", rng.Intn(3), rng.Intn(3), rng.Intn(3)) }
	rangeText := func() string {
		switch rng.Intn(7) {
		case 0:
			return "*"
		case 1:
			return ver()
		case 2:
			return "^" + ver()
		case 3:
			return "~" + ver()
		case 4:
			return ">=" + ver()
		case 5:
			return "<" + ver()
		default:
			return ">=" + ver() + " <=" + ver()
		}
	}
	reqs := func() string {
		perm := rng.Perm(nPkg + 1) // +1: sometimes a package with no versions
		k := rng.Intn(4)
		parts := make([]string, 0, k)
		for _, id := range perm[:k%len(perm)] {
			parts = append(parts, name(id)+" "+rangeText())
		}
		if len(parts) == 0 {
			return ""
		}
		return " " + strings.Join(parts, ", ")
	}
	var sb strings.Builder
	seen := map[string]bool{}
	for i := 0; i < nPkg; i++ {
		for j := rng.Intn(5); j > 0; j-- {
			v := ver()
			if seen[name(i)+v] {
				continue
			}
			seen[name(i)+v] = true
			fmt.Fprintf(&sb, "%s %s:%s\n", name(i), v, reqs())
		}
	}
	fmt.Fprintf(&sb, "root:%s\n", reqs())
	return sb.String()
}

func TestAgainstReference(t *testing.T) {
	rng := rand.New(rand.NewSource(1))
	unsat := 0
	for i := 0; i < 5000; i++ {
		src := randomInput(rng)
		in, err := registry.Parse(strings.NewReader(src))
		if err != nil {
			t.Fatalf("bad generated input: %v\n%s", err, src)
		}
		want, ok := refSolver{in}.resolve(in.Root, map[string]semver.Version{})
		got, err := resolve.Resolve(in.Registry, in.Root)
		if !ok {
			unsat++
			if !errors.Is(err, resolve.ErrUnsatisfiable) {
				t.Fatalf("expected unsatisfiable, got %q\n%s", format(got), src)
			}
			continue
		}
		var names []string
		for n := range want {
			names = append(names, n)
		}
		sort.Strings(names)
		var sb strings.Builder
		for _, n := range names {
			fmt.Fprintf(&sb, "%s %s\n", n, want[n])
		}
		if err != nil || format(got) != sb.String() {
			t.Fatalf("mismatch\nwant:\n%s\ngot:\n%s (err %v)\ninput:\n%s", sb.String(), format(got), err, src)
		}
	}
	if unsat == 0 || unsat == 5000 {
		t.Errorf("generator is degenerate: %d/5000 unsatisfiable", unsat)
	}
}

func BenchmarkBacktracking(b *testing.B) {
	// root needs x (30 versions) and then y which fits only the oldest x.
	var sb strings.Builder
	for i := 0; i < 30; i++ {
		fmt.Fprintf(&sb, "x 1.%d.0:\n", i)
	}
	sb.WriteString("y 1.0.0: x ~1.0.0\nroot: x *, y *\n")
	in, _ := registry.Parse(strings.NewReader(sb.String()))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if _, err := resolve.Resolve(in.Registry, in.Root); err != nil {
			b.Fatal(err)
		}
	}
}
