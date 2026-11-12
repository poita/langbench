// Package layout turns a parsed Codexa document into numbered pages of
// positioned items: it builds vertical lists, lays out tables, footnotes and
// floating figures, paginates, and renders headers, footers and the table of
// contents.
package layout

import (
	"typeset/codexa"
	"typeset/hlist"
	"typeset/hyphen"
	"typeset/metric"
	"typeset/settings"
)

// Input is everything Layout needs.
type Input struct {
	Doc      *codexa.Document
	Settings *settings.Settings
	Faces    *metric.Set
	Patterns *hyphen.Patterns // the selected hyphenation pattern set
}

// Region is the part of a page an item belongs to.
type Region uint8

// Regions, in output order.
const (
	RegionHeader Region = iota
	RegionFloat
	RegionBody
	RegionFootnote
	RegionFooter
)

// String returns the region's name in layout.txt.
func (r Region) String() string {
	return [...]string{"header", "float", "body", "footnote", "footer"}[r]
}

// ItemKind is the kind of a placed item.
type ItemKind uint8

// Item kinds, in output order.
const (
	ItemText ItemKind = iota
	ItemRule
	ItemBox
)

// PlacedItem is one positioned output item. For text items X is the left
// edge, Y the baseline and W the advance width; for rules and boxes Y is the
// top edge, W the width and H the thickness or height.
type PlacedItem struct {
	Region Region
	Kind   ItemKind
	Face   string
	Size   int64
	X, Y   int64
	W, H   int64
	Text   string
}

// Page is one output page.
type Page struct {
	Label string
	Items []PlacedItem
}

// Stats are the counters of report.txt.
type Stats struct {
	Pages              int
	FrontPages         int
	BodyPages          int
	Lines              int
	Paragraphs         int
	Headings           int
	Tables             int
	Figures            int
	Footnotes          int
	FootnoteSplitLines int
	HyphenatedLines    int
	OverfullLines      int
	EmergencyLists     int
	TotalDemerits      int64
}

// Result is the laid-out document.
type Result struct {
	Pages []Page // front pages first, then body pages
	Stats Stats
}

// vkind is the kind of a vertical item.
type vkind uint8

const (
	vLine vkind = iota
	vGlue
	vRule
	vRow
	vFloat
	vForce
)

// headInfo describes a heading for the table of contents and the running
// headers.
type headInfo struct {
	level  int
	number string // the number string, "" when unnumbered
	plain  string
	star   bool
	page   int // body page of the first line, 1-based; 0 until placed
}

// vitem is a vertical item.
type vitem struct {
	kind    vkind
	line    *hlist.Line
	leading int64
	k, n    int         // 1-based index within the group and the group size
	heading bool        // group kind is heading
	extras  []hlist.Run // runs placed on the line's baseline (markers, leaders)
	head    *headInfo   // set on the first line of a heading
	h       int64       // GLUE height, RULE thickness, ROW height
	x, w    int64       // RULE
	row     *rowData
	fig     int
}

// rowData is the content of a table row.
type rowData struct {
	ascent int64
	cells  [][]*hlist.Line
}

// noteGroup is a run of footnote lines placed together.
type noteGroup struct {
	note  int
	lines []*hlist.Line
	mark  bool // the footnote's number is drawn in front of the first line
}
