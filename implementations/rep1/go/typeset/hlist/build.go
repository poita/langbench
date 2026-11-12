package hlist

import (
	"sort"
	"strconv"

	"typeset/codexa"
	"typeset/dim"
	"typeset/hyphen"
	"typeset/metric"
)

// Env holds the settings-derived parameters of list construction.
type Env struct {
	Faces           *metric.Set
	Patterns        *hyphen.Patterns
	Hyphenate       bool // the global hyphenate setting
	HyphenPenalty   int64
	ExHyphenPenalty int64
	RaggedStretch   int64
	MarkSize        int64
	MarkRaise       int64
}

// Builder assembles a horizontal list.
type Builder struct {
	env   *Env
	ctx   Context
	items []Item
	frag  int
	sizes map[string]int64
}

// NewBuilder returns a builder for a list in the given context.
func NewBuilder(env *Env, ctx Context) *Builder {
	return &Builder{env: env, ctx: ctx, sizes: map[string]int64{"": ctx.Size}}
}

// Face resolves the context's face.
func (b *Builder) Face() *metric.Face { return b.env.Faces.Face(b.ctx.Style) }

// Box appends a standalone BOX (its own fragment, never hyphenated).
func (b *Builder) Box(text string, face *metric.Face, size int64) {
	b.frag++
	b.items = append(b.items, Item{
		Kind: Box, Face: face, Size: size, Text: text,
		Width: face.StringWidth(text, size), Frag: b.frag,
	})
}

// Rigid appends a rigid box of the given width.
func (b *Builder) Rigid(w int64) {
	b.items = append(b.items, Item{Kind: Box, Rigid: true, Width: w})
}

// Space appends an ordinary glue of the context face and size.
func (b *Builder) Space() {
	f, s := b.Face(), b.ctx.Size
	b.items = append(b.items, Item{
		Kind: Glue,
		W:    dim.Scale(f.Space, s), Y: dim.Scale(f.Stretch, s), Z: dim.Scale(f.Shrink, s),
	})
}

func (b *Builder) resolve(st codexa.Style) (*metric.Face, int64) {
	style := b.ctx.Style
	if st.Mono {
		style.Family = metric.Mono
	}
	if st.Bold {
		style.Bold = true
	}
	if st.Italic {
		style.Italic = true
	}
	size, ok := b.sizes[st.Size]
	if !ok {
		size = b.ctx.Size
		for i := 0; i < len(st.Size); i++ {
			if st.Size[i] == '+' {
				size = size * 6 / 5
			} else {
				size = size * 5 / 6
			}
		}
		b.sizes[st.Size] = size
	}
	return b.env.Faces.Face(style), size
}

// Inline appends the resolved inline text.
func (b *Builder) Inline(in codexa.Inline) {
	var chars []rune
	var discs []int
	var face *metric.Face
	var size int64
	prevOrd := false

	flush := func() {
		if len(chars) > 0 {
			b.fragment(chars, discs, face, size)
		}
		chars, discs = nil, nil
	}
	for idx, u := range in {
		switch u.Kind {
		case codexa.Char:
			f, s := b.resolve(u.Style)
			if len(chars) > 0 && (f != face || s != size) {
				flush()
			}
			face, size = f, s
			chars = append(chars, u.R)
			prevOrd = true
		case codexa.Space:
			flush()
			f, s := b.resolve(u.Style)
			w, y, z := dim.Scale(f.Space, s), dim.Scale(f.Stretch, s), dim.Scale(f.Shrink, s)
			if sentenceEnd(in, idx) {
				w = dim.Scale(f.Space+f.Extra, s)
				y = dim.Scale(f.Stretch+f.Stretch/2, s)
			}
			b.items = append(b.items, Item{Kind: Glue, W: w, Y: y, Z: z})
			prevOrd = false
		case codexa.Rigid:
			flush()
			f, s := b.resolve(u.Style)
			b.Rigid(dim.Scale(f.Space, s))
			prevOrd = false
		case codexa.Mark:
			flush()
			f, _ := b.resolve(u.Style)
			b.frag++
			text := strconv.Itoa(u.Note)
			b.items = append(b.items, Item{
				Kind: Box, Face: f, Size: b.env.MarkSize, Raise: b.env.MarkRaise,
				Text: text, Width: f.StringWidth(text, b.env.MarkSize), Frag: b.frag, Note: u.Note,
			})
			prevOrd = false
		case codexa.Disc:
			if prevOrd && len(chars) > 0 {
				discs = append(discs, len(chars))
			}
		}
	}
	flush()
}

