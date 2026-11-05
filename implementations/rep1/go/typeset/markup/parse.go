package markup

import (
	"strings"

	"typeset/diag"
	"typeset/units"
)

type frameKind int

const (
	fDoc frameKind = iota
	fQuote
	fGroup
	fList
	fItem
	fTable
	fPre
	fFig
)

type frame struct {
	kind   frameKind
	blocks *[]Block // where child blocks go (quote, group, item)
	list   *List
	item   *Item
	table  *Table
	pre    *Pre
	fig    *Figure
	seen   map[string]bool // @doc keys
	cap    []textLine      // @fig caption lines
}

type pendKind int

const (
	pPara pendKind = iota
	pItem
)

type pending struct {
	kind  pendKind
	item  *Item
	lines []textLine
}

type parser struct {
	lines    [][]rune
	doc      *Document
	styleIdx map[Style]int32
	stack    []*frame
	pend     *pending
	topCount int
	seenDoc  bool
	seenTOC  bool
}

// Parse parses a Codexa document. On invalid input it returns the first
// error, located in document.cdx.
func Parse(data []byte) (doc *Document, err *diag.Error) {
	p := &parser{doc: &Document{}, styleIdx: map[Style]int32{}}
	p.styleID(Style{}) // style 0 is the plain style
	text := string(data)
	for _, l := range strings.Split(text, "\n") {
		p.lines = append(p.lines, []rune(l))
	}
	if n := len(p.lines); n > 0 && len(p.lines[n-1]) == 0 {
		p.lines = p.lines[:n-1]
	}
	defer func() {
		if r := recover(); r != nil {
			if e, ok := r.(*diag.Error); ok {
				doc, err = nil, e
				return
			}
			panic(r)
		}
	}()
	p.run()
	return p.doc, nil
}

func (p *parser) fail(line, col int, code string) {
	panic(diag.New("document.cdx", line, col, code))
}

func (p *parser) top() *frame {
	if len(p.stack) == 0 {
		return nil
	}
	return p.stack[len(p.stack)-1]
}

// sink returns the block list that receives new blocks.
func (p *parser) sink() *[]Block {
	if t := p.top(); t != nil {
		return t.blocks
	}
	return &p.doc.Blocks
}

func (p *parser) add(b Block) {
	if len(p.stack) == 0 {
		p.topCount++
	}
	s := p.sink()
	*s = append(*s, b)
}

func isBlank(l []rune) bool {
	for _, r := range l {
		if r != ' ' {
			return false
		}
	}
	return true
}

func (p *parser) run() {
	for idx := 0; idx < len(p.lines); idx++ {
		ln := idx + 1
		line := p.lines[idx]
		if t := p.top(); t != nil && t.kind == fPre {
			if trimSpaces(line) == "@end" {
				p.stack = p.stack[:len(p.stack)-1]
				continue
			}
			t.pre.Lines = append(t.pre.Lines, strings.TrimRight(string(line), " "))
			continue
		}
		if isBlank(line) {
			p.flush()
			continue
		}
		first := 0
		for line[first] == ' ' {
			first++
		}
		if line[first] == '@' {
			p.flush()
			p.directive(ln, line, first)
		} else {
			p.textLine(ln, line, first)
		}
	}
	p.flush()
	if len(p.stack) > 0 {
		p.fail(len(p.lines)+1, 1, "missing-end")
	}
}

func trimSpaces(l []rune) string { return strings.Trim(string(l), " ") }

// flush scans and emits the pending paragraph or item text.
func (p *parser) flush() {
	pd := p.pend
	if pd == nil {
		return
	}
	p.pend = nil
	units := p.scan(join(pd.lines), true)
	switch pd.kind {
	case pPara:
		p.doc.Paragraphs++
		p.add(&Paragraph{Text: units})
	case pItem:
		pd.item.Text = units
	}
}

func (p *parser) textLine(ln int, line []rune, first int) {
	t := p.top()
	switch {
	case t != nil && t.kind == fDoc:
		p.metaLine(ln, line, first)
	case t != nil && t.kind == fTable:
		p.tableRow(ln, line, first)
	case t != nil && t.kind == fFig:
		t.cap = append(t.cap, newTextLine(line, ln, 0))
	case t != nil && t.kind == fList:
		p.fail(ln, first+1, "text-not-allowed")
	default:
		if p.pend == nil {
			if len(p.stack) == 0 {
				p.topCount++
			}
			p.pend = &pending{kind: pPara}
		}
		p.pend.lines = append(p.pend.lines, newTextLine(line, ln, 0))
	}
}

