// Package settings parses settings.cfg and holds the resolved layout
// settings, with every default, range and derived value of the specification.
package settings

import (
	"strings"

	"typeset/diag"
	"typeset/metrics"
	"typeset/units"
)

// Alignment values.
const (
	Justify = iota
	Left
	Right
	Center
)

// TextPart is one piece of a text-valued setting: a literal run, or a
// placeholder name such as "page".
type TextPart struct {
	Lit         string
	Placeholder string // non-empty for a {name} placeholder
}

// Text is a parsed text setting.
type Text []TextPart

// Literal returns the concatenation of the literal parts.
func (t Text) Literal() string {
	var sb strings.Builder
	for _, p := range t {
		sb.WriteString(p.Lit)
	}
	return sb.String()
}

// Settings is the complete set of layout settings. Lengths are millipoints.
type Settings struct {
	// Page geometry.
	PageWidth, PageHeight                            int64
	MarginTop, MarginBottom, MarginLeft, MarginRight int64
	HeaderBaseline, FooterBaseline                   int64
	PageStart                                        int64

	// Body text.
	BodyFont                    int
	BodySize, Leading, LineSkip int64
	Align                       int
	ParIndent, ParSpace         int64

	// Line breaking.
	Tolerance, LinePenalty, HyphenPenalty, ExHyphenPenalty int64
	AdjDemerits, DoubleHyphenDemerits, FinalHyphenDemerits int64
	RaggedStretch                                          int64
	Hyphenate                                              bool
	HyphenPatterns                                         string

	// Headings.
	HeadingFont      int
	HeadingBold      bool
	HeadingItalic    bool
	HeadingAlign     int
	HeadingNumber    bool
	HeadingNumberGap int64
	H1Newpage        bool
	HSize, HLeading  [4]int64
	HSpaceBefore     [4]int64
	HSpaceAfter      [4]int64

	// Lists, quotes, preformatted text.
	ListIndent, ListMarkerGap, ListSpace, ListItemSpace int64
	QuoteIndent, QuoteSpace                             int64
	PreFont                                             int
	PreSize, PreLeading, PreIndent, PreSpace            int64

	// Tables and rules.
	TableColGap, TableRowSpace, TableRuleSpace, TableRuleThickness int64
	TableSpace, TableLeading, RuleThickness, RuleSpace             int64

	// Footnotes.
	FootnoteFont                                            int
	FootnoteSize, FootnoteLeading, FootnoteIndent           int64
	FootnoteMarkGap, FootnoteMarkSize, FootnoteMarkRaise    int64
	FootnoteItemSpace, FootnoteRuleWidth, FootnoteRuleThick int64
	FootnoteSpaceBefore, FootnoteSpaceAfter                 int64
	FootnoteMinSplit                                        int64
	FootnoteMaxHeight                                       int64
	MarkSize, MarkRaise                                     int64

	// Figures.
	FigureWidth                                     int64
	FigureFrame                                     bool
	FigureCaptionFont                               int
	FigureCaptionSize, FigureCaptionLeading         int64
	FigureCaptionAlign                              int
	FigureCaptionSpace                              int64
	FigureCaptionPrefix                             string
	FigureCaptionGap, FloatSpaceAfter, FloatMinBody int64

	// Page breaking.
	Widows, Orphans int64
	KeepWithNext    bool

	// Table of contents.
	TOCDepth                                     int64
	TOCFont                                      int
	TOCSize, TOCLeading, TOCIndent, TOCNumberGap int64
	TOCReserve                                   int64
	TOCLeader                                    string
	TOCLeaderGap, TOCEntrySpace                  int64
	TOCTitle                                     string
	TOCTitleFont                                 int
	TOCTitleSize, TOCTitleSpaceAfter             int64

	// Running headers and footers.
	HeaderFont int
	HeaderSize int64
	// Slots: header-left, -center, -right, footer-left, -center, -right,
	// each for odd pages (index 0) and even pages (index 1).
	Slots [2][6]Text
}

