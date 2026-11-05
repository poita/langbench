package render

import (
	"strings"
	"testing"

	"typeset/layout"
)

func TestLayoutSortAndEscape(t *testing.T) {
	res := &layout.Result{Pages: []*layout.Page{{Label: "iv", Items: []layout.OutItem{
		{Region: layout.RFooter, Kind: layout.KText, Face: 0, Size: 9000, X: 5, Y: 1, W: 7, Text: "foot"},
		{Region: layout.RBody, Kind: layout.KText, Face: 1, Size: 10000, X: 30, Y: 200, W: 9, Text: `a"b\c`},
		{Region: layout.RBody, Kind: layout.KBox, X: 30, Y: 200, W: 4, H: 5},
		{Region: layout.RBody, Kind: layout.KRule, X: 30, Y: 200, W: 4, H: 1},
		{Region: layout.RBody, Kind: layout.KText, Face: 0, Size: 10000, X: 10, Y: 200, W: 3, Text: "first"},
		{Region: layout.RHeader, Kind: layout.KText, Face: 4, Size: 9000, X: 99, Y: 99, W: 1, Text: "head"},
	}}}}
	got := Layout(res, [6]int64{1, 2, 3, 4, 5, 6})
	want := strings.Join([]string{
		"layout 1",
		"pages 1",
		"page 1 iv 1 2 3 4 5 6",
		`  text header sans 9000 99 99 1 "head"`,
		`  text body serif 10000 10 200 3 "first"`,
		`  text body serif-bold 10000 30 200 9 "a\"b\\c"`,
		"  rule body 30 200 4 1",
		"  box body 30 200 4 5",
		`  text footer serif 9000 5 1 7 "foot"`,
		"",
	}, "\n")
	if got != want {
		t.Errorf("got:\n%s\nwant:\n%s", got, want)
	}
}

func TestReport(t *testing.T) {
	res := &layout.Result{Pages: make([]*layout.Page, 3), FrontPages: 1, BodyPages: 2}
	res.Stats.Lines = 7
	res.Stats.TotalDemerits = 700
	got := Report(res)
	if !strings.HasPrefix(got, "report 1\npages 3\nfront-pages 1\nbody-pages 2\nlines 7\n") ||
		!strings.HasSuffix(got, "emergency-lists 0\ntotal-demerits 700\n") {
		t.Errorf("report:\n%s", got)
	}
}
