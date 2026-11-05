package textbuffer

import (
	"math/rand"
	"strings"
	"testing"
)

func docText(d *document) string {
	var parts []string
	for i := 0; i < d.lineCount(); i++ {
		parts = append(parts, string(d.line(i)))
	}
	return strings.Join(parts, "\n")
}

func docFromText(s string) *document {
	var lines [][]byte
	for _, l := range strings.Split(s, "\n") {
		lines = append(lines, []byte(l))
	}
	return newDocument(lines)
}

func offsetOf(text string, p Position) int {
	off := 0
	for i := 0; i < p.Line; i++ {
		off += strings.IndexByte(text[off:], '\n') + 1
	}
	return off + p.Col
}

func positionOf(text string, off int) Position {
	line := strings.Count(text[:off], "\n")
	return Position{line, off - (strings.LastIndexByte(text[:off], '\n') + 1)}
}

func TestSpliceRandomMatchesStringModel(t *testing.T) {
	rng := rand.New(rand.NewSource(7))
	const alphabet = "ab \n\n"
	randText := func(n int) string {
		b := make([]byte, n)
		for i := range b {
			b[i] = alphabet[rng.Intn(len(alphabet))]
		}
		return string(b)
	}
	model := randText(30)
	d := docFromText(model)
	for step := 0; step < 3000; step++ {
		s := rng.Intn(len(model) + 1)
		e := min(len(model), s+rng.Intn(8))
		ins := randText(rng.Intn(6))
		sp, ep := positionOf(model, s), positionOf(model, e)
		if got, want := string(d.extract(sp, ep)), model[s:e]; got != want {
			t.Fatalf("extract = %q want %q", got, want)
		}
		end := d.splice(sp, ep, []byte(ins))
		model = model[:s] + ins + model[e:]
		if got := docText(d); got != model {
			t.Fatalf("step %d: doc %q want %q", step, got, model)
		}
		if want := positionOf(model, s+len(ins)); end != want {
			t.Fatalf("step %d: end %v want %v", step, end, want)
		}
		if endOf(sp, []byte(ins)) != end {
			t.Fatalf("endOf disagrees with splice")
		}
		if offsetOf(model, end) != s+len(ins) {
			t.Fatalf("offset helper broken")
		}
	}
}

func TestSpliceBytes(t *testing.T) {
	cases := []struct {
		line   string
		a, b   int
		text   string
		expect string
	}{
		{"hello", 2, 2, "XY", "heXYllo"},
		{"hello", 1, 4, "", "ho"},
		{"hello", 0, 5, "world!!", "world!!"},
		{"", 0, 0, "x", "x"},
		{"abc", 3, 3, "d", "abcd"},
	}
	for _, c := range cases {
		line := append(make([]byte, 0, 64), c.line...) // spare capacity: in place
		if got := string(spliceBytes(line, c.a, c.b, []byte(c.text))); got != c.expect {
			t.Errorf("in place %q: got %q want %q", c.line, got, c.expect)
		}
		line = []byte(c.line) // exact capacity: reallocates
		if got := string(spliceBytes(line, c.a, c.b, []byte(c.text))); got != c.expect {
			t.Errorf("realloc %q: got %q want %q", c.line, got, c.expect)
		}
	}
}

func TestShiftInverse(t *testing.T) {
	sh := shift{a: Position{3, 5}, b: Position{1, 2}}
	for _, p := range []Position{{3, 5}, {3, 9}, {4, 0}, {7, 3}} {
		if got := sh.inverse(sh.forward(p)); got != p {
			t.Errorf("inverse(forward(%v)) = %v", p, got)
		}
	}
	if got := sh.forward(Position{3, 9}); got != (Position{1, 6}) {
		t.Errorf("same-line map = %v", got)
	}
	if got := sh.forward(Position{5, 4}); got != (Position{3, 4}) {
		t.Errorf("later-line map = %v", got)
	}
}