// Default returns the settings with every value at its default, except the
// derived ones (footer-baseline, footnote-max-height), which are fixed up by
// Finish.
func Default() *Settings {
	return &Settings{
		PageWidth: 612 * units.Pt, PageHeight: 792 * units.Pt,
		MarginTop: 72 * units.Pt, MarginBottom: 72 * units.Pt,
		MarginLeft: 72 * units.Pt, MarginRight: 72 * units.Pt,
		HeaderBaseline: 36 * units.Pt, PageStart: 1,

		BodyFont: metrics.Serif, BodySize: 10 * units.Pt, Leading: 12 * units.Pt,
		LineSkip: 1 * units.Pt, Align: Justify, ParIndent: 18 * units.Pt,

		Tolerance: 1000, LinePenalty: 10, HyphenPenalty: 50, ExHyphenPenalty: 50,
		AdjDemerits: 10000, DoubleHyphenDemerits: 10000, FinalHyphenDemerits: 5000,
		RaggedStretch: 3, Hyphenate: true, HyphenPatterns: "english",

		HeadingFont: metrics.Sans, HeadingBold: true, HeadingAlign: Left,
		HeadingNumber: true, HeadingNumberGap: 6 * units.Pt,
		HSize:        [4]int64{20 * units.Pt, 14 * units.Pt, 12 * units.Pt, 11 * units.Pt},
		HLeading:     [4]int64{24 * units.Pt, 17 * units.Pt, 14 * units.Pt, 13 * units.Pt},
		HSpaceBefore: [4]int64{18 * units.Pt, 14 * units.Pt, 12 * units.Pt, 11 * units.Pt},
		HSpaceAfter:  [4]int64{9 * units.Pt, 7 * units.Pt, 6 * units.Pt, 5 * units.Pt},

		ListIndent: 18 * units.Pt, ListMarkerGap: 4 * units.Pt, ListSpace: 6 * units.Pt,
		QuoteIndent: 18 * units.Pt, QuoteSpace: 6 * units.Pt,
		PreFont: metrics.Mono, PreSize: 9 * units.Pt, PreLeading: 11 * units.Pt,
		PreSpace: 6 * units.Pt,

		TableColGap: 8 * units.Pt, TableRowSpace: 2 * units.Pt, TableRuleSpace: 2 * units.Pt,
		TableRuleThickness: 400, TableSpace: 6 * units.Pt, TableLeading: 12 * units.Pt,
		RuleThickness: 500, RuleSpace: 6 * units.Pt,

		FootnoteFont: metrics.Serif, FootnoteSize: 8 * units.Pt, FootnoteLeading: 10 * units.Pt,
		FootnoteIndent: 10 * units.Pt, FootnoteMarkGap: 2 * units.Pt,
		FootnoteMarkSize: 6 * units.Pt, FootnoteMarkRaise: 2 * units.Pt,
		FootnoteItemSpace: 2 * units.Pt, FootnoteRuleWidth: 120 * units.Pt,
		FootnoteRuleThick: 400, FootnoteSpaceBefore: 6 * units.Pt,
		FootnoteSpaceAfter: 3 * units.Pt, FootnoteMinSplit: 1,
		MarkSize: 7 * units.Pt, MarkRaise: 3 * units.Pt,

		FigureFrame: true, FigureCaptionFont: metrics.Serif,
		FigureCaptionSize: 9 * units.Pt, FigureCaptionLeading: 11 * units.Pt,
		FigureCaptionAlign: Center, FigureCaptionSpace: 4 * units.Pt,
		FigureCaptionPrefix: "Figure", FigureCaptionGap: 4 * units.Pt,
		FloatSpaceAfter: 12 * units.Pt, FloatMinBody: 24 * units.Pt,

		Widows: 2, Orphans: 2, KeepWithNext: true,

		TOCDepth: 2, TOCFont: metrics.Serif, TOCSize: 10 * units.Pt, TOCLeading: 14 * units.Pt,
		TOCIndent: 18 * units.Pt, TOCNumberGap: 6 * units.Pt, TOCReserve: 30 * units.Pt,
		TOCLeader: ".", TOCLeaderGap: 3 * units.Pt, TOCTitle: "Contents",
		TOCTitleFont: metrics.Sans, TOCTitleSize: 20 * units.Pt, TOCTitleSpaceAfter: 12 * units.Pt,

		HeaderFont: metrics.Sans, HeaderSize: 9 * units.Pt,
	}
}

