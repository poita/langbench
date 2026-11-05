package layout

import (
	"strings"

	"typeset/hyphen"
	"typeset/markup"
	"typeset/metrics"
	"typeset/settings"
	"typeset/units"
)

// Result is the complete laid-out document.
type Result struct {
	Pages      []*Page
	FrontPages int
	BodyPages  int
	Stats      Stats
}

// Layout lays out a document and returns every page.
func Layout(doc *markup.Document, s *settings.Settings, faces *metrics.Set, hyph *hyphen.Set) *Result {
	e := &Env{S: s, Faces: faces, Hyph: hyph, Doc: doc}
	e.Stats.Paragraphs, e.Stats.Headings = doc.Paragraphs, doc.Headings
	e.Stats.Tables, e.Stats.Figures = doc.Tables, doc.Figures
	e.Stats.Footnotes = len(doc.Footnotes)
	e.layoutFootnotes()

	w := &walker{e: e}
	root := Context{Family: s.BodyFont, Size: s.BodySize, Leading: s.Leading,
		Left: s.BodyX(), Measure: s.BodyWidth(), Align: s.Align, Hyphenate: s.Hyphenate}
	w.blocks(doc.Blocks, root, 0)

	body := e.paginate(w.items)
	headPage := make([]int, len(w.headings)) // 1-based body page of each heading
	for hi, h := range w.headings {
		for m, r := range body {
			if h.Item >= r.first && h.Item < r.cut {
				headPage[hi] = m + 1
				break
			}
		}
	}
	res := &Result{BodyPages: len(body)}
	var pages []*Page
	if doc.HasTOC {
		front := e.paginate(e.buildTOC(w.headings, headPage))
		for m, r := range front {
			r.page.Label = units.Roman(m + 1)
			r.page.Num = m + 1
			pages = append(pages, r.page)
		}
		res.FrontPages = len(front)
	}
	nFront := len(pages)
	hp := 0
	var chapter, section string
	for m, r := range body {
		for hp < len(w.headings) && headPage[hp] != 0 && headPage[hp] <= m+1 {
			h := w.headings[hp]
			txt := h.Plain
			if h.Number != "" {
				txt = h.Number + " " + h.Plain
			}
			if h.Level == 1 {
				chapter = txt
			} else if h.Level == 2 {
				section = txt
			}
			hp++
		}
		num := int(s.PageStart) + m
		r.page.Num = num
		r.page.Label = itoa(int64(num))
		e.headerFooter(r.page, chapter, section, len(body))
		pages = append(pages, r.page)
	}
	for _, p := range pages[:nFront] {
		e.headerFooter(p, "", "", len(body))
	}
	res.Pages = pages
	res.Stats = e.Stats
	return res
}

// headerFooter appends the running header and footer items of a page.
func (e *Env) headerFooter(p *Page, chapter, section string, pages int) {
	S := e.S
	parity := 0
	if p.Num%2 == 0 {
		parity = 1
	}
	for slot := 0; slot < 6; slot++ {
		var sb strings.Builder
		for _, part := range S.Slots[parity][slot] {
			switch part.Placeholder {
			case "":
				sb.WriteString(part.Lit)
			case "page":
				sb.WriteString(p.Label)
			case "pages":
				sb.WriteString(itoa(int64(pages)))
			case "title":
				sb.WriteString(e.Doc.Meta.Title)
			case "author":
				sb.WriteString(e.Doc.Meta.Author)
			case "date":
				sb.WriteString(e.Doc.Meta.Date)
			case "chapter":
				sb.WriteString(chapter)
			case "section":
				sb.WriteString(section)
			}
		}
		us := markup.PlainUnits(sb.String())
		if len(us) == 0 {
			continue
		}
		ctx := Context{Family: S.HeaderFont, Size: S.HeaderSize, Measure: 1 << 40, Align: settings.Justify}
		hl := e.BuildList(us, ctx)
		items := hl.Items[:len(hl.Items)-3]
		var W int64
		for _, it := range items {
			W += it.W
		}
		var x int64
		switch slot % 3 {
		case 0:
			x = S.BodyX()
		case 1:
			x = S.BodyX() + units.FloorDiv(S.BodyWidth()-W, 2)
		default:
			x = S.BodyX() + S.BodyWidth() - W
		}
		region, base := uint8(RHeader), S.HeaderBaseline
		if slot >= 3 {
			region, base = RFooter, S.FooterBaseline
		}
		for _, it := range items {
			if it.Kind == IBox && !it.Flag {
				p.Items = append(p.Items, OutItem{Region: region, Kind: KText, Face: int(it.Face), Size: it.Size,
					X: x, Y: base, W: it.W, Text: it.Text})
			}
			x += it.W
		}
	}
}

// buildTOC builds the vertical list of the table of contents.
func (e *Env) buildTOC(heads []HeadingRec, headPage []int) []VItem {
	S := e.S
	w := &walker{e: e}
	title := S.TOCTitle
	if e.Doc.HasTOCTitle {
		title = e.Doc.TOCTitle
	}
	tc := Context{Family: S.TOCTitleFont, Bold: S.HeadingBold, Italic: S.HeadingItalic, Size: S.TOCTitleSize,
		Leading: S.HLeading[0], Left: S.BodyX(), Measure: S.BodyWidth(), Align: S.HeadingAlign, Hyphenate: S.Hyphenate}
	w.leaf(0, S.TOCTitleSpaceAfter, func() {
		w.emitLines(e.BreakAndSet(e.BuildList(markup.PlainUnits(title), tc)), false)
	})
	face := metrics.FaceIndex(S.TOCFont, false, false)
	for hi, h := range heads {
		if h.Star || int64(h.Level) > S.TOCDepth {
			continue
		}
		off := int64(h.Level-1) * S.TOCIndent
		c := Context{Family: S.TOCFont, Size: S.TOCSize, Leading: S.TOCLeading, Left: S.BodyX() + off,
			Measure: clampMeasure(S.BodyWidth() - off - S.TOCReserve), Align: settings.Left, Hyphenate: S.Hyphenate}
		var us []markup.Unit
		if h.Number != "" {
			for _, r := range h.Number {
				us = append(us, markup.Unit{Kind: markup.UChar, R: r})
			}
			us = append(us, markup.Unit{Kind: markup.UFixed, Aux: S.TOCNumberGap})
		}
		us = append(us, markup.PlainUnits(h.Plain)...)
		label := itoa(S.PageStart + int64(headPage[hi]) - 1)
		w.leaf(S.TOCEntrySpace, S.TOCEntrySpace, func() {
			lines := e.BreakAndSet(e.BuildList(us, c))
			last := lines[len(lines)-1]
			lw := e.textWidth(face, S.TOCSize, []rune(label))
			labelX := S.BodyX() + S.BodyWidth() - lw
			xFrom := last.EndX + S.TOCLeaderGap
			xTo := labelX - S.TOCLeaderGap
			unit := e.textWidth(face, S.TOCSize, []rune(S.TOCLeader))
			if k := units.FloorDiv(xTo-xFrom, unit); k > 0 {
				last.Extra = append(last.Extra, Run{Text: strings.Repeat(S.TOCLeader, int(k)), Face: face,
					Size: S.TOCSize, X: xTo - k*unit, W: k * unit})
			}
			last.Extra = append(last.Extra, Run{Text: label, Face: face, Size: S.TOCSize, X: labelX, W: lw})
			w.emitLines(lines, false)
		})
	}
	return w.items
}
