// Package render formats a laid-out document as layout.txt, report.txt and
// error.txt.
package render

import (
	"sort"
	"strconv"
	"strings"

	"typeset/diag"
	"typeset/layout"
	"typeset/settings"
)

// ErrorFile returns the contents of error.txt for e.
func ErrorFile(e *diag.Error) []byte {
	return []byte(e.Error() + "\n")
}

type line struct {
	region layout.Region
	y, x   int64
	kind   layout.ItemKind
	text   string
}

func quote(s string) string {
	var b strings.Builder
	b.WriteByte('"')
	for _, r := range s {
		if r == '\\' || r == '"' {
			b.WriteByte('\\')
		}
		b.WriteRune(r)
	}
	b.WriteByte('"')
	return b.String()
}

func formatItem(it *layout.PlacedItem) string {
	i := func(v int64) string { return strconv.FormatInt(v, 10) }
	switch it.Kind {
	case layout.ItemText:
		return "  text " + it.Region.String() + " " + it.Face + " " + i(it.Size) + " " +
			i(it.X) + " " + i(it.Y) + " " + i(it.W) + " " + quote(it.Text)
	case layout.ItemRule:
		return "  rule " + it.Region.String() + " " + i(it.X) + " " + i(it.Y) + " " + i(it.W) + " " + i(it.H)
	}
	return "  box " + it.Region.String() + " " + i(it.X) + " " + i(it.Y) + " " + i(it.W) + " " + i(it.H)
}

// Layout returns the contents of layout.txt.
func Layout(res *layout.Result, s *settings.Settings) []byte {
	var b strings.Builder
	i := func(v int64) string { return strconv.FormatInt(v, 10) }
	b.WriteString("layout 1\npages " + strconv.Itoa(len(res.Pages)) + "\n")
	for n, pg := range res.Pages {
		b.WriteString("page " + strconv.Itoa(n+1) + " " + pg.Label + " " +
			i(s.PageWidth) + " " + i(s.PageHeight) + " " + i(s.BodyX()) + " " + i(s.BodyY()) + " " +
			i(s.BodyWidth()) + " " + i(s.BodyHeight()) + "\n")
		lines := make([]line, len(pg.Items))
		for k := range pg.Items {
			it := &pg.Items[k]
			lines[k] = line{it.Region, it.Y, it.X, it.Kind, formatItem(it)}
		}
		sort.SliceStable(lines, func(a, c int) bool {
			x, y := &lines[a], &lines[c]
			if x.region != y.region {
				return x.region < y.region
			}
			if x.y != y.y {
				return x.y < y.y
			}
			if x.x != y.x {
				return x.x < y.x
			}
			if x.kind != y.kind {
				return x.kind < y.kind
			}
			return x.text < y.text
		})
		for _, l := range lines {
			b.WriteString(l.text)
			b.WriteByte('\n')
		}
	}
	return []byte(b.String())
}

// Report returns the contents of report.txt.
func Report(st layout.Stats) []byte {
	var b strings.Builder
	row := func(k string, v int64) {
		b.WriteString(k + " " + strconv.FormatInt(v, 10) + "\n")
	}
	b.WriteString("report 1\n")
	row("pages", int64(st.Pages))
	row("front-pages", int64(st.FrontPages))
	row("body-pages", int64(st.BodyPages))
	row("lines", int64(st.Lines))
	row("paragraphs", int64(st.Paragraphs))
	row("headings", int64(st.Headings))
	row("tables", int64(st.Tables))
	row("figures", int64(st.Figures))
	row("footnotes", int64(st.Footnotes))
	row("footnote-split-lines", int64(st.FootnoteSplitLines))
	row("hyphenated-lines", int64(st.HyphenatedLines))
	row("overfull-lines", int64(st.OverfullLines))
	row("emergency-lists", int64(st.EmergencyLists))
	row("total-demerits", st.TotalDemerits)
	return []byte(b.String())
}