// BodyX, BodyY, BodyWidth, BodyHeight and BodyBottom give the body rectangle.
func (s *Settings) BodyX() int64      { return s.MarginLeft }
func (s *Settings) BodyY() int64      { return s.MarginTop }
func (s *Settings) BodyWidth() int64  { return s.PageWidth - s.MarginLeft - s.MarginRight }
func (s *Settings) BodyHeight() int64 { return s.PageHeight - s.MarginTop - s.MarginBottom }
func (s *Settings) BodyBottom() int64 { return s.BodyY() + s.BodyHeight() }

type kind int

const (
	kLength kind = iota
	kInt
	kBool
	kEnum
	kFamily
	kPatterns
	kText
	kString // text restricted to literals (no placeholders)
)

var alignWords = []string{"justify", "left", "right", "center"}

// Placeholders recognised in header/footer text.
var placeholders = map[string]bool{"page": true, "pages": true, "title": true,
	"author": true, "date": true, "chapter": true, "section": true}

type def struct {
	key    string
	kind   kind
	lo, hi int64
	ip     *int64
	bp     *bool
	enum   *int // enum / family result
	sp     *string
	tp     *Text
	check  func(v string, t Text) bool // extra range check for strings
}

const big = int64(1) << 60

func (s *Settings) table() []def {
	var d []def
	L := func(key string, p *int64, lo, hi int64) {
		d = append(d, def{key: key, kind: kLength, lo: lo, hi: hi, ip: p})
	}
	I := func(key string, p *int64, lo, hi int64) {
		d = append(d, def{key: key, kind: kInt, lo: lo, hi: hi, ip: p})
	}
	B := func(key string, p *bool) { d = append(d, def{key: key, kind: kBool, bp: p}) }
	A := func(key string, p *int) { d = append(d, def{key: key, kind: kEnum, enum: p}) }
	F := func(key string, p *int) { d = append(d, def{key: key, kind: kFamily, enum: p}) }
	T := func(key string, p *Text) { d = append(d, def{key: key, kind: kText, tp: p}) }
	S := func(key string, p *string, check func(string, Text) bool) {
		d = append(d, def{key: key, kind: kString, sp: p, check: check})
	}
	sizeLo, sizeHi := int64(1000), int64(200000)

	L("page-width", &s.PageWidth, 36000, big)
	L("page-height", &s.PageHeight, 36000, big)
	L("margin-top", &s.MarginTop, 0, big)
	L("margin-bottom", &s.MarginBottom, 0, big)
	L("margin-left", &s.MarginLeft, 0, big)
	L("margin-right", &s.MarginRight, 0, big)
	L("header-baseline", &s.HeaderBaseline, 0, big)
	L("footer-baseline", &s.FooterBaseline, 0, big)
	I("page-start", &s.PageStart, 1, 3000)

	F("body-font", &s.BodyFont)
	L("body-size", &s.BodySize, sizeLo, sizeHi)
	L("leading", &s.Leading, 1000, big)
	L("line-skip", &s.LineSkip, 0, big)
	A("align", &s.Align)
	L("par-indent", &s.ParIndent, 0, big)
	L("par-space", &s.ParSpace, 0, big)

	I("tolerance", &s.Tolerance, 0, 10000)
	I("line-penalty", &s.LinePenalty, 0, 10000)
	I("hyphen-penalty", &s.HyphenPenalty, -9999, 9999)
	I("ex-hyphen-penalty", &s.ExHyphenPenalty, -9999, 9999)
	I("adj-demerits", &s.AdjDemerits, 0, 1000000)
	I("double-hyphen-demerits", &s.DoubleHyphenDemerits, 0, 1000000)
	I("final-hyphen-demerits", &s.FinalHyphenDemerits, 0, 1000000)
	I("ragged-stretch", &s.RaggedStretch, 0, 100)
	B("hyphenate", &s.Hyphenate)
	d = append(d, def{key: "hyphen-patterns", kind: kPatterns, sp: &s.HyphenPatterns})

	F("heading-font", &s.HeadingFont)
	B("heading-bold", &s.HeadingBold)
	B("heading-italic", &s.HeadingItalic)
	A("heading-align", &s.HeadingAlign)
	B("heading-number", &s.HeadingNumber)
	L("heading-number-gap", &s.HeadingNumberGap, 0, big)
	B("h1-newpage", &s.H1Newpage)
	for i := 0; i < 4; i++ {
		n := string(rune('1' + i))
		L("h"+n+"-size", &s.HSize[i], sizeLo, sizeHi)
	}
	for i := 0; i < 4; i++ {
		L("h"+string(rune('1'+i))+"-leading", &s.HLeading[i], 1000, big)
	}
	for i := 0; i < 4; i++ {
		L("h"+string(rune('1'+i))+"-space-before", &s.HSpaceBefore[i], 0, big)
	}
	for i := 0; i < 4; i++ {
		L("h"+string(rune('1'+i))+"-space-after", &s.HSpaceAfter[i], 0, big)
	}

	L("list-indent", &s.ListIndent, 0, big)
	L("list-marker-gap", &s.ListMarkerGap, 0, big)
	L("list-space", &s.ListSpace, 0, big)
	L("list-item-space", &s.ListItemSpace, 0, big)
	L("quote-indent", &s.QuoteIndent, 0, big)
	L("quote-space", &s.QuoteSpace, 0, big)
	F("pre-font", &s.PreFont)
	L("pre-size", &s.PreSize, sizeLo, sizeHi)
	L("pre-leading", &s.PreLeading, 1000, big)
	L("pre-indent", &s.PreIndent, 0, big)
	L("pre-space", &s.PreSpace, 0, big)

	L("table-col-gap", &s.TableColGap, 0, big)
	L("table-row-space", &s.TableRowSpace, 0, big)
	L("table-rule-space", &s.TableRuleSpace, 0, big)
	L("table-rule-thickness", &s.TableRuleThickness, 1, big)
	L("table-space", &s.TableSpace, 0, big)
	L("table-leading", &s.TableLeading, 1000, big)
	L("rule-thickness", &s.RuleThickness, 1, big)
	L("rule-space", &s.RuleSpace, 0, big)

	F("footnote-font", &s.FootnoteFont)
	L("footnote-size", &s.FootnoteSize, sizeLo, sizeHi)
	L("footnote-leading", &s.FootnoteLeading, 1000, big)
	L("footnote-indent", &s.FootnoteIndent, 0, big)
	L("footnote-mark-gap", &s.FootnoteMarkGap, 0, big)
	L("footnote-mark-size", &s.FootnoteMarkSize, sizeLo, sizeHi)
	L("footnote-mark-raise", &s.FootnoteMarkRaise, 0, big)
	L("footnote-item-space", &s.FootnoteItemSpace, 0, big)
	L("footnote-rule-width", &s.FootnoteRuleWidth, 0, big)
	L("footnote-rule-thickness", &s.FootnoteRuleThick, 1, big)
	L("footnote-space-before", &s.FootnoteSpaceBefore, 0, big)
	L("footnote-space-after", &s.FootnoteSpaceAfter, 0, big)
	I("footnote-min-split", &s.FootnoteMinSplit, 1, 100)
	L("footnote-max-height", &s.FootnoteMaxHeight, 1000, big)
	L("mark-size", &s.MarkSize, sizeLo, sizeHi)
	L("mark-raise", &s.MarkRaise, 0, big)

	L("figure-width", &s.FigureWidth, 0, big)
	B("figure-frame", &s.FigureFrame)
	F("figure-caption-font", &s.FigureCaptionFont)
	L("figure-caption-size", &s.FigureCaptionSize, sizeLo, sizeHi)
	L("figure-caption-leading", &s.FigureCaptionLeading, 1000, big)
	A("figure-caption-align", &s.FigureCaptionAlign)
	L("figure-caption-space", &s.FigureCaptionSpace, 0, big)
	S("figure-caption-prefix", &s.FigureCaptionPrefix, nil)
	L("figure-caption-gap", &s.FigureCaptionGap, 0, big)
	L("float-space-after", &s.FloatSpaceAfter, 0, big)
	L("float-min-body", &s.FloatMinBody, 0, big)

	I("widows", &s.Widows, 1, 20)
	I("orphans", &s.Orphans, 1, 20)
	B("keep-with-next", &s.KeepWithNext)

	I("toc-depth", &s.TOCDepth, 0, 4)
	F("toc-font", &s.TOCFont)
	L("toc-size", &s.TOCSize, sizeLo, sizeHi)
	L("toc-leading", &s.TOCLeading, 1000, big)
	L("toc-indent", &s.TOCIndent, 0, big)
	L("toc-number-gap", &s.TOCNumberGap, 0, big)
	L("toc-reserve", &s.TOCReserve, 0, big)
	S("toc-leader", &s.TOCLeader, func(v string, _ Text) bool {
		n := len([]rune(v))
		return n >= 1 && n <= 8 && !strings.ContainsRune(v, ' ')
	})
	L("toc-leader-gap", &s.TOCLeaderGap, 0, big)
	L("toc-entry-space", &s.TOCEntrySpace, 0, big)
	S("toc-title", &s.TOCTitle, nil)
	F("toc-title-font", &s.TOCTitleFont)
	L("toc-title-size", &s.TOCTitleSize, sizeLo, sizeHi)
	L("toc-title-space-after", &s.TOCTitleSpaceAfter, 0, big)

	F("header-font", &s.HeaderFont)
	L("header-size", &s.HeaderSize, sizeLo, sizeHi)
	names := []string{"header-left", "header-center", "header-right", "footer-left", "footer-center", "footer-right"}
	for i, n := range names {
		T(n, &s.Slots[0][i])
		T(n+"-even", &s.Slots[1][i])
	}
	return d
}

