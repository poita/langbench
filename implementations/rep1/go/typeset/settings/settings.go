// Package settings parses settings.cfg into a Settings value, applying the
// defaults, ranges and error positions of the specification.
package settings

import (
	"strings"
	"unicode/utf8"

	"typeset/diag"
	"typeset/dim"
)

// File is the name reported in settings errors.
const File = "settings.cfg"

// Alignment values.
const (
	Justify = "justify"
	Left    = "left"
	Right   = "right"
	Center  = "center"
)

// Header and footer slot indices into Settings.Slots[parity].
const (
	HeaderLeft = iota
	HeaderCenter
	HeaderRight
	FooterLeft
	FooterCenter
	FooterRight
	NumSlots
)

// Template is a text setting: literal runs and placeholders.
type Template []TemplatePart

// TemplatePart is either literal text (Placeholder == "") or a placeholder
// such as "page".
type TemplatePart struct {
	Literal     string
	Placeholder string
}

// HasPlaceholder reports whether the template contains a placeholder.
func (t Template) HasPlaceholder() bool {
	for _, p := range t {
		if p.Placeholder != "" {
			return true
		}
	}
	return false
}

// Literal returns the template's text with placeholders ignored; it is
// meaningful only for templates without placeholders.
func (t Template) Literal() string {
	var b strings.Builder
	for _, p := range t {
		b.WriteString(p.Literal)
	}
	return b.String()
}

// Settings is the complete set of layout settings. All lengths are in
// millipoints. Level-indexed arrays are indexed by heading level minus one.
type Settings struct {
	PageWidth, PageHeight                            int64
	MarginTop, MarginBottom, MarginLeft, MarginRight int64
	HeaderBaseline, FooterBaseline                   int64
	PageStart                                        int64

	BodyFont                    string
	BodySize, Leading, LineSkip int64
	Align                       string
	ParIndent, ParSpace         int64

	Tolerance, LinePenalty            int64
	HyphenPenalty, ExHyphenPenalty    int64
	AdjDemerits, DoubleHyphenDemerits int64
	FinalHyphenDemerits               int64
	RaggedStretch                     int64
	Hyphenate                         bool
	HyphenPatterns                    string

	HeadingFont                string
	HeadingBold, HeadingItalic bool
	HeadingAlign               string
	HeadingNumber              bool
	HeadingNumberGap           int64
	H1Newpage                  bool
	HSize, HLeading            [4]int64
	HSpaceBefore, HSpaceAfter  [4]int64

	ListIndent, ListMarkerGap int64
	ListSpace, ListItemSpace  int64
	QuoteIndent, QuoteSpace   int64
	PreFont                   string
	PreSize, PreLeading       int64
	PreIndent, PreSpace       int64

	TableColGap, TableRowSpace         int64
	TableRuleSpace, TableRuleThickness int64
	TableSpace, TableLeading           int64
	RuleThickness, RuleSpace           int64

	FootnoteFont                             string
	FootnoteSize, FootnoteLeading            int64
	FootnoteIndent, FootnoteMarkGap          int64
	FootnoteMarkSize, FootnoteMarkRaise      int64
	FootnoteItemSpace                        int64
	FootnoteRuleWidth, FootnoteRuleThickness int64
	FootnoteSpaceBefore, FootnoteSpaceAfter  int64
	FootnoteMinSplit                         int64
	FootnoteMaxHeight                        int64
	MarkSize, MarkRaise                      int64

	FigureWidth                             int64
	FigureFrame                             bool
	FigureCaptionFont                       string
	FigureCaptionSize, FigureCaptionLeading int64
	FigureCaptionAlign                      string
	FigureCaptionSpace                      int64
	FigureCaptionPrefix                     string
	FigureCaptionGap                        int64
	FloatSpaceAfter, FloatMinBody           int64

	Widows, Orphans int64
	KeepWithNext    bool

	TocDepth                            int64
	TocFont                             string
	TocSize, TocLeading                 int64
	TocIndent, TocNumberGap, TocReserve int64
	TocLeader                           string
	TocLeaderGap, TocEntrySpace         int64
	TocTitle                            string
	TocTitleFont                        string
	TocTitleSize, TocTitleSpaceAfter    int64

	HeaderFont string
	HeaderSize int64
	// Slots[0] holds the odd-page templates, Slots[1] the even-page ones.
	Slots [2][NumSlots]Template
}

