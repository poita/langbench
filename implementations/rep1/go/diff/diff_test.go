package linediff

import (
	"bytes"
	"math/rand"
	"strings"
	"testing"
)

func lcs(a, b []int32) int {
	prev := make([]int, len(b)+1)
	cur := make([]int, len(b)+1)
	for i := 1; i <= len(a); i++ {
		for j := 1; j <= len(b); j++ {
			switch {
			case a[i-1] == b[j-1]:
				cur[j] = prev[j-1] + 1
			case prev[j] >= cur[j-1]:
				cur[j] = prev[j]
			default:
				cur[j] = cur[j-1]
			}
		}
		prev, cur = cur, prev
	}
	return prev[len(b)]
}

// checkOps verifies that ops is a valid script for a and b and has the
// minimum cost.
func checkOps(t *testing.T, a, b []int32, ops []Op) {
	t.Helper()
	var ra, rb []int32
	for _, op := range ops {
		switch op.Tag {
		case Keep:
			ra = append(ra, a[op.Index])
			rb = append(rb, a[op.Index])
		case Delete:
			ra = append(ra, a[op.Index])
		case Insert:
			rb = append(rb, b[op.Index])
		default:
			t.Fatalf("bad tag %q", op.Tag)
		}
	}
	if !equalIDs(ra, a) || !equalIDs(rb, b) {
		t.Fatalf("script does not reproduce inputs\na=%v b=%v ops=%v", a, b, ops)
	}
	// Keep indices must pair equal elements: check by walking both.
	i, j := 0, 0
	for _, op := range ops {
		switch op.Tag {
		case Keep:
			if int(op.Index) != i || a[i] != b[j] {
				t.Fatalf("keep out of step: %v", op)
			}
			i++
			j++
		case Delete:
			if int(op.Index) != i {
				t.Fatalf("delete out of step: %v", op)
			}
			i++
		case Insert:
			if int(op.Index) != j {
				t.Fatalf("insert out of step: %v", op)
			}
			j++
		}
	}
	if want := len(a) + len(b) - 2*lcs(a, b); Cost(ops) != want {
		t.Fatalf("cost %d, want %d\na=%v\nb=%v\nops=%v", Cost(ops), want, a, b, ops)
	}
}

func equalIDs(x, y []int32) bool {
	if len(x) != len(y) {
		return false
	}
	for i := range x {
		if x[i] != y[i] {
			return false
		}
	}
	return true
}

func TestDiffIDsExhaustiveSmall(t *testing.T) {
	// Every pair of sequences over {0,1,2} with length <= 5 (or {0,1} to 7).
	gen := func(alpha, maxLen int) [][]int32 {
		out := [][]int32{{}}
		for l := 1; l <= maxLen; l++ {
			total := 1
			for i := 0; i < l; i++ {
				total *= alpha
			}
			for v := 0; v < total; v++ {
				s := make([]int32, l)
				x := v
				for i := range s {
					s[i] = int32(x % alpha)
					x /= alpha
				}
				out = append(out, s)
			}
		}
		return out
	}
	for _, c := range []struct{ alpha, maxLen int }{{3, 5}, {2, 7}} {
		seqs := gen(c.alpha, c.maxLen)
		for _, a := range seqs {
			for _, b := range seqs {
				checkOps(t, a, b, DiffIDs(a, b))
			}
		}
	}
}

func TestDiffIDsRandom(t *testing.T) {
	rng := rand.New(rand.NewSource(1))
	for iter := 0; iter < 3000; iter++ {
		alpha := 1 + rng.Intn(8)
		a := make([]int32, rng.Intn(60))
		b := make([]int32, rng.Intn(60))
		for i := range a {
			a[i] = int32(rng.Intn(alpha))
		}
		if rng.Intn(2) == 0 {
			// b is a mutated copy of a.
			b = append(b[:0], a...)
			for e := rng.Intn(10); e > 0 && len(b) > 0; e-- {
				p := rng.Intn(len(b))
				switch rng.Intn(3) {
				case 0:
					b[p] = int32(rng.Intn(alpha))
				case 1:
					b = append(b[:p], b[p+1:]...)
				default:
					b = append(b[:p], append([]int32{int32(rng.Intn(alpha))}, b[p:]...)...)
				}
			}
		} else {
			for i := range b {
				b[i] = int32(rng.Intn(alpha))
			}
		}
		checkOps(t, a, b, DiffIDs(a, b))
	}
}

