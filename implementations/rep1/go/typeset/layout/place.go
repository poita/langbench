package layout

import (
	"strconv"

	"typeset/hlist"
	"typeset/numeral"
	"typeset/settings"
)

func runItem(region Region, r *hlist.Run, baseline int64) PlacedItem {
	return PlacedItem{
		Region: region, Kind: ItemText, Face: r.Face.Name, Size: r.Size,
		X: r.X, Y: baseline - r.Raise, W: r.Width, Text: r.Text,
	}
}

func (p *paginator) placeLine(pg *rawPage, it *vitem, base int64) {
	for i := range it.line.Runs {
		pg.items = append(pg.items, runItem(RegionBody, &it.line.Runs[i], base))
	}
	for i := range it.extras {
		pg.items = append(pg.items, runItem(RegionBody, &it.extras[i], base))
	}
	if h := it.head; h != nil {
		h.page = len(p.pages) + 1
		text := h.plain
		if h.number != "" {
			text = h.number + " " + h.plain
		}
		switch h.level {
		case 1:
			p.chapter = text
		case 2:
			p.section = text
		}
	}
}

func (lo *layouter) figureItems(f *figure, y int64) []PlacedItem {
	var out []PlacedItem
	if lo.s.FigureFrame {
		out = append(out, PlacedItem{Region: RegionFloat, Kind: ItemBox, X: f.fx, Y: y, W: f.fw, H: f.height})
	}
	for k, ln := range f.lines {
		for i := range ln.Runs {
			out = append(out, runItem(RegionFloat, &ln.Runs[i], y+f.baseline[k]))
		}
	}
	return out
}

func (lo *layouter) rowItems(pg *rawPage, it *vitem, top int64) {
	for _, lines := range it.row.cells {
		for k, ln := range lines {
			base := top + it.row.ascent + int64(k)*lo.s.TableLeading
			for i := range ln.Runs {
				pg.items = append(pg.items, runItem(RegionBody, &ln.Runs[i], base))
			}
		}
	}
}

// placeNotes places the footnote area of a page.
func (p *paginator) placeNotes(pg *rawPage, groups []*noteGroup) {
	if len(groups) == 0 {
		return
	}
	lo, s := p.lo, p.lo.s
	var ns noteStack
	for _, g := range groups {
		ns.startGroup(s.FootnoteItemSpace)
		for _, ln := range g.lines {
			p.addNoteLine(&ns, ln)
		}
	}
	hfn := ns.st.cursor
	ruleTop := lo.bodyBottom - hfn - s.FootnoteSpaceAfter - s.FootnoteRuleThickness
	pg.items = append(pg.items, PlacedItem{
		Region: RegionFootnote, Kind: ItemRule, X: lo.bodyX, Y: ruleTop,
		W: s.FootnoteRuleWidth, H: s.FootnoteRuleThickness,
	})
	top := ruleTop + s.FootnoteRuleThickness + s.FootnoteSpaceAfter
	st := newVstate(top)
	face := lo.faces.Face(style(s.FootnoteFont, false, false))
	for gi, g := range groups {
		if gi > 0 {
			st.skip(s.FootnoteItemSpace)
		}
		for li, ln := range g.lines {
			base := st.line(s.FootnoteLeading, s.LineSkip, ln.Ascent, ln.Depth)
			for i := range ln.Runs {
				pg.items = append(pg.items, runItem(RegionFootnote, &ln.Runs[i], base))
			}
			if li == 0 && g.mark {
				text := strconv.Itoa(g.note)
				w := face.StringWidth(text, s.FootnoteMarkSize)
				pg.items = append(pg.items, PlacedItem{
					Region: RegionFootnote, Kind: ItemText, Face: face.Name, Size: s.FootnoteMarkSize,
					X: lo.bodyX + s.FootnoteIndent - s.FootnoteMarkGap - w, Y: base - s.FootnoteMarkRaise,
					W: w, Text: text,
				})
			}
		}
	}
}

// assemble adds headers and footers and numbers the pages.
func (lo *layouter) assemble(front, body []rawPage) *Result {
	s := lo.s
	res := &Result{}
	nBody := len(body)
	add := func(rp rawPage, label string, num int, isBody bool) {
		pg := Page{Label: label, Items: rp.items}
		par := 0
		if num%2 == 0 {
			par = 1
		}
		for slot := 0; slot < settings.NumSlots; slot++ {
			chapter, section := "", ""
			if isBody {
				chapter, section = rp.chapter, rp.section
			}
			text := lo.expand(s.Slots[par][slot], label, nBody, chapter, section)
			base, region := s.HeaderBaseline, RegionHeader
			if slot >= settings.FooterLeft {
				base, region = s.FooterBaseline, RegionFooter
			}
			pg.Items = append(pg.Items, lo.slotItems(text, slot%3, base, region)...)
		}
		res.Pages = append(res.Pages, pg)
	}
	for m, rp := range front {
		add(rp, numeral.Roman(m+1), m+1, false)
	}
	for m, rp := range body {
		n := int(s.PageStart) + m
		add(rp, strconv.Itoa(n), n, true)
	}
	res.Stats = lo.stats
	res.Stats.FrontPages = len(front)
	res.Stats.BodyPages = nBody
	res.Stats.Pages = len(front) + nBody
	return res
}

// expand substitutes the placeholders of a template.
func (lo *layouter) expand(t settings.Template, label string, pages int, chapter, section string) string {
	var out []byte
	for _, part := range t {
		if part.Placeholder == "" {
			out = append(out, part.Literal...)
			continue
		}
		switch part.Placeholder {
		case "page":
			out = append(out, label...)
		case "pages":
			out = strconv.AppendInt(out, int64(pages), 10)
		case "title":
			out = append(out, lo.doc.Meta.Title...)
		case "author":
			out = append(out, lo.doc.Meta.Author...)
		case "date":
			out = append(out, lo.doc.Meta.Date...)
		case "chapter":
			out = append(out, chapter...)
		case "section":
			out = append(out, section...)
		}
	}
	return string(out)
}

// pageLabel returns the decimal label of body page m (1-based).
func (lo *layouter) pageLabel(m int) string {
	return strconv.Itoa(int(lo.s.PageStart) + m - 1)
}
