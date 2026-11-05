// Package render formats a laid-out document as layout.txt and report.txt.
package render

import (
	"sort"
	"strconv"
	"strings"

	"typeset/layout"
	"typeset/metrics"
)

var regionNames = [...]string{"header", "float", "body", "footnote", "footer"}

type formatted struct {
	region, kind uint8
	x, y         int64
	line         string
}

func appendInt(b []byte, n int64) []byte { return strconv.AppendInt(b, n, 10) }

func format(it *layout.OutItem) formatted {
	b := make([]byte, 0, 64)
	b = append(b, "  "...)
	switch it.Kind {
	case layout.KText:
		b = append(b, "text "...)
		b = append(b, regionNames[it.Region]...)
		b = append(b, ' ')
		b = append(b, metrics.FaceNames[it.Face]...)
		b = append(b, ' ')
		b = appendInt(b, it.Size)
		b = append(b, ' ')
		b = appendInt(b, it.X)
		b = append(b, ' ')
		b = appendInt(b, it.Y)
		b = append(b, ' ')
		b = appendInt(b, it.W)
		b = append(b, " \""...)
		for i := 0; i < len(it.Text); i++ {
			c := it.Text[i]
			if c == '\\' || c == '"' {
				b = append(b, '\\')
			}
			b = append(b, c)
		}
		b = append(b, '"')
	case layout.KRule:
		b = append(b, "rule "...)
		b = append(b, regionNames[it.Region]...)
		b = append(b, ' ')
		b = appendInt(b, it.X)
		b = append(b, ' ')
		b = appendInt(b, it.Y)
		b = append(b, ' ')
		b = appendInt(b, it.W)
		b = append(b, ' ')
		b = appendInt(b, it.H)
	default:
		b = append(b, "box "...)
		b = append(b, regionNames[it.Region]...)
		b = append(b, ' ')
		b = appendInt(b, it.X)
		b = append(b, ' ')
		b = appendInt(b, it.Y)
		b = append(b, ' ')
		b = appendInt(b, it.W)
		b = append(b, ' ')
		b = appendInt(b, it.H)
	}
	return formatted{region: it.Region, kind: it.Kind, x: it.X, y: it.Y, line: string(b)}
}

// Layout renders layout.txt. geometry is the six numbers that follow the
// label in every page record.
func Layout(res *layout.Result, geometry [6]int64) string {
	var sb strings.Builder
	sb.WriteString("layout 1\npages ")
	sb.WriteString(strconv.Itoa(len(res.Pages)))
	sb.WriteByte('\n')
	for i, p := range res.Pages {
		sb.WriteString("page ")
		sb.WriteString(strconv.Itoa(i + 1))
		sb.WriteByte(' ')
		sb.WriteString(p.Label)
		for _, g := range geometry {
			sb.WriteByte(' ')
			sb.WriteString(strconv.FormatInt(g, 10))
		}
		sb.WriteByte('\n')
		fs := make([]formatted, len(p.Items))
		for k := range p.Items {
			fs[k] = format(&p.Items[k])
		}
		sort.Slice(fs, func(a, b int) bool {
			x, y := &fs[a], &fs[b]
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
			return x.line < y.line
		})
		for _, f := range fs {
			sb.WriteString(f.line)
			sb.WriteByte('\n')
		}
	}
	return sb.String()
}

// Report renders report.txt.
func Report(res *layout.Result) string {
	st := res.Stats
	var sb strings.Builder
	add := func(k string, v int64) {
		sb.WriteString(k)
		sb.WriteByte(' ')
		sb.WriteString(strconv.FormatInt(v, 10))
		sb.WriteByte('\n')
	}
	sb.WriteString("report 1\n")
	add("pages", int64(len(res.Pages)))
	add("front-pages", int64(res.FrontPages))
	add("body-pages", int64(res.BodyPages))
	add("lines", int64(st.Lines))
	add("paragraphs", int64(st.Paragraphs))
	add("headings", int64(st.Headings))
	add("tables", int64(st.Tables))
	add("figures", int64(st.Figures))
	add("footnotes", int64(st.Footnotes))
	add("footnote-split-lines", int64(st.FootnoteSplitLines))
	add("hyphenated-lines", int64(st.HyphenatedLines))
	add("overfull-lines", int64(st.OverfullLines))
	add("emergency-lists", int64(st.EmergencyLists))
	add("total-demerits", st.TotalDemerits)
	return sb.String()
}