func (p *parser) metaLine(ln int, line []rune, first int) {
	i := first
	for i < len(line) && (line[i] >= 'a' && line[i] <= 'z' || line[i] >= '0' && line[i] <= '9' || line[i] == '-') {
		i++
	}
	key := string(line[first:i])
	for i < len(line) && line[i] == ' ' {
		i++
	}
	if key == "" || i >= len(line) || line[i] != '=' {
		p.fail(ln, first+1, "bad-syntax")
	}
	val := strings.Trim(string(line[i+1:]), " ")
	t := p.top()
	switch key {
	case "title", "author", "date":
	default:
		p.fail(ln, first+1, "unknown-meta")
	}
	if t.seen[key] {
		p.fail(ln, first+1, "duplicate-meta")
	}
	t.seen[key] = true
	switch key {
	case "title":
		p.doc.Meta.Title = val
	case "author":
		p.doc.Meta.Author = val
	case "date":
		p.doc.Meta.Date = val
	}
}

// tableRow splits a row into cells before parsing any inline content.
func (p *parser) tableRow(ln int, line []rune, first int) {
	t := p.top()
	var cells [][2]int // [start, end) rune offsets in line
	start := first
	for i := first; i < len(line); i++ {
		switch line[i] {
		case '\\':
			i++
		case '|':
			cells = append(cells, [2]int{start, i})
			start = i + 1
		}
	}
	cells = append(cells, [2]int{start, len(line)})
	if len(cells) != t.table.Cols {
		p.fail(ln, 1, "cell-count")
	}
	row := TableElem{}
	for _, c := range cells {
		var s srcText
		for k := c[0]; k < c[1]; k++ {
			s.add(line[k], ln, k+1)
		}
		row.Cells = append(row.Cells, p.scan(s, false))
	}
	t.table.Elems = append(t.table.Elems, row)
}

// ---- directives ----

type attr struct {
	name, val       string
	quoted          bool
	nameCol, valCol int // 1-based
}

type attrSpec struct {
	name     string
	required bool
	check    func(v string) bool
}

type dirSpec struct {
	attrs []attrSpec
}

func lengthAtLeast(lo int64) func(string) bool {
	return func(v string) bool {
		x, ok := units.ParseLength(v)
		return ok && x >= lo
	}
}

func lengthRange(lo, hi int64) func(string) bool {
	return func(v string) bool {
		x, ok := units.ParseLength(v)
		return ok && x >= lo && x <= hi
	}
}

func intRange(lo, hi int64) func(string) bool {
	return func(v string) bool {
		if len(v) > 0 && v[0] == '-' {
			return false
		}
		x, ok := units.ParseInt(v)
		return ok && x >= lo && x <= hi
	}
}

var alignWords = []string{"justify", "left", "right", "center"}
var fontWords = []string{"serif", "sans", "mono"}

func oneOf(words []string) func(string) bool {
	return func(v string) bool {
		for _, w := range words {
			if v == w {
				return true
			}
		}
		return false
	}
}

func anyValue(string) bool { return true }

func tableAlign(v string) bool {
	for _, r := range v {
		if r != 'l' && r != 'r' && r != 'c' {
			return false
		}
	}
	return true
}

var dirSpecs = map[string]*dirSpec{
	"@doc":     {},
	"@toc":     {attrs: []attrSpec{{"title", false, anyValue}}},
	"@q":       {},
	"@block":   {attrs: []attrSpec{{"align", false, oneOf(alignWords)}, {"indent", false, lengthAtLeast(0)}, {"right-indent", false, lengthAtLeast(0)}, {"font", false, oneOf(fontWords)}, {"size", false, lengthRange(1000, 200000)}, {"leading", false, lengthAtLeast(1000)}}},
	"@ul":      {},
	"@ol":      {attrs: []attrSpec{{"start", false, intRange(1, 100000)}}},
	"@table":   {attrs: []attrSpec{{"cols", true, intRange(1, 20)}, {"align", false, tableAlign}}},
	"@hrule":   {},
	"@pre":     {},
	"@fig":     {attrs: []attrSpec{{"height", true, lengthAtLeast(0)}, {"width", false, lengthAtLeast(0)}}},
	"@rule":    {},
	"@vspace":  {attrs: []attrSpec{{"height", true, lengthAtLeast(0)}}},
	"@newpage": {},
	"@end":     {},
	"@li":      {},
	"@h1":      {}, "@h2": {}, "@h3": {}, "@h4": {},
	"@h1*": {}, "@h2*": {}, "@h3*": {}, "@h4*": {},
}