// BodyX, BodyY, BodyWidth, BodyHeight and BodyBottom describe the body
// rectangle.
func (s *Settings) BodyX() int64      { return s.MarginLeft }
func (s *Settings) BodyY() int64      { return s.MarginTop }
func (s *Settings) BodyWidth() int64  { return s.PageWidth - s.MarginLeft - s.MarginRight }
func (s *Settings) BodyHeight() int64 { return s.PageHeight - s.MarginTop - s.MarginBottom }
func (s *Settings) BodyBottom() int64 { return s.BodyY() + s.BodyHeight() }

// Defaults returns the settings used when no settings.cfg is given.
func Defaults() *Settings {
	s := &Settings{}
	s.setDefaults()
	s.finish(nil)
	return s
}

func (s *Settings) setDefaults() {
	pt := int64(dim.Pt)
	s.PageWidth, s.PageHeight = 612*pt, 792*pt
	s.MarginTop, s.MarginBottom, s.MarginLeft, s.MarginRight = 72*pt, 72*pt, 72*pt, 72*pt
	s.HeaderBaseline = 36 * pt
	s.PageStart = 1
	s.BodyFont = "serif"
	s.BodySize, s.Leading, s.LineSkip = 10*pt, 12*pt, 1*pt
	s.Align = Justify
	s.ParIndent, s.ParSpace = 18*pt, 0
	s.Tolerance, s.LinePenalty = 1000, 10
	s.HyphenPenalty, s.ExHyphenPenalty = 50, 50
	s.AdjDemerits, s.DoubleHyphenDemerits, s.FinalHyphenDemerits = 10000, 10000, 5000
	s.RaggedStretch = 3
	s.Hyphenate = true
	s.HyphenPatterns = "english"
	s.HeadingFont = "sans"
	s.HeadingBold = true
	s.HeadingAlign = Left
	s.HeadingNumber = true
	s.HeadingNumberGap = 6 * pt
	s.HSize = [4]int64{20 * pt, 14 * pt, 12 * pt, 11 * pt}
	s.HLeading = [4]int64{24 * pt, 17 * pt, 14 * pt, 13 * pt}
	s.HSpaceBefore = [4]int64{18 * pt, 14 * pt, 12 * pt, 11 * pt}
	s.HSpaceAfter = [4]int64{9 * pt, 7 * pt, 6 * pt, 5 * pt}
	s.ListIndent, s.ListMarkerGap, s.ListSpace, s.ListItemSpace = 18*pt, 4*pt, 6*pt, 0
	s.QuoteIndent, s.QuoteSpace = 18*pt, 6*pt
	s.PreFont = "mono"
	s.PreSize, s.PreLeading, s.PreIndent, s.PreSpace = 9*pt, 11*pt, 0, 6*pt
	s.TableColGap, s.TableRowSpace, s.TableRuleSpace = 8*pt, 2*pt, 2*pt
	s.TableRuleThickness = 400
	s.TableSpace, s.TableLeading = 6*pt, 12*pt
	s.RuleThickness, s.RuleSpace = 500, 6*pt
	s.FootnoteFont = "serif"
	s.FootnoteSize, s.FootnoteLeading = 8*pt, 10*pt
	s.FootnoteIndent, s.FootnoteMarkGap = 10*pt, 2*pt
	s.FootnoteMarkSize, s.FootnoteMarkRaise = 6*pt, 2*pt
	s.FootnoteItemSpace = 2 * pt
	s.FootnoteRuleWidth, s.FootnoteRuleThickness = 120*pt, 400
	s.FootnoteSpaceBefore, s.FootnoteSpaceAfter = 6*pt, 3*pt
	s.FootnoteMinSplit = 1
	s.MarkSize, s.MarkRaise = 7*pt, 3*pt
	s.FigureCaptionFont = "serif"
	s.FigureFrame = true
	s.FigureCaptionSize, s.FigureCaptionLeading = 9*pt, 11*pt
	s.FigureCaptionAlign = Center
	s.FigureCaptionSpace = 4 * pt
	s.FigureCaptionPrefix = "Figure"
	s.FigureCaptionGap = 4 * pt
	s.FloatSpaceAfter, s.FloatMinBody = 12*pt, 24*pt
	s.Widows, s.Orphans = 2, 2
	s.KeepWithNext = true
	s.TocDepth = 2
	s.TocFont = "serif"
	s.TocSize, s.TocLeading = 10*pt, 14*pt
	s.TocIndent, s.TocNumberGap, s.TocReserve = 18*pt, 6*pt, 30*pt
	s.TocLeader = "."
	s.TocLeaderGap = 3 * pt
	s.TocTitle = "Contents"
	s.TocTitleFont = "sans"
	s.TocTitleSize, s.TocTitleSpaceAfter = 20*pt, 12*pt
	s.HeaderFont = "sans"
	s.HeaderSize = 9 * pt
}