// Parse parses the text of a settings.cfg. A nil data means "absent". The
// returned settings are complete (defaults and derived values applied).
func Parse(data []byte) (*Settings, *diag.Error) {
	s := Default()
	defs := s.table()
	byKey := make(map[string]*def, len(defs))
	for i := range defs {
		byKey[defs[i].key] = &defs[i]
	}
	assigned := map[string]bool{}
	var geomLine, geomCol int // position of the last explicit geometry key
	geomKeys := map[string]bool{"page-width": true, "page-height": true,
		"margin-top": true, "margin-bottom": true, "margin-left": true, "margin-right": true}

	text := string(data)
	lines := strings.Split(text, "\n")
	if len(lines) > 0 && lines[len(lines)-1] == "" {
		lines = lines[:len(lines)-1]
	}
	for ln, raw := range lines {
		line := []rune(raw)
		fail := func(col int, code string) *diag.Error { return diag.New("settings.cfg", ln+1, col, code) }
		i := 0
		for i < len(line) && (line[i] == ' ' || line[i] == '\t') {
			i++
		}
		if i == len(line) || line[i] == '#' {
			continue
		}
		first := i
		ks := i
		for i < len(line) && (line[i] >= 'a' && line[i] <= 'z' || line[i] >= '0' && line[i] <= '9' || line[i] == '-') {
			i++
		}
		key := string(line[ks:i])
		for i < len(line) && (line[i] == ' ' || line[i] == '\t') {
			i++
		}
		if key == "" || i >= len(line) || line[i] != '=' {
			return nil, fail(first+1, "bad-syntax")
		}
		i++
		vs := i
		for vs < len(line) && (line[vs] == ' ' || line[vs] == '\t') {
			vs++
		}
		ve := len(line)
		for ve > vs && (line[ve-1] == ' ' || line[ve-1] == '\t') {
			ve--
		}
		valCol := vs + 1
		if vs >= len(line) {
			valCol = len(line) + 1
		}
		value := string(line[vs:ve])
		d, ok := byKey[key]
		if !ok {
			return nil, fail(ks+1, "unknown-setting")
		}
		if assigned[key] {
			return nil, fail(ks+1, "duplicate-setting")
		}
		if code, col := d.assign(value, valCol); code != "" {
			return nil, fail(col, code)
		}
		assigned[key] = true
		if geomKeys[key] {
			geomLine, geomCol = ln+1, valCol
		}
	}

	// Derived defaults.
	if !assigned["footer-baseline"] {
		s.FooterBaseline = s.PageHeight - 36*units.Pt
	}
	if s.BodyWidth() < 36000 || s.BodyHeight() < 36000 {
		return nil, diag.New("settings.cfg", geomLine, geomCol, "bad-value")
	}
	if !assigned["footnote-max-height"] {
		s.FootnoteMaxHeight = units.FloorDiv(s.BodyHeight(), 2)
	}
	for i := 0; i < 6; i++ {
		names := []string{"header-left", "header-center", "header-right", "footer-left", "footer-center", "footer-right"}
		if !assigned[names[i]+"-even"] {
			s.Slots[1][i] = s.Slots[0][i]
		}
	}
	return s, nil
}

