package layout

import (
	"fmt"
	"strings"
	"testing"

	"typeset/hyphen"
	"typeset/markup"
	"typeset/metrics"
	"typeset/settings"
)

// A synthetic font: every glyph advances 500 units except a few, space is
// 250/125/85, extra 100, ascent 700, descent 200. All nine faces share it.
const testFace = `cfm 1
face test
ascent 700
descent 200
space 250 125 85
extra 100
default 500
glyph 45 300
glyph 46 250
kern 65 86 -100
`

const testPatterns = `chp 1
left 2
right 2
pattern a1b
exception ex-am-ple
`

func testEnv(t *testing.T, cfg string) *Env {
	t.Helper()
	set := &metrics.Set{}
	for i := range set.Faces {
		f, err := metrics.Parse(metrics.FaceNames[i], testFace)
		if err != nil {
			t.Fatal(err)
		}
		set.Faces[i] = f
	}
	h, err := hyphen.Parse(testPatterns)
	if err != nil {
		t.Fatal(err)
	}
	s, derr := settings.Parse([]byte(cfg))
	if derr != nil {
		t.Fatal(derr)
	}
	return &Env{S: s, Faces: set, Hyph: h, Doc: &markup.Document{Styles: []markup.Style{{}}}}
}

func TestBadness(t *testing.T) {
	cases := []struct{ num, den, want int64 }{
		{11020, 6350, 522}, {3890, 5100, 44}, {0 + 1, 100, 0}, {30950, 5080, 10000}, {5, 1, 10000},
		{1 << 20, (1 << 22) + 5, 1}, // Y^3 beyond 64 bits uses the exact fallback
	}
	for _, c := range cases {
		if got := badness(c.num, c.den); got != c.want {
			t.Errorf("badness(%d,%d) = %d want %d", c.num, c.den, got, c.want)
		}
	}
}

func TestClassify(t *testing.T) {
	type res struct {
		bad int64
		fit int
		ok  bool
	}
	cases := []struct {
		name       string
		L, W, Y, Z int64
		inf        bool
		want       res
	}{
		{"exact", 142000, 142000, 1270, 850, false, res{0, fitDecent, true}},
		{"very loose", 142000, 130980, 6350, 4250, false, res{522, fitVeryLoose, true}},
		{"tight", 142000, 145890, 7620, 5100, false, res{44, fitTight, true}},
		{"overfull", 142000, 164800, 8890, 5950, false, res{10000, fitTight, false}},
		{"unstretchable", 142000, 15630, 0, 0, false, res{10000, fitVeryLoose, false}},
		{"infinite", 142000, 1000, 0, 0, true, res{0, fitDecent, true}},
		{"infinite overfull", 100, 1000, 0, 0, true, res{10000, fitTight, false}},
	}
	for _, c := range cases {
		b, f, ok := classify(c.L, c.W, c.Y, c.Z, c.inf)
		if (res{b, f, ok}) != c.want {
			t.Errorf("%s: got %v,%v,%v want %v", c.name, b, f, ok, c.want)
		}
	}
}

func plain(s string) []markup.Unit { return markup.PlainUnits(s) }

func rootCtx(e *Env, measure int64) Context {
	return Context{Family: metrics.Serif, Size: 10000, Leading: 12000, Left: 0, Measure: measure,
		Align: settings.Justify, Hyphenate: true}
}

func TestBuildListMeasuresAndEnds(t *testing.T) {
	e := testEnv(t, "")
	hl := e.BuildList(plain("AV ab."), rootCtx(e, 100000))
	// "AV" kerns by -100: (500+500-100)*10 = 9000 ; glue 2500/1250/850 ; "ab." 500+500+250=1250 -> 12500
	if hl.Items[0].Kind != IBox || hl.Items[0].W != 9000 {
		t.Errorf("AV width = %d", hl.Items[0].W)
	}
	if g := hl.Items[1]; g.Kind != IGlue || g.W != 2500 || g.Y != 1250 || g.Z != 850 {
		t.Errorf("glue = %+v", g)
	}
	n := len(hl.Items)
	if hl.Items[n-3].P != 10000 || !hl.Items[n-2].Flag || hl.Items[n-1].P != -10000 {
		t.Error("list must end with penalty 10000, infinite glue, penalty -10000")
	}
}

func TestSentenceEndGlue(t *testing.T) {
	e := testEnv(t, "")
	hl := e.BuildList(plain("end. J. x"), rootCtx(e, 100000))
	var glues []Item
	for _, it := range hl.Items[:len(hl.Items)-3] {
		if it.Kind == IGlue {
			glues = append(glues, it)
		}
	}
	if len(glues) != 2 || glues[0].W != 3500 || glues[0].Y != 1870 || glues[1].W != 2500 {
		t.Errorf("sentence glue wrong: %+v", glues)
	}
}

func TestHyphenationItems(t *testing.T) {
	e := testEnv(t, "")
	hl := e.BuildList(plain("example Xabab"), rootCtx(e, 100000))
	var pens, boxes int
	for _, it := range hl.Items {
		if it.Kind == IPenalty && it.Flag {
			pens++
			if it.Text != "-" || it.W != 3000 {
				t.Errorf("pre-break text wrong: %+v", it)
			}
		}
		if it.Kind == IBox {
			boxes++
		}
	}
	// ex-am-ple has 2 points (exception); Xabab matches a1b at q=2 and q=4 but only q=2 survives left=2,right=2
	if pens != 3 || boxes != 5 {
		t.Errorf("pens=%d boxes=%d", pens, boxes)
	}
	e.S.Hyphenate = false
	hl = e.BuildList(plain("example"), rootCtx(e, 100000))
	if len(hl.Items) != 4 {
		t.Errorf("hyphenate=off must not split: %d items", len(hl.Items))
	}
}

