// Package markup parses the Codexa markup language into a block tree whose
// inline text is already resolved into styled character units.
package markup

// UnitKind classifies one element of a resolved inline stream.
type UnitKind uint8

const (
	// UChar is an ordinary character (R).
	UChar UnitKind = iota
	// UGlue is one inter-word glue (a collapsed run of spaces). Aux == 1
	// marks a glue that is never an extra-space glue.
	UGlue
	// URigid is a rigid space (from `~` or `\ `) whose width is the space
	// of the face in force.
	URigid
	// UFixed is a rigid box of fixed width Aux (millipoints).
	UFixed
	// UDisc is a discretionary hyphenation point (`\-`).
	UDisc
	// UMark is a footnote reference mark; Aux is the footnote number.
	UMark
)

// Unit is one element of the resolved inline stream. Style indexes the
// document's style table.
type Unit struct {
	Kind  UnitKind
	Style int32
	R     rune
	Aux   int64
}

// Style is the inline style in force: the flags only ever switch things on
// (a nested tag cannot switch bold off), and Steps records the exact
// sequence of size steps ('+' up, '-' down), because the steps do not
// commute under integer rounding.
type Style struct {
	Bold, Italic, Mono bool
	Steps              string
}

// Alignment numbers, identical to the settings package.
const (
	AlignJustify = iota
	AlignLeft
	AlignRight
	AlignCenter
)

// Block is one block of the document: *Paragraph, *Heading, *Quote, *Group,
// *List, *Table, *Pre, *Figure, *Rule, *VSpace or *NewPage.
type Block interface{}

// Paragraph is a run of text lines.
type Paragraph struct{ Text []Unit }

// Heading is @h1..@h4. Plain is the heading's plain text (see the spec).
type Heading struct {
	Level int
	Star  bool
	Text  []Unit
	Plain string
}

// Quote is a @q block.
type Quote struct{ Children []Block }

// Group is a @block with optional overrides.
type Group struct {
	Align       *int
	Indent      *int64
	RightIndent *int64
	Font        *int
	Size        *int64
	Leading     *int64
	Children    []Block
}

// List is a @ul or @ol.
type List struct {
	Ordered bool
	Start   int
	Items   []*Item
}

// Item is one @li: its text and the blocks that follow it.
type Item struct {
	Text     []Unit
	Children []Block
}

// TableElem is a row of cells or an @hrule.
type TableElem struct {
	Rule  bool
	Cells [][]Unit
}

// Table is a @table.
type Table struct {
	Cols  int
	Align string // one letter of "lrc" per column
	Elems []TableElem
}

// Pre is a @pre block; Lines are verbatim with trailing spaces removed.
type Pre struct{ Lines []string }

// Figure is a @fig.
type Figure struct {
	Height   int64
	Width    int64
	HasWidth bool
	Caption  []Unit
}

// Rule is @rule.
type Rule struct{}

// VSpace is @vspace.
type VSpace struct{ Height int64 }

// NewPage is @newpage.
type NewPage struct{}

// Meta holds the @doc values.
type Meta struct{ Title, Author, Date string }

// Document is a parsed Codexa document.
type Document struct {
	Meta        Meta
	HasTOC      bool
	TOCTitle    string // value of the @toc title attribute
	HasTOCTitle bool
	Blocks      []Block
	Footnotes   [][]Unit // footnote n is Footnotes[n-1]
	Styles      []Style

	Paragraphs, Headings, Tables, Figures int
}

// StyleOf returns the style with the given id.
func (d *Document) StyleOf(id int32) Style { return d.Styles[id] }

// PlainUnits turns literal text into a unit stream: spaces become collapsed
// glue (stripped at both ends) and every other character is ordinary, all in
// the base style (id 0).
func PlainUnits(s string) []Unit {
	var out []Unit
	for _, r := range s {
		if r == ' ' {
			if len(out) > 0 && out[len(out)-1].Kind != UGlue {
				out = append(out, Unit{Kind: UGlue})
			}
			continue
		}
		out = append(out, Unit{Kind: UChar, R: r})
	}
	if n := len(out); n > 0 && out[n-1].Kind == UGlue {
		out = out[:n-1]
	}
	return out
}

// PlainText returns the plain text of an inline stream: discretionary points
// removed, rigid and ordinary spaces replaced by one space, runs of spaces
// collapsed and the ends trimmed.
func PlainText(us []Unit) string {
	var b []rune
	for _, u := range us {
		switch u.Kind {
		case UChar:
			b = append(b, u.R)
		case UGlue, URigid:
			if len(b) > 0 && b[len(b)-1] != ' ' {
				b = append(b, ' ')
			}
		}
	}
	for len(b) > 0 && b[len(b)-1] == ' ' {
		b = b[:len(b)-1]
	}
	return string(b)
}