// assign parses and range-checks one value; it returns an error code and the
// column to report it at, or "" on success.
func (d *def) assign(v string, valCol int) (string, int) {
	switch d.kind {
	case kLength, kInt:
		var x int64
		var ok bool
		if d.kind == kLength {
			x, ok = units.ParseLength(v)
		} else {
			x, ok = units.ParseInt(v)
		}
		if !ok {
			if d.kind == kLength {
				return "bad-length", valCol
			}
			return "bad-integer", valCol
		}
		if x < d.lo || x > d.hi {
			return "bad-value", valCol
		}
		*d.ip = x
	case kBool:
		switch v {
		case "on":
			*d.bp = true
		case "off":
			*d.bp = false
		default:
			return "bad-boolean", valCol
		}
	case kEnum:
		for i, w := range alignWords {
			if v == w {
				*d.enum = i
				return "", 0
			}
		}
		return "bad-enum", valCol
	case kFamily:
		switch v {
		case "serif":
			*d.enum = metrics.Serif
		case "sans":
			*d.enum = metrics.Sans
		case "mono":
			*d.enum = metrics.Mono
		default:
			return "unknown-font", valCol
		}
	case kPatterns:
		if v != "english" && v != "minimal" {
			return "unknown-patterns", valCol
		}
		*d.sp = v
	case kText, kString:
		t, code, off := parseText(v)
		if code != "" {
			return code, valCol + off
		}
		if d.kind == kText {
			*d.tp = t
			return "", 0
		}
		for _, p := range t {
			if p.Placeholder != "" {
				return "bad-value", valCol
			}
		}
		lv := t.Literal()
		if d.check != nil && !d.check(lv, t) {
			return "bad-value", valCol
		}
		*d.sp = lv
	}
	return "", 0
}

// parseText scans a text value in one left-to-right pass. On error it
// returns the code and the rune offset of the offending character.
func parseText(v string) (Text, string, int) {
	r := []rune(v)
	var out Text
	var cur []rune
	flush := func() {
		if len(cur) > 0 {
			out = append(out, TextPart{Lit: string(cur)})
			cur = nil
		}
	}
	for i := 0; i < len(r); i++ {
		switch c := r[i]; c {
		case '\\':
			if i+1 < len(r) && (r[i+1] == '{' || r[i+1] == '}' || r[i+1] == '\\') {
				cur = append(cur, r[i+1])
				i++
			} else {
				return nil, "bad-escape", i
			}
		case '{':
			j := i + 1
			for j < len(r) && r[j] != '}' {
				j++
			}
			if j >= len(r) || !placeholders[string(r[i+1:j])] {
				return nil, "unknown-placeholder", i
			}
			flush()
			out = append(out, TextPart{Placeholder: string(r[i+1 : j])})
			i = j
		case '}':
			return nil, "stray-brace", i
		default:
			cur = append(cur, c)
		}
	}
	flush()
	return out, "", 0
}