// finish resolves the derived defaults. assigned records which keys were
// explicitly set.
func (s *Settings) finish(assigned map[string]bool) {
	if !assigned["footer-baseline"] {
		s.FooterBaseline = s.PageHeight - 36*dim.Pt
	}
	if !assigned["footnote-max-height"] {
		s.FootnoteMaxHeight = dim.FloorDiv(s.BodyHeight(), 2)
	}
	for slot := 0; slot < NumSlots; slot++ {
		if !assigned[evenKeys[slot]] {
			s.Slots[1][slot] = s.Slots[0][slot]
		}
	}
}

var slotKeys = [NumSlots]string{
	"header-left", "header-center", "header-right",
	"footer-left", "footer-center", "footer-right",
}

var evenKeys = [NumSlots]string{
	"header-left-even", "header-center-even", "header-right-even",
	"footer-left-even", "footer-center-even", "footer-right-even",
}

// pos is a 1-based line/column.
type pos struct{ line, col int }

// Parse parses the contents of settings.cfg. A nil *diag.Error means success.
func Parse(data []byte) (*Settings, *diag.Error) {
	s := &Settings{}
	s.setDefaults()
	tab := s.table()
	assigned := map[string]bool{}
	valuePos := map[string]pos{}
	var geomOrder []string

	text := string(data)
	lines := strings.Split(text, "\n")
	if n := len(lines); n > 0 && lines[n-1] == "" {
		lines = lines[:n-1]
	}
	for ln, raw := range lines {
		line := []rune(raw)
		fail := func(col int, code string) (*Settings, *diag.Error) {
			return nil, &diag.Error{File: File, Line: ln + 1, Col: col, Code: code}
		}
		i := 0
		for i < len(line) && (line[i] == ' ' || line[i] == '\t') {
			i++
		}
		if i == len(line) || line[i] == '#' {
			continue
		}
		keyStart := i
		for i < len(line) && isKeyChar(line[i]) {
			i++
		}
		keyEnd := i
		for i < len(line) && (line[i] == ' ' || line[i] == '\t') {
			i++
		}
		if keyEnd == keyStart || i >= len(line) || line[i] != '=' {
			return fail(keyStart+1, diag.BadSyntax)
		}
		i++
		key := string(line[keyStart:keyEnd])
		f, ok := tab[key]
		if !ok {
			return fail(keyStart+1, diag.UnknownSetting)
		}
		if assigned[key] {
			return fail(keyStart+1, diag.DuplicateSetting)
		}
		vs := i
		for vs < len(line) && (line[vs] == ' ' || line[vs] == '\t') {
			vs++
		}
		ve := len(line)
		for ve > vs && (line[ve-1] == ' ' || line[ve-1] == '\t') {
			ve--
		}
		value := line[vs:ve]
		valCol := vs + 1
		if vs >= len(line) {
			valCol = len(line) + 1
		}
		if code, off := f(value); code != "" {
			return fail(valCol+off, code)
		}
		assigned[key] = true
		valuePos[key] = pos{ln + 1, valCol}
		switch key {
		case "page-width", "page-height", "margin-top", "margin-bottom", "margin-left", "margin-right":
			geomOrder = append(geomOrder, key)
		}
	}
	if s.BodyWidth() < 36000 || s.BodyHeight() < 36000 {
		e := &diag.Error{File: File, Code: diag.BadValue}
		if len(geomOrder) > 0 {
			p := valuePos[geomOrder[len(geomOrder)-1]]
			e.Line, e.Col = p.line, p.col
		}
		return nil, e
	}
	s.finish(assigned)
	return s, nil
}