func isAttrNameChar(r rune) bool {
	return r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || r == '-'
}

func isBareChar(r rune) bool {
	return isAttrNameChar(r) || r == '.' || r == '+' || r == '%'
}

// lexAttrs reads the attribute tokens of a directive line starting at i.
func (p *parser) lexAttrs(ln int, line []rune, i int, spec *dirSpec) []attr {
	var out []attr
	seen := map[string]bool{}
	for {
		for i < len(line) && line[i] == ' ' {
			i++
		}
		if i >= len(line) {
			return out
		}
		ts := i
		for i < len(line) && isAttrNameChar(line[i]) {
			i++
		}
		if i == ts || i >= len(line) || line[i] != '=' {
			p.fail(ln, ts+1, "bad-attribute")
		}
		name := string(line[ts:i])
		known := false
		for _, a := range spec.attrs {
			if a.name == name {
				known = true
			}
		}
		if !known || seen[name] {
			p.fail(ln, ts+1, "bad-attribute")
		}
		seen[name] = true
		i++
		vs := i
		a := attr{name: name, nameCol: ts + 1, valCol: vs + 1}
		if i < len(line) && line[i] == '"' {
			j := i + 1
			for j < len(line) && line[j] != '"' {
				j++
			}
			if j >= len(line) {
				p.fail(ln, vs+1, "bad-attribute-value")
			}
			a.val, a.quoted = string(line[i+1:j]), true
			i = j + 1
		} else {
			for i < len(line) && isBareChar(line[i]) {
				i++
			}
			if i == vs {
				p.fail(ln, vs+1, "bad-attribute-value")
			}
			a.val = string(line[vs:i])
		}
		if i < len(line) && line[i] != ' ' {
			p.fail(ln, vs+1, "bad-attribute-value")
		}
		out = append(out, a)
	}
}

func get(attrs []attr, name string) *attr {
	for i := range attrs {
		if attrs[i].name == name {
			return &attrs[i]
		}
	}
	return nil
}

func (p *parser) directive(ln int, line []rune, first int) {
	j := first
	for j < len(line) && line[j] != ' ' {
		j++
	}
	name := string(line[first:j])
	spec, ok := dirSpecs[name]
	if !ok {
		p.fail(ln, first+1, "unknown-block")
	}
	col := first + 1
	inlineRest := name == "@li" || (len(name) >= 3 && name[1] == 'h' && name[2] >= '1' && name[2] <= '4')
	var attrs []attr
	if !inlineRest {
		attrs = p.lexAttrs(ln, line, j, spec)
		for _, a := range spec.attrs {
			if a.required && get(attrs, a.name) == nil {
				p.fail(ln, col, "missing-attribute")
			}
		}
	}
	p.place(ln, col, name)
	for _, a := range attrs { // step 4: shapes and ranges, in source order
		for _, s := range spec.attrs {
			if s.name == a.name && !s.check(a.val) {
				p.fail(ln, a.valCol, "bad-attribute-value")
			}
		}
	}
	cols := 0
	if name == "@table" {
		cols = int(mustInt(get(attrs, "cols").val))
		if al := get(attrs, "align"); al != nil && len([]rune(al.val)) != cols {
			p.fail(ln, al.valCol, "bad-attribute-value")
		}
	}
	p.build(ln, line, j, name, attrs, cols)
}

func mustInt(s string) int64 {
	v, _ := units.ParseInt(s)
	return v
}

// place performs the placement checks (step 3).
func (p *parser) place(ln, col int, name string) {
	t := p.top()
	deny := func() { p.fail(ln, col, "block-not-allowed") }
	if name == "@end" {
		if t == nil {
			p.fail(ln, col, "unexpected-end")
		}
		return
	}
	if name == "@toc" && p.seenTOC {
		if t != nil && (t.kind == fDoc || t.kind == fTable || t.kind == fFig || t.kind == fList) {
			deny()
		}
		p.fail(ln, col, "duplicate-toc")
	}
	if t != nil {
		switch t.kind {
		case fDoc, fFig:
			deny()
		case fTable:
			if name != "@hrule" {
				deny()
			}
			return
		case fList:
			if name != "@li" {
				deny()
			}
			return
		}
	}
	switch name {
	case "@li":
		if t == nil || t.kind != fItem {
			deny()
		}
	case "@hrule":
		deny()
	case "@doc":
		if t != nil || p.topCount != 0 {
			deny()
		}
	case "@toc":
		if t != nil || !(p.topCount == 0 || p.topCount == 1 && p.seenDoc) {
			deny()
		}
	}
}

