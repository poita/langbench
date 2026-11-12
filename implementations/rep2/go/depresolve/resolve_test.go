package depresolve

import (
	"errors"
	"fmt"
	"math/rand"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

func resolveText(t *testing.T, in string) (string, error) {
	t.Helper()
	reg, root, err := ParseString(in)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	sol, err := reg.Resolve(root)
	if err != nil {
		return "", err
	}
	var sb strings.Builder
	for _, p := range sol {
		fmt.Fprintf(&sb, "%s %s\n", p.Name, p.Version)
	}
	return sb.String(), nil
}

func TestSpecExamples(t *testing.T) {
	cases := []struct {
		name, in, want string
		unsat          bool
	}{
		{"diamond", "a 1.0.0: c ^1.0.0\nb 1.0.0: c ~1.2.0\nc 1.1.0:\nc 1.2.5:\nc 1.3.0:\nroot: a *, b *\n",
			"a 1.0.0\nb 1.0.0\nc 1.2.5\n", false},
		{"first solution", "a 2.0.0: b ~1.0.0\na 1.0.0:\nb 1.0.0:\nb 1.0.5:\nb 1.5.0:\nb 2.0.0:\nroot: a *, b *\n",
			"a 2.0.0\nb 1.0.5\n", false},
		{"conflict", "a 1.0.0: c ^1.0.0\nb 1.0.0: c ^2.0.0\nc 1.0.0:\nc 2.0.0:\nroot: a *, b *\n", "", true},
		{"order ab", "a 2.0.0: c ^2.0.0\na 1.0.0: c ^1.0.0\nb 2.0.0: c ^1.0.0\nb 1.0.0: c ^2.0.0\nc 1.0.0:\nc 2.0.0:\nroot: a *, b *\n",
			"a 2.0.0\nb 1.0.0\nc 2.0.0\n", false},
		{"order ba", "a 2.0.0: c ^2.0.0\na 1.0.0: c ^1.0.0\nb 2.0.0: c ^1.0.0\nb 1.0.0: c ^2.0.0\nc 1.0.0:\nc 2.0.0:\nroot: b *, a *\n",
			"a 1.0.0\nb 2.0.0\nc 1.0.0\n", false},
		{"empty root", "root:\n", "", false},
		{"missing package", "root: ghost *\n", "", true},
		{"self cycle", "a 1.0.0: a 1.0.0\nroot: a *\n", "a 1.0.0\n", false},
		{"cycle", "a 1.0.0: b *\nb 1.0.0: a *\nroot: a *\n", "a 1.0.0\nb 1.0.0\n", false},
		{"numeric order", "a 1.9.0:\na 1.10.0:\nroot: a *\n", "a 1.10.0\n", false},
		{"name order", "mylib 1.0.0:\nmy-lib2 1.0.0:\nmy-lib 1.0.0:\nroot: mylib *, my-lib2 *, my-lib *\n",
			"my-lib 1.0.0\nmy-lib2 1.0.0\nmylib 1.0.0\n", false},
		{"unchosen deps ignored", "a 2.0.0: ghost *\na 1.0.0:\nroot: a *\n", "a 1.0.0\n", false},
		{"empty range", "a 1.0.0:\nroot: a >=2.0.0 <1.0.0\n", "", true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, err := resolveText(t, c.in)
			if c.unsat {
				if !errors.Is(err, ErrUnsatisfiable) {
					t.Fatalf("got %q, %v; want ErrUnsatisfiable", got, err)
				}
				return
			}
			if err != nil || got != c.want {
				t.Fatalf("got %q, %v; want %q", got, err, c.want)
			}
		})
	}
}

func TestLookup(t *testing.T) {
	got, err := resolveText(t, "a 1.0.0:\nb 2.0.0:\nroot: a *, b *\n")
	if err != nil || got != "a 1.0.0\nb 2.0.0\n" {
		t.Fatal(got, err)
	}
	reg, root, _ := ParseString("a 1.0.0:\nb 2.0.0:\nroot: a *, b *\n")
	sol, _ := reg.Resolve(root)
	if v, ok := sol.Lookup("b"); !ok || v != (Version{2, 0, 0}) {
		t.Errorf("Lookup(b) = %v, %v", v, ok)
	}
	if _, ok := sol.Lookup("c"); ok {
		t.Error("Lookup(c) found a package")
	}
}

