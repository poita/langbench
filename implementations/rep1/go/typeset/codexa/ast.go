// Package codexa parses the Codexa markup language into a block tree whose
// inline text is already resolved into styled character units.
package codexa

// File is the name reported in document errors.
const File = "document.cdx"

// Style is the inline style in force at some point of the text. Size is the
// sequence of size steps applied so far, one byte per step: '+' for a step
// up, '-' for a step down. (The steps cannot be collapsed to a count because
// the rounding of up and down steps differs.)
type Style struct {
	Bold, Italic, Mono bool
	Size               string
}

// UnitKind classifies a unit of the resolved character stream.
type UnitKind uint8

// Unit kinds.
const (
	Char  UnitKind = iota // an ordinary character
	Space                 // one inter-word space (runs are already collapsed)
	Rigid                 // a rigid, never-breaking space (~ or "\ ")
	Mark                  // a footnote reference mark
	Disc                  // a discretionary hyphenation point
)

// Unit is one element of the resolved character stream.
type Unit struct {
	Kind  UnitKind
	R     rune  // the character, for Char
	Style Style // the style in force
	Note  int   // the footnote number, for Mark
}

// Inline is the resolved text of a block: spaces are collapsed and the
// leading and trailing space is removed.
type Inline []Unit

// Footnote is the text of one {n|...}. Numbers start at 1 in source order.
type Footnote struct {
	Number int
	Text   Inline
}

// Meta is the content of the @doc block.
type Meta struct {
	Title, Author, Date string
}

// TOC is the @toc block.
type TOC struct {
	Title    string
	HasTitle bool // the title attribute was given
}

// Document is a parsed Codexa document.
type Document struct {
	Meta      Meta
	TOC       *TOC // nil when there is no @toc
	Blocks    []Block
	Footnotes []*Footnote // indexed by Number-1
}

// Block is any block-level construct.
type Block interface{ isBlock() }

// Paragraph is a paragraph of text.
type Paragraph struct{ Text Inline }

// Heading is @h1..@h4. Star marks an unnumbered heading.
type Heading struct {
	Level int
	Star  bool
	Text  Inline
}

// Quote is @q.
type Quote struct{ Children []Block }

// Group is @block with its optional overrides.
type Group struct {
	Align       string
	Font        string
	Indent      int64
	RightIndent int64
	Size        int64
	Leading     int64
	HasAlign    bool
	HasFont     bool
	HasIndent   bool
	HasRight    bool
	HasSize     bool
	HasLeading  bool
	Children    []Block
}

// List is @ul or @ol.
type List struct {
	Ordered bool
	Start   int64
	Items   []*Item
}

// Item is one @li: its inline text followed by nested blocks.
type Item struct {
	Text     Inline
	Children []Block
}

// Table is @table.
type Table struct {
	Cols  int
	Align []byte // one of 'l', 'r', 'c' per column
	Rows  []TableElem
}

// TableElem is a table row or a horizontal rule.
type TableElem struct {
	Rule  bool
	Cells []Inline
}

// Pre is @pre; Lines have their trailing spaces removed.
type Pre struct{ Lines []string }

// Figure is @fig.
type Figure struct {
	Height   int64
	Width    int64
	HasWidth bool
	Caption  Inline
}

// Rule is @rule.
type Rule struct{}

// VSpace is @vspace.
type VSpace struct{ Height int64 }

// NewPage is @newpage.
type NewPage struct{}

func (*Paragraph) isBlock() {}
func (*Heading) isBlock()   {}
func (*Quote) isBlock()     {}
func (*Group) isBlock()     {}
func (*List) isBlock()      {}
func (*Table) isBlock()     {}
func (*Pre) isBlock()       {}
func (*Figure) isBlock()    {}
func (*Rule) isBlock()      {}
func (*VSpace) isBlock()    {}
func (*NewPage) isBlock()   {}

// Literal converts plain text to an Inline: every space becomes a Space unit
// and every other character an ordinary character, with the usual collapsing
// and trimming of spaces.
func Literal(s string) Inline {
	var u []Unit
	for _, r := range s {
		if r == ' ' {
			u = append(u, Unit{Kind: Space})
		} else {
			u = append(u, Unit{Kind: Char, R: r})
		}
	}
	return normalize(u)
}

// PlainText returns the plain text of a heading: styles removed, discretionary
// points dropped, rigid spaces turned into spaces, space runs collapsed and
// the ends trimmed.
func PlainText(in Inline) string {
	var out []rune
	lastSpace := true
	for _, u := range in {
		switch u.Kind {
		case Char:
			out = append(out, u.R)
			lastSpace = false
		case Space, Rigid:
			if !lastSpace {
				out = append(out, ' ')
				lastSpace = true
			}
		}
	}
	if n := len(out); n > 0 && out[n-1] == ' ' {
		out = out[:n-1]
	}
	return string(out)
}

// normalize collapses runs of Space units (keeping the first's style) and
// removes a Space at the start and at the end.
func normalize(u []Unit) Inline {
	out := make([]Unit, 0, len(u))
	for _, x := range u {
		if x.Kind == Space && len(out) > 0 && out[len(out)-1].Kind == Space {
			continue
		}
		out = append(out, x)
	}
	if len(out) > 0 && out[0].Kind == Space {
		out = out[1:]
	}
	if n := len(out); n > 0 && out[n-1].Kind == Space {
		out = out[:n-1]
	}
	return out
}
