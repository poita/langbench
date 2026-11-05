// Package layout turns a parsed Codexa document and its settings into placed
// pages: horizontal lists, total-fit line breaking, line setting, vertical
// lists, tables, footnotes, floats, page breaking, the table of contents and
// running headers.
package layout

import (
	"sort"
	"strconv"
	"strings"

	"typeset/hyphen"
	"typeset/markup"
	"typeset/metrics"
	"typeset/settings"
	"typeset/units"
)

// Stats are the counters reported in report.txt.
type Stats struct {
	Lines, Paragraphs, Headings, Tables, Figures, Footnotes int
	FootnoteSplitLines, HyphenatedLines, OverfullLines      int
	EmergencyLists                                          int
	TotalDemerits                                           int64
}

// Env bundles everything the layout stages need.
type Env struct {
	S     *settings.Settings
	Faces *metrics.Set
	Hyph  *hyphen.Set
	Doc   *markup.Document
	Stats Stats

	nextFrag int32
	figs     []*FigBlock
	fnLines  [][]*Line
}

// Context is the horizontal-list context of the specification.
type Context struct {
	Family      int
	Bold        bool
	Italic      bool
	Size        int64
	Leading     int64
	Left        int64
	Measure     int64
	FirstIndent int64
	Align       int
	Hyphenate   bool
}

// ItemKind tags a horizontal-list item.
type ItemKind uint8

// Horizontal-list item kinds.
const (
	IBox ItemKind = iota
	IGlue
	IPenalty
)

// Item is one item of a horizontal list. For a BOX, W is the width and Flag
// marks a rigid box (no text, no face). For a GLUE, W/Y/Z are the natural
// width, stretch and shrink and Flag marks the infinite glue. For a PENALTY,
// P is the penalty, Flag says flagged, and Text/W are the pre-break text and
// its width.
type Item struct {
	Kind    ItemKind
	Flag    bool
	Face    int8
	Size    int64
	Raise   int64
	W, Y, Z int64
	P       int64
	Text    string
	Frag    int32
	Fn      int32
}

// HList is a built horizontal list with the prefix sums used by line
// breaking and line setting.
type HList struct {
	Items  []Item
	Ctx    Context
	BPs    []int32 // breakpoint item indices (breakpoint 0 is implicit)
	cumW   []int64
	cumY   []int64
	cumZ   []int64
	cumInf []int32
	nextNG []int32
}

// face metrics helper.
func (e *Env) face(i int) *metrics.Face { return e.Faces.Faces[i] }

func (e *Env) resolve(ctx *Context, st markup.Style) (int, int64) {
	family := ctx.Family
	if st.Mono {
		family = metrics.Mono
	}
	size := ctx.Size
	for i := 0; i < len(st.Steps); i++ {
		if st.Steps[i] == '+' {
			size = units.FloorDiv(size*6, 5)
		} else {
			size = units.FloorDiv(size*5, 6)
		}
	}
	return metrics.FaceIndex(family, ctx.Bold || st.Bold, ctx.Italic || st.Italic), size
}

// textWidth returns the single-scale width of text in a face at a size.
func (e *Env) textWidth(face int, size int64, text []rune) int64 {
	return units.Scale(e.face(face).Units(text), size)
}

