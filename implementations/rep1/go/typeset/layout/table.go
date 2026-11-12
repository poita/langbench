package layout

import (
	"typeset/codexa"
	"typeset/dim"
	"typeset/hlist"
)

// table lays out a table and returns its vertical items.
func (lo *layouter) table(t *codexa.Table, c bctx) []vitem {
	s := lo.s
	cols := t.Cols
	nat := make([]int64, cols)
	min := make([]int64, cols)

	// Build every cell's list once and measure it.
	lists := make([][]*hlist.List, len(t.Rows))
	for ri, row := range t.Rows {
		if row.Rule {
			continue
		}
		lists[ri] = make([]*hlist.List, cols)
		for ci, cell := range row.Cells {
			al := hlist.Left
			switch t.Align[ci] {
			case 'r':
				al = hlist.Right
			case 'c':
				al = hlist.Center
			}
			bl := hlist.NewBuilder(lo.env, hlist.Context{
				Style: style(c.family, false, false), Size: c.size, Align: al, Hyphenate: c.hyphenate,
			})
			bl.Inline(cell)
			l := bl.List()
			lists[ri][ci] = l
			nat[ci] = dim.Max(nat[ci], l.Natural())
			bps := l.Breakpoints()
			for k := 1; k < len(bps); k++ {
				min[ci] = dim.Max(min[ci], l.Line(bps[k-1], bps[k]).W)
			}
		}
	}

	// Column widths.
	A := dim.Max(0, c.measure-int64(cols-1)*s.TableColGap)
	var sumNat, sumMin int64
	for i := 0; i < cols; i++ {
		sumNat += nat[i]
		sumMin += min[i]
	}
	w := make([]int64, cols)
	switch {
	case sumNat <= A:
		copy(w, nat)
	case sumMin >= A:
		copy(w, min)
	default:
		D := sumNat - A
		var S int64
		for i := 0; i < cols; i++ {
			S += nat[i] - min[i]
		}
		var P, prevC int64
		for i := 0; i < cols; i++ {
			P += nat[i] - min[i]
			C := dim.FloorDiv(D*P, S)
			w[i] = nat[i] - (C - prevC)
			prevC = C
		}
	}
	x := make([]int64, cols)
	var tw int64
	for i := 0; i < cols; i++ {
		x[i] = c.left + tw
		tw += w[i] + s.TableColGap
	}
	tw -= s.TableColGap
	// tw is now sum(w) + (cols-1)*gap

	var items []vitem
	prevRow := false
	for ri, row := range t.Rows {
		if row.Rule {
			if ri > 0 {
				items = append(items, vitem{kind: vGlue, h: s.TableRuleSpace})
			}
			items = append(items, vitem{kind: vRule, x: c.left, w: tw, h: s.TableRuleThickness})
			if ri < len(t.Rows)-1 {
				items = append(items, vitem{kind: vGlue, h: s.TableRuleSpace})
			}
			prevRow = false
			continue
		}
		if prevRow {
			items = append(items, vitem{kind: vGlue, h: s.TableRowSpace})
		}
		prevRow = true
		rd := &rowData{cells: make([][]*hlist.Line, cols)}
		var aRow, dRow int64
		nRow := 0
		for ci := 0; ci < cols; ci++ {
			lines := lo.breakAndSet(lists[ri][ci], hlist.Geometry{Left: x[ci], Measure: w[ci]})
			rd.cells[ci] = lines
			aRow = dim.Max(aRow, lines[0].Ascent)
			dRow = dim.Max(dRow, lines[len(lines)-1].Depth)
			if len(lines) > nRow {
				nRow = len(lines)
			}
		}
		rd.ascent = aRow
		h := aRow + int64(nRow-1)*s.TableLeading + dRow
		items = append(items, vitem{kind: vRow, row: rd, h: h})
	}
	return items
}