func TestAPIBuilding(t *testing.T) {
	reg := NewRegistry()
	if err := reg.Add("a", MustParseVersion("1.0.0"), MustParseRequirements("c ^1.0.0")); err != nil {
		t.Fatal(err)
	}
	if err := reg.Add("a", MustParseVersion("1.0.0"), nil); err == nil {
		t.Error("duplicate Add succeeded")
	}
	reg.Add("c", MustParseVersion("1.2.0"), nil)
	reg.Add("c", MustParseVersion("2.0.0"), nil)
	sol, err := reg.Resolve(MustParseRequirements("a *"))
	if err != nil || len(sol) != 2 || sol[1] != (Package{"c", Version{1, 2, 0}}) {
		t.Fatalf("got %v, %v", sol, err)
	}
	// Resolve is repeatable and does not modify the registry.
	sol2, _ := reg.Resolve(MustParseRequirements("a *"))
	if fmt.Sprint(sol) != fmt.Sprint(sol2) {
		t.Error("second Resolve differs")
	}
}

func TestParseErrors(t *testing.T) {
	for _, in := range []string{
		"", "a 1.0.0:\n", "root:", "root: a\n", "a 1.0.0 root:\n", "A 1.0.0:\nroot:\n",
		"a 1.0.0:\nroot:\na 2.0.0:\n", "a 1.0.0:\na 1.0.0:\nroot:\n", "a 1.0:\nroot:\n",
		"a 1.0.0: b\nroot:\n", "nocolon\nroot:\n",
	} {
		if _, _, err := ParseString(in); err == nil {
			t.Errorf("ParseString(%q) succeeded; want error", in)
		}
	}
}

// TestDeepChain checks that very long dependency paths do not exhaust the
// call stack (the search is iterative).
func TestDeepChain(t *testing.T) {
	var sb strings.Builder
	const n = 20000
	for i := 0; i < n; i++ {
		fmt.Fprintf(&sb, "p%s 1.0.0: p%s *\n", name(i), name(i+1))
	}
	fmt.Fprintf(&sb, "p%s 1.0.0:\nroot: p%s *\n", name(n), name(0))
	got, err := resolveText(t, sb.String())
	if err != nil || strings.Count(got, "\n") != n+1 {
		t.Fatalf("err=%v lines=%d", err, strings.Count(got, "\n"))
	}
}

func name(i int) string {
	s := ""
	for {
		s = string(rune('a'+i%26)) + s
		i /= 26
		if i == 0 {
			return s
		}
	}
}

// naive is a direct transcription of the specification's recursive search,
// used as an oracle.
func naive(reg *Registry, pending []Requirement, chosen map[string]Version) (map[string]Version, bool) {
	if len(pending) == 0 {
		return chosen, true
	}
	req, rest := pending[0], pending[1:]
	if v, ok := chosen[req.Name]; ok {
		if req.Range.Contains(v) {
			return naive(reg, rest, chosen)
		}
		return nil, false
	}
	var cands []packageVersion
	if id, ok := reg.index[req.Name]; ok {
		for _, pv := range reg.versions[id] {
			if req.Range.Contains(pv.version) {
				cands = append(cands, pv)
			}
		}
	}
	sort.Slice(cands, func(i, j int) bool { return cands[j].version.Less(cands[i].version) })
	for _, pv := range cands {
		next := make(map[string]Version, len(chosen)+1)
		for k, v := range chosen {
			next[k] = v
		}
		next[req.Name] = pv.version
		p := append(append([]Requirement(nil), pv.reqs...), rest...)
		if res, ok := naive(reg, p, next); ok {
			return res, true
		}
	}
	return nil, false
}

func randomRange(rng *rand.Rand) string {
	v := func() string { return fmt.Sprintf("%d.%d.%d", rng.Intn(3), rng.Intn(3), rng.Intn(3)) }
	ops := []string{"<", "<=", ">", ">="}
	switch rng.Intn(7) {
	case 0:
		return "*"
	case 1:
		return v()
	case 2:
		return "^" + v()
	case 3:
		return "~" + v()
	case 4:
		return ops[rng.Intn(4)] + v()
	case 5:
		return ops[rng.Intn(4)] + v() + " " + ops[rng.Intn(4)] + v()
	}
	return ">=" + v() + " <" + v()
}