func (p *parser) push(f *frame) { p.stack = append(p.stack, f) }

func (p *parser) build(ln int, line []rune, j int, name string, attrs []attr, cols int) {
	switch name {
	case "@end":
		p.end(ln)
	case "@doc":
		p.topCount++
		p.seenDoc = true
		p.push(&frame{kind: fDoc, seen: map[string]bool{}})
	case "@toc":
		p.topCount++
		p.seenTOC = true
		p.doc.HasTOC = true
		if a := get(attrs, "title"); a != nil {
			p.doc.TOCTitle, p.doc.HasTOCTitle = a.val, true
		}
	case "@q":
		q := &Quote{}
		p.add(q)
		p.push(&frame{kind: fQuote, blocks: &q.Children})
	case "@block":
		g := &Group{}
		for _, a := range attrs {
			switch a.name {
			case "align":
				v := indexOf(alignWords, a.val)
				g.Align = &v
			case "indent":
				v, _ := units.ParseLength(a.val)
				g.Indent = &v
			case "right-indent":
				v, _ := units.ParseLength(a.val)
				g.RightIndent = &v
			case "font":
				v := indexOf(fontWords, a.val)
				g.Font = &v
			case "size":
				v, _ := units.ParseLength(a.val)
				g.Size = &v
			case "leading":
				v, _ := units.ParseLength(a.val)
				g.Leading = &v
			}
		}
		p.add(g)
		p.push(&frame{kind: fGroup, blocks: &g.Children})
	case "@ul", "@ol":
		l := &List{Ordered: name == "@ol", Start: 1}
		if a := get(attrs, "start"); a != nil {
			l.Start = int(mustInt(a.val))
		}
		p.add(l)
		p.push(&frame{kind: fList, list: l})
	case "@li":
		if t := p.top(); t.kind == fItem {
			p.stack = p.stack[:len(p.stack)-1]
		}
		list := p.top().list
		it := &Item{}
		list.Items = append(list.Items, it)
		p.push(&frame{kind: fItem, item: it, blocks: &it.Children})
		p.pend = &pending{kind: pItem, item: it, lines: []textLine{newTextLine(line, ln, j)}}
	case "@table":
		al := strings.Repeat("l", cols)
		if a := get(attrs, "align"); a != nil {
			al = a.val
		}
		t := &Table{Cols: cols, Align: al}
		p.doc.Tables++
		p.add(t)
		p.push(&frame{kind: fTable, table: t})
	case "@hrule":
		t := p.top().table
		t.Elems = append(t.Elems, TableElem{Rule: true})
	case "@pre":
		pr := &Pre{}
		p.add(pr)
		p.push(&frame{kind: fPre, pre: pr})
	case "@fig":
		f := &Figure{}
		f.Height, _ = units.ParseLength(get(attrs, "height").val)
		if a := get(attrs, "width"); a != nil {
			f.Width, _ = units.ParseLength(a.val)
			f.HasWidth = true
		}
		p.doc.Figures++
		p.add(f)
		p.push(&frame{kind: fFig, fig: f})
	case "@rule":
		p.add(&Rule{})
	case "@vspace":
		h, _ := units.ParseLength(get(attrs, "height").val)
		p.add(&VSpace{Height: h})
	case "@newpage":
		p.add(&NewPage{})
	default: // headings
		star := strings.HasSuffix(name, "*")
		level := int(name[2] - '0')
		h := &Heading{Level: level, Star: star}
		h.Text = p.scan(join([]textLine{newTextLine(line, ln, j)}), false)
		h.Plain = PlainText(h.Text)
		p.doc.Headings++
		p.add(h)
	}
}

func indexOf(words []string, w string) int {
	for i, x := range words {
		if x == w {
			return i
		}
	}
	return -1
}

// end closes the innermost open block.
func (p *parser) end(ln int) {
	t := p.top()
	if t.kind == fItem {
		p.stack = p.stack[:len(p.stack)-1]
		t = p.top()
	}
	p.stack = p.stack[:len(p.stack)-1]
	if t.kind == fFig {
		t.fig.Caption = p.scan(join(t.cap), false)
	}
}
