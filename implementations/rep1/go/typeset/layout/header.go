package layout

import (
	"typeset/codexa"
	"typeset/dim"
	"typeset/hlist"
)

// slotItems sets the text of a header or footer slot (0 left, 1 center,
// 2 right) as one unbreakable line.
func (lo *layouter) slotItems(text string, pos int, baseline int64, region Region) []PlacedItem {
	if text == "" {
		return nil
	}
	s := lo.s
	b := hlist.NewBuilder(lo.env, hlist.Context{
		Style: style(s.HeaderFont, false, false), Size: s.HeaderSize, Align: hlist.Left,
	})
	b.Inline(codexa.Literal(text))
	l := b.List()
	items := l.Items[:len(l.Items)-3]
	var w int64
	for _, it := range items {
		switch it.Kind {
		case hlist.Box:
			w += it.Width
		case hlist.Glue:
			w += it.W
		}
	}
	if len(items) == 0 {
		return nil
	}
	var x int64
	switch pos {
	case 0:
		x = lo.bodyX
	case 1:
		x = lo.bodyX + dim.FloorDiv(lo.bodyW-w, 2)
	default:
		x = lo.bodyX + lo.bodyW - w
	}
	var out []PlacedItem
	for _, it := range items {
		switch it.Kind {
		case hlist.Box:
			if !it.Rigid {
				out = append(out, PlacedItem{
					Region: region, Kind: ItemText, Face: it.Face.Name, Size: it.Size,
					X: x, Y: baseline, W: it.Width, Text: it.Text,
				})
			}
			x += it.Width
		case hlist.Glue:
			x += it.W
		}
	}
	return out
}