func TestBreakAndSetJustify(t *testing.T) {
	e := testEnv(t, "tolerance = 10000\n")
	// words of width 7500 (15 chars... use 5 letters = 25 units*10 = 2500? 5*500*10/1000=25000? compute)
	text := strings.Repeat("aaaa ", 12) + "aaaa"
	ctx := rootCtx(e, 60000)
	ctx.Hyphenate = false
	hl := e.BuildList(plain(text), ctx)
	lines := e.BreakAndSet(hl)
	if len(lines) < 2 {
		t.Fatalf("expected several lines, got %d", len(lines))
	}
	for i, ln := range lines[:len(lines)-1] {
		last := ln.Runs[len(ln.Runs)-1]
		if got := last.X + last.W; got != 60000 {
			t.Errorf("line %d does not fill the measure: ends at %d", i, got)
		}
	}
	if e.Stats.Lines != len(lines) || e.Stats.TotalDemerits <= 0 {
		t.Errorf("stats not updated: %+v", e.Stats)
	}
}

func TestEmptyListOneLine(t *testing.T) {
	e := testEnv(t, "")
	lines := e.BreakAndSet(e.BuildList(nil, rootCtx(e, 50000)))
	if len(lines) != 1 || len(lines[0].Runs) != 0 || e.Stats.TotalDemerits != 100 {
		t.Errorf("empty list: %d lines, demerits %d", len(lines), e.Stats.TotalDemerits)
	}
	if lines[0].Ascent != 7000 || lines[0].Depth != 2000 {
		t.Errorf("empty line metrics %d/%d", lines[0].Ascent, lines[0].Depth)
	}
}

func TestEmergencyPass(t *testing.T) {
	e := testEnv(t, "")
	ctx := rootCtx(e, 3000) // far narrower than any word
	ctx.Hyphenate = false
	lines := e.BreakAndSet(e.BuildList(plain("wwwwwwww wwwwwwww"), ctx))
	if e.Stats.EmergencyLists != 1 || e.Stats.OverfullLines == 0 || len(lines) == 0 {
		t.Errorf("expected pass 2 with overfull lines: %+v", e.Stats)
	}
}

func TestRaggedAlignment(t *testing.T) {
	e := testEnv(t, "")
	ctx := rootCtx(e, 100000)
	ctx.Align = settings.Right
	lines := e.BreakAndSet(e.BuildList(plain("ab ab"), ctx))
	r := lines[0].Runs
	// natural width: 2*1000? "ab"=1000*10/1000... compute through the runs: line ends at the measure.
	if end := r[len(r)-1].X + r[len(r)-1].W; end != 100000 {
		t.Errorf("right-aligned line ends at %d", end)
	}
}

func TestLegality(t *testing.T) {
	e := testEnv(t, "orphans = 2\nwidows = 2\n")
	mk := func(group int32, k, n int32, heading bool) VItem {
		return VItem{Kind: VLine, Line: &Line{}, Group: group, K: k, N: n, Heading: heading}
	}
	items := []VItem{mk(1, 1, 1, true), {Kind: VGlue, H: 100}, mk(2, 1, 4, false), mk(2, 2, 4, false), mk(2, 3, 4, false), mk(2, 4, 4, false)}
	legal := e.legality(items)
	want := []bool{false, false, false, false, true, false, true}
	// position 1 and 2 follow a heading (keep-with-next); 3 is inside the orphan limit; 5 inside widow limit.
	for j, w := range want {
		if legal[j] != w {
			t.Errorf("legal[%d] = %v want %v", j, legal[j], w)
		}
	}
}

func TestPaginateAndHeaders(t *testing.T) {
	e := testEnv(t, "page-width = 200pt\npage-height = 120pt\nmargin-top = 20pt\nmargin-bottom = 20pt\nmargin-left = 20pt\nmargin-right = 20pt\nfooter-center = {page}/{pages}\n")
	doc, err := markup.Parse([]byte("@h1 Intro\nSome text here.\n@newpage\nSecond page.\n"))
	if err != nil {
		t.Fatal(err)
	}
	res := Layout(doc, e.S, e.Faces, e.Hyph)
	if len(res.Pages) != 2 || res.BodyPages != 2 || res.FrontPages != 0 {
		t.Fatalf("pages = %d", len(res.Pages))
	}
	var footers []string
	for _, p := range res.Pages {
		for _, it := range p.Items {
			if it.Region == RFooter {
				footers = append(footers, it.Text)
			}
		}
	}
	if fmt.Sprint(footers) != "[1 / 2 2 / 2]" && fmt.Sprint(footers) != "[1/2 2/2]" {
		// "1/2" is a single fragment
		t.Errorf("footers = %v", footers)
	}
	if res.Stats.Headings != 1 || res.Stats.Paragraphs != 2 {
		t.Errorf("stats = %+v", res.Stats)
	}
}

func TestFootnoteOnPage(t *testing.T) {
	e := testEnv(t, "page-width = 200pt\npage-height = 120pt\nmargin-top = 20pt\nmargin-bottom = 20pt\nmargin-left = 20pt\nmargin-right = 20pt\n")
	doc, _ := markup.Parse([]byte("Word{n|A note.} more.\n"))
	res := Layout(doc, e.S, e.Faces, e.Hyph)
	var rules, notes int
	for _, it := range res.Pages[0].Items {
		if it.Region == RFootnote && it.Kind == KRule {
			rules++
		}
		if it.Region == RFootnote && it.Kind == KText {
			notes++
		}
	}
	if rules != 1 || notes < 2 {
		t.Errorf("footnote area missing: rules=%d texts=%d", rules, notes)
	}
}