func isKeyChar(r rune) bool {
	return (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') || r == '-'
}

// A parser returns an error code and the rune offset within the value at
// which it is reported ("" means success).
type parser func(v []rune) (string, int)

func (s *Settings) table() map[string]parser {
	t := map[string]parser{}
	length := func(key string, p *int64, lo, hi int64) {
		t[key] = func(v []rune) (string, int) {
			x, ok := dim.ParseLength(string(v))
			if !ok {
				return diag.BadLength, 0
			}
			if x < lo || x > hi {
				return diag.BadValue, 0
			}
			*p = x
			return "", 0
		}
	}
	const inf = int64(1) << 60
	integer := func(key string, p *int64, lo, hi int64) {
		t[key] = func(v []rune) (string, int) {
			x, ok := dim.ParseInteger(string(v))
			if !ok {
				return diag.BadInteger, 0
			}
			if x < lo || x > hi {
				return diag.BadValue, 0
			}
			*p = x
			return "", 0
		}
	}
	boolean := func(key string, p *bool) {
		t[key] = func(v []rune) (string, int) {
			switch string(v) {
			case "on":
				*p = true
			case "off":
				*p = false
			default:
				return diag.BadBoolean, 0
			}
			return "", 0
		}
	}
	enum := func(key string, p *string) {
		t[key] = func(v []rune) (string, int) {
			switch string(v) {
			case Justify, Left, Right, Center:
				*p = string(v)
				return "", 0
			}
			return diag.BadEnum, 0
		}
	}
	family := func(key string, p *string) {
		t[key] = func(v []rune) (string, int) {
			switch string(v) {
			case "serif", "sans", "mono":
				*p = string(v)
				return "", 0
			}
			return diag.UnknownFont, 0
		}
	}
	// plain text: no placeholders allowed; check receives the unescaped text.
	plain := func(key string, p *string, check func(string) bool) {
		t[key] = func(v []rune) (string, int) {
			tpl, code, off := parseText(v)
			if code != "" {
				return code, off
			}
			if tpl.HasPlaceholder() {
				return diag.BadValue, 0
			}
			lit := tpl.Literal()
			if check != nil && !check(lit) {
				return diag.BadValue, 0
			}
			*p = lit
			return "", 0
		}
	}
	slot := func(key string, p *Template) {
		t[key] = func(v []rune) (string, int) {
			tpl, code, off := parseText(v)
			if code != "" {
				return code, off
			}
			*p = tpl
			return "", 0
		}
	}

	length("page-width", &s.PageWidth, 36000, inf)
	length("page-height", &s.PageHeight, 36000, inf)
	length("margin-top", &s.MarginTop, 0, inf)
	length("margin-bottom", &s.MarginBottom, 0, inf)
	length("margin-left", &s.MarginLeft, 0, inf)
	length("margin-right", &s.MarginRight, 0, inf)
	length("header-baseline", &s.HeaderBaseline, 0, inf)
	length("footer-baseline", &s.FooterBaseline, 0, inf)
	integer("page-start", &s.PageStart, 1, 3000)

	family("body-font", &s.BodyFont)
	length("body-size", &s.BodySize, 1000, 200000)
	length("leading", &s.Leading, 1000, inf)
	length("line-skip", &s.LineSkip, 0, inf)
	enum("align", &s.Align)
	length("par-indent", &s.ParIndent, 0, inf)
	length("par-space", &s.ParSpace, 0, inf)

	integer("tolerance", &s.Tolerance, 0, 10000)
	integer("line-penalty", &s.LinePenalty, 0, 10000)
	integer("hyphen-penalty", &s.HyphenPenalty, -9999, 9999)
	integer("ex-hyphen-penalty", &s.ExHyphenPenalty, -9999, 9999)
	integer("adj-demerits", &s.AdjDemerits, 0, 1000000)
	integer("double-hyphen-demerits", &s.DoubleHyphenDemerits, 0, 1000000)
	integer("final-hyphen-demerits", &s.FinalHyphenDemerits, 0, 1000000)
	integer("ragged-stretch", &s.RaggedStretch, 0, 100)
	boolean("hyphenate", &s.Hyphenate)
	t["hyphen-patterns"] = func(v []rune) (string, int) {
		switch string(v) {
		case "english", "minimal":
			s.HyphenPatterns = string(v)
			return "", 0
		}
		return diag.UnknownPatterns, 0
	}

	family("heading-font", &s.HeadingFont)
	boolean("heading-bold", &s.HeadingBold)
	boolean("heading-italic", &s.HeadingItalic)
	enum("heading-align", &s.HeadingAlign)
	boolean("heading-number", &s.HeadingNumber)
	length("heading-number-gap", &s.HeadingNumberGap, 0, inf)
	boolean("h1-newpage", &s.H1Newpage)
	for i := 0; i < 4; i++ {
		n := string(rune('1' + i))
		length("h"+n+"-size", &s.HSize[i], 1000, 200000)
		length("h"+n+"-leading", &s.HLeading[i], 1000, inf)
		length("h"+n+"-space-before", &s.HSpaceBefore[i], 0, inf)
		length("h"+n+"-space-after", &s.HSpaceAfter[i], 0, inf)
	}

	length("list-indent", &s.ListIndent, 0, inf)
	length("list-marker-gap", &s.ListMarkerGap, 0, inf)
	length("list-space", &s.ListSpace, 0, inf)
	length("list-item-space", &s.ListItemSpace, 0, inf)
	length("quote-indent", &s.QuoteIndent, 0, inf)
	length("quote-space", &s.QuoteSpace, 0, inf)
	family("pre-font", &s.PreFont)
	length("pre-size", &s.PreSize, 1000, 200000)
	length("pre-leading", &s.PreLeading, 1000, inf)
	length("pre-indent", &s.PreIndent, 0, inf)
	length("pre-space", &s.PreSpace, 0, inf)

	length("table-col-gap", &s.TableColGap, 0, inf)
	length("table-row-space", &s.TableRowSpace, 0, inf)
	length("table-rule-space", &s.TableRuleSpace, 0, inf)
	length("table-rule-thickness", &s.TableRuleThickness, 1, inf)
	length("table-space", &s.TableSpace, 0, inf)
	length("table-leading", &s.TableLeading, 1000, inf)
	length("rule-thickness", &s.RuleThickness, 1, inf)
	length("rule-space", &s.RuleSpace, 0, inf)

	family("footnote-font", &s.FootnoteFont)
	length("footnote-size", &s.FootnoteSize, 1000, 200000)
	length("footnote-leading", &s.FootnoteLeading, 1000, inf)
	length("footnote-indent", &s.FootnoteIndent, 0, inf)
	length("footnote-mark-gap", &s.FootnoteMarkGap, 0, inf)
	length("footnote-mark-size", &s.FootnoteMarkSize, 1000, 200000)
	length("footnote-mark-raise", &s.FootnoteMarkRaise, 0, inf)
	length("footnote-item-space", &s.FootnoteItemSpace, 0, inf)
	length("footnote-rule-width", &s.FootnoteRuleWidth, 0, inf)
	length("footnote-rule-thickness", &s.FootnoteRuleThickness, 1, inf)
	length("footnote-space-before", &s.FootnoteSpaceBefore, 0, inf)
	length("footnote-space-after", &s.FootnoteSpaceAfter, 0, inf)
	integer("footnote-min-split", &s.FootnoteMinSplit, 1, 100)
	length("footnote-max-height", &s.FootnoteMaxHeight, 1000, inf)
	length("mark-size", &s.MarkSize, 1000, 200000)
	length("mark-raise", &s.MarkRaise, 0, inf)

	length("figure-width", &s.FigureWidth, 0, inf)
	boolean("figure-frame", &s.FigureFrame)
	family("figure-caption-font", &s.FigureCaptionFont)
	length("figure-caption-size", &s.FigureCaptionSize, 1000, 200000)
	length("figure-caption-leading", &s.FigureCaptionLeading, 1000, inf)
	enum("figure-caption-align", &s.FigureCaptionAlign)
	length("figure-caption-space", &s.FigureCaptionSpace, 0, inf)
	plain("figure-caption-prefix", &s.FigureCaptionPrefix, nil)
	length("figure-caption-gap", &s.FigureCaptionGap, 0, inf)
	length("float-space-after", &s.FloatSpaceAfter, 0, inf)
	length("float-min-body", &s.FloatMinBody, 0, inf)

	integer("widows", &s.Widows, 1, 20)
	integer("orphans", &s.Orphans, 1, 20)
	boolean("keep-with-next", &s.KeepWithNext)

	integer("toc-depth", &s.TocDepth, 0, 4)
	family("toc-font", &s.TocFont)
	length("toc-size", &s.TocSize, 1000, 200000)
	length("toc-leading", &s.TocLeading, 1000, inf)
	length("toc-indent", &s.TocIndent, 0, inf)
	length("toc-number-gap", &s.TocNumberGap, 0, inf)
	length("toc-reserve", &s.TocReserve, 0, inf)
	plain("toc-leader", &s.TocLeader, func(lit string) bool {
		n := utf8.RuneCountInString(lit)
		return n >= 1 && n <= 8 && !strings.Contains(lit, " ")
	})
	length("toc-leader-gap", &s.TocLeaderGap, 0, inf)
	length("toc-entry-space", &s.TocEntrySpace, 0, inf)
	plain("toc-title", &s.TocTitle, nil)
	family("toc-title-font", &s.TocTitleFont)
	length("toc-title-size", &s.TocTitleSize, 1000, 200000)
	length("toc-title-space-after", &s.TocTitleSpaceAfter, 0, inf)

	family("header-font", &s.HeaderFont)
	length("header-size", &s.HeaderSize, 1000, 200000)
	for i := 0; i < NumSlots; i++ {
		slot(slotKeys[i], &s.Slots[0][i])
		slot(evenKeys[i], &s.Slots[1][i])
	}
	return t
}

var placeholders = map[string]bool{
	"page": true, "pages": true, "title": true, "author": true,
	"date": true, "chapter": true, "section": true,
}

// parseText scans a text value in a single left-to-right pass. On error it
// returns the code and the rune offset of the offending character.
func parseText(v []rune) (Template, string, int) {
	var tpl Template
	var lit []rune
	flush := func() {
		if len(lit) > 0 {
			tpl = append(tpl, TemplatePart{Literal: string(lit)})
			lit = lit[:0]
		}
	}
	for i := 0; i < len(v); i++ {
		c := v[i]
		switch c {
		case '\\':
			if i+1 < len(v) && (v[i+1] == '{' || v[i+1] == '}' || v[i+1] == '\\') {
				lit = append(lit, v[i+1])
				i++
			} else {
				return nil, diag.BadEscape, i
			}
		case '{':
			end := -1
			for j := i + 1; j < len(v); j++ {
				if v[j] == '}' {
					end = j
					break
				}
			}
			if end < 0 || !placeholders[string(v[i+1:end])] {
				return nil, diag.UnknownPlaceholder, i
			}
			flush()
			tpl = append(tpl, TemplatePart{Placeholder: string(v[i+1 : end])})
			i = end
		case '}':
			return nil, diag.StrayBrace, i
		default:
			lit = append(lit, c)
		}
	}
	flush()
	return tpl, "", 0
}