func TestDiffDisjointWorstCase(t *testing.T) {
	a := make([]int32, 1500)
	b := make([]int32, 1500)
	for i := range a {
		a[i] = int32(i)
		b[i] = int32(i + 1500)
	}
	ops := DiffIDs(a, b)
	if Cost(ops) != 3000 || len(ops) != 3000 {
		t.Fatalf("cost %d, ops %d", Cost(ops), len(ops))
	}
}

func lines(s string) [][]byte {
	if s == "" {
		return nil
	}
	return SplitLines([]byte(s))
}

func TestDiffMyersPaperExample(t *testing.T) {
	a := lines("a\nb\nc\na\nb\nb\na\n")
	b := lines("c\nb\na\nb\na\nc\n")
	ops := Diff(a, b)
	if Cost(ops) != 5 {
		t.Fatalf("cost %d, want 5: %v", Cost(ops), ops)
	}
	got := string(AppendScript(nil, a, b, ops))
	if !strings.HasPrefix(got, "9\n") {
		t.Fatalf("script %q", got)
	}
}

func TestDiffIdenticalAndEmpty(t *testing.T) {
	a := lines("x\n\n y \n")
	ops := Diff(a, a)
	if len(ops) != 3 || Cost(ops) != 0 {
		t.Fatalf("identical: %v", ops)
	}
	if ops := Diff(nil, nil); len(ops) != 0 {
		t.Fatalf("empty: %v", ops)
	}
	if ops := Diff(nil, a); Cost(ops) != 3 {
		t.Fatalf("empty->a: %v", ops)
	}
	if ops := Diff(a, nil); Cost(ops) != 3 {
		t.Fatalf("a->empty: %v", ops)
	}
}

func TestDiffWhitespaceSignificant(t *testing.T) {
	a := lines("trailing \ntrailing\n both \n")
	b := lines("trailing\ntrailing \n both\n")
	ops := Diff(a, b)
	if Cost(ops) != 4 { // keeps only one "trailing"/"trailing " pair
		t.Fatalf("cost %d: %v", Cost(ops), ops)
	}
}

func TestDiffStrings(t *testing.T) {
	ops := DiffStrings([]string{"a", "b", "c"}, []string{"a", "c", "d"})
	if Cost(ops) != 2 {
		t.Fatalf("cost %d", Cost(ops))
	}
}

func TestIntern(t *testing.T) {
	ia, ib, n := Intern(lines("a\nb\na\n"), lines("b\nc\n"))
	if n != 3 || !equalIDs(ia, []int32{0, 1, 0}) || !equalIDs(ib, []int32{1, 2}) {
		t.Fatalf("%v %v %d", ia, ib, n)
	}
}

func TestSplitLines(t *testing.T) {
	cases := map[string]int{"": 0, "\n": 1, "a": 1, "a\n": 1, "a\n\nb\n": 3, "a\nb": 2}
	for in, want := range cases {
		if got := SplitLines([]byte(in)); len(got) != want {
			t.Errorf("SplitLines(%q) = %d lines, want %d", in, len(got), want)
		}
	}
}

func TestScriptRoundTrip(t *testing.T) {
	a := lines("1\n2\n+3\n-4\n \n")
	b := lines("2\n+3\nnew\n \n")
	ops := Diff(a, b)
	text := AppendScript(nil, a, b, ops)
	all := SplitLines(text)
	script, err := ParseScript(all[1:])
	if err != nil {
		t.Fatal(err)
	}
	out, err := Apply(a, script)
	if err != nil {
		t.Fatal(err)
	}
	if len(out) != len(b) {
		t.Fatalf("got %d lines, want %d", len(out), len(b))
	}
	for i := range b {
		if !bytes.Equal(out[i], b[i]) {
			t.Fatalf("line %d: %q != %q", i, out[i], b[i])
		}
	}
}

func TestParseScriptErrors(t *testing.T) {
	if _, err := ParseScript([][]byte{[]byte("")}); err != ErrBadTag {
		t.Errorf("empty line: %v", err)
	}
	if _, err := ParseScript([][]byte{[]byte("x foo")}); err != ErrBadTag {
		t.Errorf("bad tag: %v", err)
	}
	e, err := ParseScript([][]byte{[]byte("+-x"), []byte("  "), []byte("+")})
	if err != nil || e[0].Tag != Insert || string(e[0].Text) != "-x" ||
		e[1].Tag != Keep || string(e[1].Text) != " " || len(e[2].Text) != 0 {
		t.Errorf("parse: %v %v", e, err)
	}
}
