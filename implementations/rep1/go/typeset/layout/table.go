package layout

import (
	"typeset/markup"
	"typeset/settings"
	"typeset/units"
)

// table lays out a @table and appends its vertical items.
func (w *walker) table(t *markup.Table, ctx Context) {
	e, S := w.e, w.e.S
	cols := t.Cols
	lists := make([][]*HList, len(t.Elems))
	nat := make([]int64, cols)
	min := make([]int64, cols)
	for r, el := range t.Elems {
		if el.Rule {
			continue
		}
		lists[r] = make([]*HList, cols)
		for c, cell := range el.Cells {
			cc := Context{Family: ctx.Family, Size: ctx.Size, Leading: S.TableLeading,
				Left: ctx.Left, Measure: ctx.Measure, Hyphenate: ctx.Hyphenate}
			switch t.Align[c] {
			case 'r':
				cc.Align = settings.Right
			case 'c':
				cc.Align = settings.Center
			default:
				cc.Align = settings.Left
			}
			hl := e.BuildList(cell, cc)
			lists[r][c] = hl
			cn := hl.cumW[len(hl.Items)]
			var cm int64
			prev := int32(-1)
			for _, b := range hl.BPs {
				wd, _, _, _ := hl.lineSums(prev, b, true)
				cm = max64(cm, wd)
				prev = b
			}
			nat[c] = max64(nat[c], cn)
			min[c] = max64(min[c], cm)
		}
	}
	A := max64(0, ctx.Measure-int64(cols-1)*S.TableColGap)
	var sn, sm int64
	for c := 0; c < cols; c++ {
		sn += nat[c]
		sm += min[c]
	}
	widths := make([]int64, cols)
	switch {
	case sn <= A:
		copy(widths, nat)
	case sm >= A:
		copy(widths, min)
	default:
		D := sn - A
		Ssum := sn - sm
		var P, Cprev int64
		for c := 0; c < cols; c++ {
			P += nat[c] - min[c]
			C := units.FloorDiv(D*P, Ssum)
			widths[c] = nat[c] - (C - Cprev)
			Cprev = C
		}
	}
	xs := make([]int64, cols)
	x := ctx.Left
	var tw int64
	for c := 0; c < cols; c++ {
		xs[c] = x
		x += widths[c] + S.TableColGap
		tw += widths[c]
	}
	tw += int64(cols-1) * S.TableColGap

	prevRow := false
	for r, el := range t.Elems {
		if el.Rule {
			if r > 0 {
				w.push(VItem{Kind: VGlue, H: S.TableRuleSpace})
			}
			w.push(VItem{Kind: VRule, X: ctx.Left, W: tw, H: S.TableRuleThickness})
			if r < len(t.Elems)-1 {
				w.push(VItem{Kind: VGlue, H: S.TableRuleSpace})
			}
			prevRow = false
			continue
		}
		if prevRow {
			w.push(VItem{Kind: VGlue, H: S.TableRowSpace})
		}
		prevRow = true
		cells := make([][]*Line, cols)
		var arow, drow int64
		nrow := 0
		for c := 0; c < cols; c++ {
			hl := lists[r][c]
			hl.Ctx.Left, hl.Ctx.Measure = xs[c], widths[c]
			ls := e.BreakAndSet(hl)
			cells[c] = ls
			arow = max64(arow, ls[0].Ascent)
			drow = max64(drow, ls[len(ls)-1].Depth)
			if len(ls) > nrow {
				nrow = len(ls)
			}
		}
		row := make([][]RowLine, cols)
		for c := 0; c < cols; c++ {
			for k, ln := range cells[c] {
				row[c] = append(row[c], RowLine{Line: ln, Off: arow + int64(k)*S.TableLeading})
			}
		}
		w.push(VItem{Kind: VRow, H: arow + int64(nrow-1)*S.TableLeading + drow, Row: row})
	}
}