func isCloser(r rune) bool {
	switch r {
	case ')', ']', '}', '\'', '"', '’', '”':
		return true
	}
	return false
}

// sentenceEnd reports whether the space at in[idx] follows a sentence end.
func sentenceEnd(in codexa.Inline, idx int) bool {
	j := idx - 1
	for j >= 0 {
		u := in[j]
		if u.Kind == codexa.Disc || (u.Kind == codexa.Char && isCloser(u.R)) {
			j--
			continue
		}
		break
	}
	if j < 0 || in[j].Kind != codexa.Char {
		return false
	}
	if c := in[j].R; c != '.' && c != '!' && c != '?' {
		return false
	}
	j--
	for j >= 0 && in[j].Kind == codexa.Disc {
		j--
	}
	if j >= 0 && in[j].Kind == codexa.Char && in[j].R >= 'A' && in[j].R <= 'Z' {
		return false
	}
	return true
}

type hpoint struct {
	pos     int
	penalty int64
	pre     bool
}

func isLetter(r rune) bool { return (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') }

// points computes a fragment's hyphenation points.
func (b *Builder) points(chars []rune, discs []int, face *metric.Face) []hpoint {
	if !b.ctx.Hyphenate || !b.env.Hyphenate || face.Name == "mono" {
		return nil
	}
	lo, hi := -1, -1
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
	n := len(chars)
	var explicit []int
	for _, d := range discs {
		if d > 0 && d < n {
			explicit = append(explicit, d)
		}
	}
	pts := map[int]hpoint{}
	for _, d := range explicit {
		pts[d] = hpoint{pos: d, penalty: b.env.HyphenPenalty, pre: true}
	}
	segStart := lo
	for k := lo; k <= hi; k++ {
		if k == hi || chars[k] == '-' {
			if k < hi {
				pts[k+1] = hpoint{pos: k + 1, penalty: b.env.ExHyphenPenalty}
			}
			if len(explicit) == 0 && b.env.Patterns != nil && k > segStart {
				seg := chars[segStart:k]
				letters := true
				low := make([]byte, len(seg))
				for i, c := range seg {
					if !isLetter(c) {
						letters = false
						break
					}
					if c >= 'A' && c <= 'Z' {
						c += 'a' - 'A'
					}
					low[i] = byte(c)
				}
				if letters {
					for _, q := range b.env.Patterns.Points(string(low)) {
						pts[segStart+q] = hpoint{pos: segStart + q, penalty: b.env.HyphenPenalty, pre: true}
					}
				}
			}
			segStart = k + 1
		}
	}
	out := make([]hpoint, 0, len(pts))
	for _, p := range pts {
		out = append(out, p)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].pos < out[j].pos })
	return out
}

// fragment appends one fragment as a BOX or as BOXes split by PENALTYs.
func (b *Builder) fragment(chars []rune, discs []int, face *metric.Face, size int64) {
	b.frag++
	frag := b.frag
	pts := b.points(chars, discs, face)
	start := 0
	for _, p := range pts {
		b.items = append(b.items, Item{
			Kind: Box, Face: face, Size: size, Text: string(chars[start:p.pos]),
			Width: face.Width(chars[start:p.pos], size), Frag: frag,
		})
		pen := Item{Kind: Penalty, P: p.penalty, Flagged: true}
		if p.pre {
			pen.Pre = &Item{
				Kind: Box, Face: face, Size: size, Text: "-",
				Width: face.StringWidth("-", size), Frag: frag,
			}
		}
		b.items = append(b.items, pen)
		start = p.pos
	}
	b.items = append(b.items, Item{
		Kind: Box, Face: face, Size: size, Text: string(chars[start:]),
		Width: face.Width(chars[start:], size), Frag: frag,
	})
}

// List finishes the list: ragged alignments get ragged glue and the three
// closing items are appended.
func (b *Builder) List() *List {
	if b.ctx.Align != Justify {
		for i := range b.items {
			if it := &b.items[i]; it.Kind == Glue {
				it.Y = b.env.RaggedStretch * it.W
				it.Z = 0
			}
		}
	}
	b.items = append(b.items,
		Item{Kind: Penalty, P: 10000},
		Item{Kind: Glue, Infinite: true},
		Item{Kind: Penalty, P: -10000},
	)
	return &List{Items: b.items, Ctx: b.ctx}
}
