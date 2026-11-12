package hlist

import (
	"os"
	"testing"

	"typeset/codexa"
	"typeset/hyphen"
	"typeset/metric"
)

func testEnv(t *testing.T) *Env {
	t.Helper()
	faces, err := metric.LoadSet(os.DirFS("../data"), "faces")
	if err != nil {
		t.Fatal(err)
	}
	f, err := os.Open("../data/hyphen/english.chp")
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	pats, err := hyphen.Parse(f)
	if err != nil {
		t.Fatal(err)
	}
	return &Env{
		Faces: faces, Patterns: pats, Hyphenate: true, HyphenPenalty: 50,
		ExHyphenPenalty: 50, RaggedStretch: 3, MarkSize: 7000, MarkRaise: 3000,
	}
}

func build(t *testing.T, env *Env, src string, hyph bool) *List {
	t.Helper()
	doc, e := codexa.Parse([]byte(src))
	if e != nil {
		t.Fatal(e)
	}
	b := NewBuilder(env, Context{
		Style: metric.Style{Family: metric.Serif}, Size: 10000, Align: Justify, Hyphenate: hyph,
	})
	b.Inline(doc.Blocks[0].(*codexa.Paragraph).Text)
	return b.List()
}

func TestSimpleList(t *testing.T) {
	l := build(t, testEnv(t), "The quick brown fox.\n", true)
	if len(l.Items) != 10 {
		t.Fatalf("%d items", len(l.Items))
	}
	if l.Items[0].Text != "The" || l.Items[0].Width != 15630 {
		t.Errorf("first box %+v", l.Items[0])
	}
	if g := l.Items[1]; g.W != 2540 || g.Y != 1270 || g.Z != 850 {
		t.Errorf("glue %+v", g)
	}
	if bp := l.Breakpoints(); len(bp) != 5 || bp[1] != 1 || bp[4] != 9 {
		t.Errorf("breakpoints %v", bp)
	}
}

func TestHyphenationItems(t *testing.T) {
	l := build(t, testEnv(t), "typesetting\n", true)
	// typeset - t - ing + final three
	if len(l.Items) != 5+3 {
		t.Fatalf("%d items", len(l.Items))
	}
	if l.Items[1].Kind != Penalty || !l.Items[1].Flagged || l.Items[1].Pre == nil || l.Items[1].Pre.Text != "-" {
		t.Errorf("penalty %+v", l.Items[1])
	}
	off := build(t, testEnv(t), "typesetting\n", false)
	if len(off.Items) != 1+3 {
		t.Errorf("hyphenation not gated by context: %d items", len(off.Items))
	}
}

func TestExplicitDiscretionaryOverridesPatterns(t *testing.T) {
	l := build(t, testEnv(t), "typeset\\-ting\n", true)
	pens := 0
	for _, it := range l.Items {
		if it.Kind == Penalty && it.P == 50 {
			pens++
		}
	}
	if pens != 1 {
		t.Errorf("%d hyphenation penalties, want only the explicit one", pens)
	}
	trailing := build(t, testEnv(t), "typesetting\\-\n", true)
	pens = 0
	for _, it := range trailing.Items {
		if it.Kind == Penalty && it.P == 50 {
			pens++
		}
	}
	if pens != 2 {
		t.Errorf("trailing \\- should not suppress Liang: %d penalties", pens)
	}
}

func TestSentenceGlue(t *testing.T) {
	l := build(t, testEnv(t), "end. J. Smith\n", true)
	var glues []int64
	for _, it := range l.Items {
		if it.Kind == Glue && !it.Infinite {
			glues = append(glues, it.W)
		}
	}
	if len(glues) != 2 || glues[0] != 2540+1120 || glues[1] != 2540 {
		t.Errorf("glues %v", glues)
	}
}

func TestSetLineJustifyFloorDivision(t *testing.T) {
	env := testEnv(t)
	l := build(t, env, "The quick brown fox jumps over the lazy dog.\n", true)
	// break after "the" (item 13): the first line of Example 6.
	var bps []int
	for _, b := range l.Breakpoints() {
		if b > 0 && l.Items[b].Kind == Glue {
			bps = append(bps, b)
		}
	}
	lines := SetLines(env, l, []int{bps[6], l.Final()}, Geometry{Left: 20000, Measure: 160000, FirstIndent: 18000})
	first := lines[0]
	wantX := []int64{38000, 55521, 79653, 106685, 121856, 148348, 167630}
	if len(first.Runs) != len(wantX) {
		t.Fatalf("%d runs", len(first.Runs))
	}
	for i, r := range first.Runs {
		if r.X != wantX[i] {
			t.Errorf("run %d x = %d, want %d", i, r.X, wantX[i])
		}
	}
	if lines[1].Runs[0].X != 20000 {
		t.Errorf("second line starts at %d", lines[1].Runs[0].X)
	}
}

func TestRunMerging(t *testing.T) {
	env := testEnv(t)
	l := build(t, env, "typesetting\n", true)
	lines := SetLines(env, l, []int{l.Final()}, Geometry{Left: 0, Measure: 200000})
	if len(lines[0].Runs) != 1 || lines[0].Runs[0].Text != "typesetting" {
		t.Errorf("runs %+v", lines[0].Runs)
	}
}
