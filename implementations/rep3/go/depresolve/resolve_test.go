package depresolve

import (
	"errors"
	"fmt"
	"math/rand"
	"sort"
	"strings"
	"testing"
)

func solve(t *testing.T, in string) string {
	t.Helper()
	p, err := Parse(in)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	res, err := p.Resolve()
	if errors.Is(err, ErrUnsatisfiable) {
		return "unsatisfiable"
	}
	if err != nil {
		t.Fatalf("Resolve: %v", err)
	}
	return strings.TrimSuffix(res.String(), "\n")
}

func TestSpecExamples(t *testing.T) {
	tests := []struct{ name, in, want string }{
		{"diamond", "a 1.0.0: c ^1.0.0\nb 1.0.0: c ~1.2.0\nc 1.1.0:\nc 1.2.5:\nc 1.3.0:\nroot: a *, b *\n",
			"a 1.0.0\nb 1.0.0\nc 1.2.5"},
		{"first not newest", "a 2.0.0: b ~1.0.0\na 1.0.0:\nb 1.0.0:\nb 1.0.5:\nb 1.5.0:\nb 2.0.0:\nroot: a *, b *\n",
			"a 2.0.0\nb 1.0.5"},
		{"conflict", "a 1.0.0: c ^1.0.0\nb 1.0.0: c ^2.0.0\nc 1.0.0:\nc 2.0.0:\nroot: a *, b *\n",
			"unsatisfiable"},
		{"order ab", "a 2.0.0: c ^2.0.0\na 1.0.0: c ^1.0.0\nb 2.0.0: c ^1.0.0\nb 1.0.0: c ^2.0.0\nc 1.0.0:\nc 2.0.0:\nroot: a *, b *\n",
			"a 2.0.0\nb 1.0.0\nc 2.0.0"},
		{"order ba", "a 2.0.0: c ^2.0.0\na 1.0.0: c ^1.0.0\nb 2.0.0: c ^1.0.0\nb 1.0.0: c ^2.0.0\nc 1.0.0:\nc 2.0.0:\nroot: b *, a *\n",
			"a 1.0.0\nb 2.0.0\nc 1.0.0"},
	}
	for _, tc := range tests {
		if got := solve(t, tc.in); got != tc.want {
			t.Errorf("%s: got %q; want %q", tc.name, got, tc.want)
		}
	}
}

func TestEdgeCases(t *testing.T) {
	tests := []struct{ name, in, want string }{
		{"empty root", "root:\n", ""},
		{"empty registry unsat", "root: a *\n", "unsatisfiable"},
		{"missing dependency", "a 1.0.0: ghost *\nroot: a *\n", "unsatisfiable"},
		{"empty range", "a 1.0.0:\nroot: a >=2.0.0 <1.0.0\n", "unsatisfiable"},
		{"numeric order", "a 1.9.0:\na 1.10.0:\na 1.2.0:\nroot: a *\n", "a 1.10.0"},
		{"cycle", "a 1.0.0: b *\nb 1.0.0: a *\nroot: a *\n", "a 1.0.0\nb 1.0.0"},
		{"self requirement", "a 2.0.0: a ^1.0.0\na 1.0.0: a 1.0.0\nroot: a *\n", "a 1.0.0"},
		{"unreached versions ignored", "a 1.0.0:\nb 1.0.0: ghost *\nroot: a *\n", "a 1.0.0"},
		{"name sort", "mylib 1.0.0:\nmy-lib2 1.0.0:\nmy-lib 1.0.0:\nroot: mylib *, my-lib2 *, my-lib *\n",
			"my-lib 1.0.0\nmy-lib2 1.0.0\nmylib 1.0.0"},
		{"chronological backtracking", // z is retried although unrelated to the failure
			"z 2.0.0:\nz 1.0.0:\na 1.0.0: q ^1.0.0\nq 1.0.0:\nq 2.0.0:\nroot: z *, a *, q ^2.0.0\n", "unsatisfiable"},
		{"backtrack into unrelated", "x 2.0.0: y 1.0.0\nx 1.0.0: y 2.0.0\ny 1.0.0:\ny 2.0.0:\nroot: x *, y 2.0.0\n",
			"x 1.0.0\ny 2.0.0"},
	}
	for _, tc := range tests {
		if got := solve(t, tc.in); got != tc.want {
			t.Errorf("%s: got %q; want %q", tc.name, got, tc.want)
		}
	}
}

func TestBuilderAPI(t *testing.T) {
	var b Builder
	b.AddVersion("web", Version{1, 0, 0}, Requirement{"log", Caret(Version{1, 0, 0})})
	b.AddVersion("log", Version{1, 2, 0})
	b.AddVersion("log", Version{2, 0, 0})
	b.SetRoot(Requirement{"web", AnyVersion})
	p, err := b.Build()
	if err != nil {
		t.Fatal(err)
	}
	res, err := p.Resolve()
	if err != nil {
		t.Fatal(err)
	}
	if v, ok := res.Lookup("log"); !ok || v != (Version{1, 2, 0}) {
		t.Errorf("log = %v, %v", v, ok)
	}
	if _, ok := res.Lookup("nope"); ok {
		t.Error("Lookup of absent package succeeded")
	}
	// Resolve is repeatable and the builder is reusable.
	res2, _ := p.Resolve()
	if res.String() != res2.String() {
		t.Error("Resolve not repeatable")
	}
	b.SetRoot()
	p2, _ := b.Build()
	if r, err := p2.Resolve(); err != nil || len(r) != 0 {
		t.Errorf("empty root: %v, %v", r, err)
	}
}

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
	// p-names are not valid for digits-first only; "p0" is fine.
	p, err := Parse(sb.String())
	if err != nil {
		t.Fatal(err)
	}
	res, err := p.Resolve()
	if err != nil || len(res) != n {
		t.Fatalf("len=%d err=%v", len(res), err)
	}
	if !sort.SliceIsSorted(res, func(i, j int) bool { return res[i].Package < res[j].Package }) {
		t.Error("result not sorted")
	}
}