func randomReqs(rng *rand.Rand, npkg int) string {
	k := rng.Intn(4)
	seen := map[int]bool{}
	var parts []string
	for i := 0; i < k; i++ {
		p := rng.Intn(npkg + 1) // npkg is a package with no versions
		if seen[p] {
			continue
		}
		seen[p] = true
		parts = append(parts, fmt.Sprintf("p%d %s", p, randomRange(rng)))
	}
	if len(parts) == 0 {
		return ""
	}
	return " " + strings.Join(parts, ", ")
}

func TestRandomAgainstNaive(t *testing.T) {
	rng := rand.New(rand.NewSource(1))
	sat, unsat := 0, 0
	for iter := 0; iter < 1500; iter++ {
		npkg := 2 + rng.Intn(6)
		var sb strings.Builder
		seen := map[string]bool{}
		for p := 0; p < npkg; p++ {
			for n := rng.Intn(5); n > 0; n-- {
				ver := fmt.Sprintf("%d.%d.%d", rng.Intn(3), rng.Intn(3), rng.Intn(3))
				if seen[fmt.Sprint(p, ver)] {
					continue
				}
				seen[fmt.Sprint(p, ver)] = true
				fmt.Fprintf(&sb, "p%d %s:%s\n", p, ver, randomReqs(rng, npkg))
			}
		}
		fmt.Fprintf(&sb, "root:%s\n", randomReqs(rng, npkg))
		in := sb.String()
		reg, root, err := ParseString(in)
		if err != nil {
			t.Fatalf("parse %q: %v", in, err)
		}
		want, ok := naive(reg, root, map[string]Version{})
		got, err := reg.Resolve(root)
		if !ok {
			unsat++
			if !errors.Is(err, ErrUnsatisfiable) {
				t.Fatalf("input:\n%sgot %v, %v; want unsatisfiable", in, got, err)
			}
			continue
		}
		sat++
		if err != nil || len(got) != len(want) {
			t.Fatalf("input:\n%sgot %v, %v; want %v", in, got, err, want)
		}
		for _, p := range got {
			if want[p.Name] != p.Version {
				t.Fatalf("input:\n%sgot %v; want %v", in, got, want)
			}
		}
	}
	if sat < 100 || unsat < 100 {
		t.Errorf("weak coverage: %d satisfiable, %d unsatisfiable", sat, unsat)
	}
}

// TestSpecSuite runs every .in/.out pair in testdata (copies of
// representative cases) through the library.
func TestSpecSuite(t *testing.T) {
	files, _ := filepath.Glob("testdata/*.in")
	if len(files) == 0 {
		t.Skip("no testdata")
	}
	for _, f := range files {
		t.Run(filepath.Base(f), func(t *testing.T) {
			in, _ := os.ReadFile(f)
			want, _ := os.ReadFile(strings.TrimSuffix(f, ".in") + ".out")
			got, err := resolveText(t, string(in))
			if errors.Is(err, ErrUnsatisfiable) {
				got = "unsatisfiable\n"
			} else if err != nil {
				t.Fatal(err)
			}
			if strings.TrimSpace(got) != strings.TrimSpace(string(want)) {
				t.Errorf("got:\n%s\nwant:\n%s", got, want)
			}
		})
	}
}

func BenchmarkResolveBacktracking(b *testing.B) {
	// 12 independent packages with 4 versions each, then a conflict that
	// forces enumeration of many combinations before failure.
	var sb strings.Builder
	var roots []string
	for p := 0; p < 8; p++ {
		for v := 1; v <= 4; v++ {
			fmt.Fprintf(&sb, "p%d %d.0.0:\n", p, v)
		}
		roots = append(roots, fmt.Sprintf("p%d *", p))
	}
	sb.WriteString("z 1.0.0: p0 ^9.0.0\n")
	roots = append(roots, "z *")
	fmt.Fprintf(&sb, "root: %s\n", strings.Join(roots, ", "))
	reg, root, _ := ParseString(sb.String())
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		reg.Resolve(root)
	}
}