func isLetter(r rune) bool { return r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' }

// sentenceEnd reports whether the glue at units[idx] follows a sentence end.
func sentenceEnd(us []markup.Unit, idx int) bool {
	k := idx - 1
	for k >= 0 {
		u := us[k]
		if u.Kind == markup.UDisc {
			k--
			continue
		}
		if u.Kind != markup.UChar {
			return false
		}
		if strings.ContainsRune(")]}'\"’”", u.R) {
			k--
			continue
		}
		break
	}
	if k < 0 || us[k].Kind != markup.UChar {
		return false
	}
	if r := us[k].R; r != '.' && r != '!' && r != '?' {
		return false
	}
	k--
	for k >= 0 && us[k].Kind == markup.UDisc {
		k--
	}
	if k >= 0 && us[k].Kind == markup.UChar && us[k].R >= 'A' && us[k].R <= 'Z' {
		return false
	}
	return true
}

type point struct {
	pos     int
	core    bool // after a hyphen of the core: no pre-break text
	penalty int64
}

// hyphenPoints computes the hyphenation points of a fragment.
func (e *Env) hyphenPoints(chars []rune, discs []int) []point {
	n := len(chars)
	lo, hi := -1, 0
	for i, c := range chars {
		if isLetter(c) {
			if lo < 0 {
				lo = i
			}
			hi = i + 1
		}
	}
	if lo < 0 {
		return nil
	}
	var pts []point
	for k := lo; k < hi; k++ {
		if chars[k] == '-' {
			pts = append(pts, point{pos: k + 1, core: true, penalty: e.S.ExHyphenPenalty})
		}
	}
	explicit := false
	for _, p := range discs {
		if p > 0 && p < n {
			explicit = true
			pts = append(pts, point{pos: p, penalty: e.S.HyphenPenalty})
		}
	}
	if !explicit {
		a := lo
		for a <= hi {
			b := a
			for b < hi && chars[b] != '-' {
				b++
			}
			allLetters := b > a
			for k := a; k < b; k++ {
				if !isLetter(chars[k]) {
					allLetters = false
				}
			}
			if allLetters {
				low := make([]byte, b-a)
				for k := a; k < b; k++ {
					c := chars[k]
					if c >= 'A' && c <= 'Z' {
						c += 'a' - 'A'
					}
					low[k-a] = byte(c)
				}
				for _, q := range e.Hyph.Positions(string(low)) {
					pts = append(pts, point{pos: a + q, penalty: e.S.HyphenPenalty})
				}
			}
			a = b + 1
		}
	}
	sort.SliceStable(pts, func(i, j int) bool { return pts[i].pos < pts[j].pos })
	out := pts[:0]
	for _, p := range pts {
		if len(out) > 0 && out[len(out)-1].pos == p.pos {
			if p.core && !out[len(out)-1].core {
				out[len(out)-1] = p
			}
			continue
		}
		out = append(out, p)
	}
	return out
}

// BuildList builds the horizontal list of a unit stream in a context.
func (e *Env) BuildList(us []markup.Unit, ctx Context) *HList {
	hl := &HList{Ctx: ctx}
	items := make([]Item, 0, len(us)/3+8)
	ragged := ctx.Align != settings.Justify
	type res struct {
		face int
		size int64
		ok   bool
	}
	cache := make([]res, len(e.Doc.Styles)+1)
	resolve := func(id int32) (int, int64) {
		if int(id) >= len(cache) {
			return e.resolve(&ctx, e.Doc.StyleOf(id))
		}
		c := &cache[id]
		if !c.ok {
			c.face, c.size = e.resolve(&ctx, e.Doc.StyleOf(id))
			c.ok = true
		}
		return c.face, c.size
	}

	var chars []rune
	var discs []int
	var fFace int
	var fSize, fRaise int64
	flush := func() {
		if len(chars) == 0 {
			return
		}
		e.nextFrag++
		frag := e.nextFrag
		var pts []point
		if ctx.Hyphenate && e.S.Hyphenate && fFace != metrics.MonoFace {
			pts = e.hyphenPoints(chars, discs)
		}
		prev := 0
		emit := func(to int) {
			items = append(items, Item{Kind: IBox, Face: int8(fFace), Size: fSize, Raise: fRaise,
				W: e.textWidth(fFace, fSize, chars[prev:to]), Text: string(chars[prev:to]), Frag: frag})
			prev = to
		}
		for _, p := range pts {
			emit(p.pos)
			pen := Item{Kind: IPenalty, Flag: true, P: p.penalty, Face: int8(fFace), Size: fSize, Raise: fRaise, Frag: frag}
			if !p.core {
				pen.Text = "-"
				pen.W = e.textWidth(fFace, fSize, []rune{'-'})
			}
			items = append(items, pen)
		}
		emit(len(chars))
		chars = chars[:0]
		discs = discs[:0]
	}

	for idx, u := range us {
		switch u.Kind {
		case markup.UChar:
			face, size := resolve(u.Style)
			if len(chars) > 0 && (face != fFace || size != fSize || fRaise != 0) {
				flush()
			}
			if len(chars) == 0 {
				fFace, fSize, fRaise = face, size, 0
			}
			chars = append(chars, u.R)
		case markup.UDisc:
			if len(chars) > 0 && (len(discs) == 0 || discs[len(discs)-1] != len(chars)) {
				discs = append(discs, len(chars))
			}
		case markup.UGlue:
			flush()
			face, size := resolve(u.Style)
			f := e.face(face)
			g := Item{Kind: IGlue}
			if u.Aux != 1 && sentenceEnd(us, idx) {
				g.W = units.Scale(f.Space+f.Extra, size)
				g.Y = units.Scale(f.Stretch+units.FloorDiv(f.Stretch, 2), size)
				g.Z = units.Scale(f.Shrink, size)
			} else {
				g.W = units.Scale(f.Space, size)
				g.Y = units.Scale(f.Stretch, size)
				g.Z = units.Scale(f.Shrink, size)
			}
			if ragged {
				g.Y = e.S.RaggedStretch * g.W
				g.Z = 0
			}
			items = append(items, g)
		case markup.URigid:
			flush()
			face, size := resolve(u.Style)
			items = append(items, Item{Kind: IBox, Flag: true, W: units.Scale(e.face(face).Space, size), Frag: 0})
		case markup.UFixed:
			flush()
			items = append(items, Item{Kind: IBox, Flag: true, W: u.Aux})
		case markup.UMark:
			flush()
			st := e.Doc.StyleOf(u.Style)
			family := ctx.Family
			if st.Mono {
				family = metrics.Mono
			}
			face := metrics.FaceIndex(family, ctx.Bold || st.Bold, ctx.Italic || st.Italic)
			text := []rune(strconv.FormatInt(u.Aux, 10))
			e.nextFrag++
			items = append(items, Item{Kind: IBox, Face: int8(face), Size: e.S.MarkSize, Raise: e.S.MarkRaise,
				W: e.textWidth(face, e.S.MarkSize, text), Text: string(text), Frag: e.nextFrag, Fn: int32(u.Aux)})
		}
	}
	flush()
	items = append(items,
		Item{Kind: IPenalty, P: 10000},
		Item{Kind: IGlue, Flag: true},
		Item{Kind: IPenalty, P: -10000})
	hl.Items = items
	hl.prepare()
	return hl
}

// prepare computes the prefix sums and the breakpoint list.
func (hl *HList) prepare() {
	n := len(hl.Items)
	hl.cumW = make([]int64, n+1)
	hl.cumY = make([]int64, n+1)
	hl.cumZ = make([]int64, n+1)
	hl.cumInf = make([]int32, n+1)
	hl.nextNG = make([]int32, n+2)
	for i, it := range hl.Items {
		hl.cumW[i+1], hl.cumY[i+1], hl.cumZ[i+1], hl.cumInf[i+1] = hl.cumW[i], hl.cumY[i], hl.cumZ[i], hl.cumInf[i]
		switch it.Kind {
		case IBox:
			hl.cumW[i+1] += it.W
		case IGlue:
			hl.cumW[i+1] += it.W
			hl.cumY[i+1] += it.Y
			hl.cumZ[i+1] += it.Z
			if it.Flag {
				hl.cumInf[i+1]++
			}
		}
		isBP := (it.Kind == IGlue && i > 0 && hl.Items[i-1].Kind == IBox) ||
			(it.Kind == IPenalty && it.P < 10000)
		if isBP {
			hl.BPs = append(hl.BPs, int32(i))
		}
	}
	hl.nextNG[n] = int32(n)
	hl.nextNG[n+1] = int32(n)
	for i := n - 1; i >= 0; i-- {
		if hl.Items[i].Kind == IGlue {
			hl.nextNG[i] = hl.nextNG[i+1]
		} else {
			hl.nextNG[i] = int32(i)
		}
	}
}

// start returns the index of the first non-glue item of a line starting
// after breakpoint a (a == -1 for the notional start).
func (hl *HList) start(a int32) int32 { return hl.nextNG[a+1] }

// lineSums returns W, Y, Z and the infinite flag of the line (a, b), where
// the pre-break text of b is included in W when withPre is set.
func (hl *HList) lineSums(a, b int32, withPre bool) (w, y, z int64, inf bool) {
	s := hl.start(a)
	if s < b {
		w = hl.cumW[b] - hl.cumW[s]
		y = hl.cumY[b] - hl.cumY[s]
		z = hl.cumZ[b] - hl.cumZ[s]
		inf = hl.cumInf[b]-hl.cumInf[s] > 0
	}
	if withPre && hl.Items[b].Kind == IPenalty {
		w += hl.Items[b].W
	}
	return
}

func itoa(n int64) string { return strconv.FormatInt(n, 10) }