func TestManyVersionsStepDown(t *testing.T) {
	var sb strings.Builder
	for i := 0; i < 1600; i++ {
		fmt.Fprintf(&sb, "a %d.0.0:\n", i)
	}
	sb.WriteString("root: a *, a <1.0.0\n")
	if got := solve(t, sb.String()); got != "a 0.0.0" {
		t.Errorf("got %q", got)
	}
}

// naive is a direct transcription of the specification's recursive pseudocode.
type naiveReq struct {
	name string
	rng  Range
}

type naiveReg map[string]map[Version][]naiveReq

func naiveResolve(reg naiveReg, pending []naiveReq, chosen map[string]Version) (map[string]Version, bool) {
	if len(pending) == 0 {
		return chosen, true
	}
	r, rest := pending[0], pending[1:]
	if v, ok := chosen[r.name]; ok {
		if r.rng.Contains(v) {
			return naiveResolve(reg, rest, chosen)
		}
		return nil, false
	}
	var cands []Version
	for v := range reg[r.name] {
		if r.rng.Contains(v) {
			cands = append(cands, v)
		}
	}
	sort.Slice(cands, func(i, j int) bool { return cands[j].Less(cands[i]) })
	for _, v := range cands {
		next := make(map[string]Version, len(chosen)+1)
		for k, x := range chosen {
			next[k] = x
		}
		next[r.name] = v
		np := append(append([]naiveReq{}, reg[r.name][v]...), rest...)
		if res, ok := naiveResolve(reg, np, next); ok {
			return res, true
		}
	}
	return nil, false
}

func TestAgainstNaive(t *testing.T) {
	rng := rand.New(rand.NewSource(1))
	ranges := []string{"*", "^%d.%d.0", "~%d.%d.0", "%d.%d.0", ">=%d.0.0 <%d.5.0", ">%d.%d.0", "<=%d.%d.0", "^0.0.%d"}
	sat := 0
	for iter := 0; iter < 3000; iter++ {
		np := 2 + rng.Intn(6)
		name := func(i int) string { return fmt.Sprintf("p%d", i) }
		randReqs := func(max int) ([]naiveReq, string) {
			var rs []naiveReq
			var txt []string
			for _, i := range rng.Perm(np)[:min(np, rng.Intn(max+1))] {
				f := ranges[rng.Intn(len(ranges))]
				s := f
				if strings.Count(f, "%d") == 2 {
					s = fmt.Sprintf(f, rng.Intn(3), rng.Intn(3))
				} else if strings.Count(f, "%d") == 1 {
					s = fmt.Sprintf(f, rng.Intn(3))
				}
				rg, err := ParseRange(s)
				if err != nil {
					t.Fatal(err)
				}
				rs = append(rs, naiveReq{name(i), rg})
				txt = append(txt, name(i)+" "+s)
			}
			if len(txt) == 0 {
				return rs, ""
			}
			return rs, " " + strings.Join(txt, ", ")
		}
		reg := naiveReg{}
		var sb strings.Builder
		for i := 0; i < np; i++ {
			reg[name(i)] = map[Version][]naiveReq{}
			for k := rng.Intn(5); k > 0; k-- {
				v := Version{uint32(rng.Intn(3)), uint32(rng.Intn(3)), uint32(rng.Intn(3))}
				if _, dup := reg[name(i)][v]; dup {
					continue
				}
				rs, txt := randReqs(3)
				reg[name(i)][v] = rs
				fmt.Fprintf(&sb, "%s %s:%s\n", name(i), v, txt)
			}
		}
		rootReqs, rtxt := randReqs(4)
		fmt.Fprintf(&sb, "root:%s\n", rtxt)

		want := "unsatisfiable"
		if res, ok := naiveResolve(reg, rootReqs, map[string]Version{}); ok {
			sat++
			var lines []string
			for n, v := range res {
				lines = append(lines, n+" "+v.String())
			}
			sort.Strings(lines)
			want = strings.Join(lines, "\n")
		}
		if got := solve(t, sb.String()); got != want {
			t.Fatalf("mismatch on\n%s\ngot  %q\nwant %q", sb.String(), got, want)
		}
	}
	if sat < 300 || sat > 2700 {
		t.Errorf("random test is degenerate: %d/3000 satisfiable", sat)
	}
}

func BenchmarkBacktracking(b *testing.B) {
	var sb strings.Builder
	for i := 0; i < 12; i++ {
		for v := 1; v <= 6; v++ {
			fmt.Fprintf(&sb, "p%d %d.0.0:\n", i, v)
		}
	}
	sb.WriteString("root: ")
	for i := 0; i < 12; i++ {
		fmt.Fprintf(&sb, "p%d *, ", i)
	}
	sb.WriteString("p0 1.0.0\n")
	in := sb.String()
	p, err := Parse(in)
	if err != nil {
		b.Fatal(err)
	}
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		p.Resolve()
	}
}
