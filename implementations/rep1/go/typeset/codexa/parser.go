package codexa

import (
	"strings"

	"typeset/diag"
	"typeset/dim"
)

type frameKind uint8

const (
	fkDoc frameKind = iota
	fkQuote
	fkBlock
	fkList
	fkItem
	fkTable
	fkFig
)

// open is an open container on the block stack.
type open struct {
	kind     frameKind
	line     int
	children []Block // finished child blocks (quote, block, item)
	// per kind
	group *Group
	list  *List
	item  *Item
	table *Table
	fig   *Figure
	cap   text // figure caption text
	meta  map[string]bool
}

type pending struct {
	active bool
	item   bool // text belongs to an @li rather than a paragraph
	t      text
}

type parser struct {
	lines   []string
	doc     *Document
	sc      scanner
	stack   []*open
	pend    pending
	topSeen int  // top-level blocks started
	hasDoc  bool // the first block is @doc
	hasTOC  bool
	// preState
	inPre   bool
	pre     *Pre
	preLine int
}

// Parse parses a Codexa document. A nil *diag.Error means success.
func Parse(src []byte) (*Document, *diag.Error) {
	p := &parser{doc: &Document{}}
	p.sc.doc = p.doc
	s := string(src)
	lines := strings.Split(s, "\n")
	if n := len(lines); n > 0 && lines[n-1] == "" {
		lines = lines[:n-1]
	}
	p.lines = lines
	for i, l := range lines {
		if e := p.line(i+1, []rune(l)); e != nil {
			return nil, e
		}
	}
	if e := p.flush(); e != nil {
		return nil, e
	}
	if p.inPre || len(p.stack) > 0 {
		return nil, &diag.Error{File: File, Line: len(lines) + 1, Col: 1, Code: diag.MissingEnd}
	}
	return p.doc, nil
}

func (p *parser) errAt(line, col int, code string) *diag.Error {
	return &diag.Error{File: File, Line: line, Col: col, Code: code}
}

func (p *parser) top() *open {
	if len(p.stack) == 0 {
		return nil
	}
	return p.stack[len(p.stack)-1]
}

// emit adds a finished block to the innermost container.
func (p *parser) emit(b Block) {
	t := p.top()
	if t == nil {
		p.doc.Blocks = append(p.doc.Blocks, b)
		return
	}
	t.children = append(t.children, b)
}

// begin records that a block starts; only top-level blocks are counted.
func (p *parser) begin() {
	if len(p.stack) == 0 {
		p.topSeen++
	}
}

// flush scans and emits the pending paragraph or item text.
func (p *parser) flush() *diag.Error {
	if !p.pend.active {
		return nil
	}
	pd := p.pend
	p.pend = pending{}
	in, e := p.sc.scan(&pd.t, false)
	if e != nil {
		return e
	}
	if pd.item {
		p.top().item.Text = in
	} else {
		p.emit(&Paragraph{Text: in})
	}
	return nil
}

func leadingSpaces(l []rune) int {
	i := 0
	for i < len(l) && l[i] == ' ' {
		i++
	}
	return i
}

func (p *parser) line(no int, l []rune) *diag.Error {
	if p.inPre {
		if strings.TrimLeft(strings.TrimRight(string(l), " "), " ") == "@end" {
			p.inPre = false
			p.emit(p.pre)
			p.pre = nil
			return nil
		}
		p.pre.Lines = append(p.pre.Lines, strings.TrimRight(string(l), " "))
		return nil
	}
	first := leadingSpaces(l)
	if first == len(l) {
		// blank line
		return p.flush()
	}
	if l[first] == '@' {
		if e := p.flush(); e != nil {
			return e
		}
		e := p.directive(no, l, first)
		return e
	}
	return p.textLine(no, l, first)
}

func (p *parser) textLine(no int, l []rune, first int) *diag.Error {
	t := p.top()
	if t != nil {
		switch t.kind {
		case fkDoc:
			return p.metaLine(no, l, first)
		case fkList:
			return p.errAt(no, first+1, diag.TextNotAllowed)
		case fkTable:
			return p.tableRow(no, l, first)
		case fkFig:
			if len(t.cap.r) > 0 {
				t.cap.add(' ', srcPos{no, len(l) + 1})
			}
			t.cap.addLine(l, first, no)
			return nil
		}
	}
	if p.pend.active {
		p.pend.t.add(' ', srcPos{no, len(l) + 1})
		p.pend.t.addLine(l, first, no)
		return nil
	}
	p.begin()
	p.pend = pending{active: true}
	p.pend.t.addLine(l, first, no)
	return nil
}

// metaLine handles a line inside @doc.
func (p *parser) metaLine(no int, l []rune, first int) *diag.Error {
	i := first
	for i < len(l) && isKeyChar(l[i]) {
		i++
	}
	keyEnd := i
	for i < len(l) && (l[i] == ' ' || l[i] == '\t') {
		i++
	}
	if keyEnd == first || i >= len(l) || l[i] != '=' {
		return p.errAt(no, first+1, diag.BadSyntax)
	}
	key := string(l[first:keyEnd])
	t := p.top()
	switch key {
	case "title", "author", "date":
	default:
		return p.errAt(no, first+1, diag.UnknownMeta)
	}
	if t.meta[key] {
		return p.errAt(no, first+1, diag.DuplicateMeta)
	}
	t.meta[key] = true
	val := strings.Trim(string(l[i+1:]), " \t")
	switch key {
	case "title":
		p.doc.Meta.Title = val
	case "author":
		p.doc.Meta.Author = val
	case "date":
		p.doc.Meta.Date = val
	}
	return nil
}

func isKeyChar(r rune) bool {
	return (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') || r == '-'
}

// tableRow splits a row into cells and scans each.
func (p *parser) tableRow(no int, l []rune, first int) *diag.Error {
	t := p.top()
	var cells []*text
	cur := &text{}
	for i := first; i < len(l); i++ {
		c := l[i]
		switch {
		case c == '\\' && i+1 < len(l):
			cur.add(c, srcPos{no, i + 1})
			i++
			cur.add(l[i], srcPos{no, i + 1})
		case c == '|':
			cells = append(cells, cur)
			cur = &text{}
		default:
			cur.add(c, srcPos{no, i + 1})
		}
	}
	cells = append(cells, cur)
	if len(cells) != t.table.Cols {
		return p.errAt(no, 1, diag.CellCount)
	}
	row := TableElem{}
	for _, c := range cells {
		in, e := p.sc.scan(c, false)
		if e != nil {
			return e
		}
		row.Cells = append(row.Cells, in)
	}
	t.table.Rows = append(t.table.Rows, row)
	return nil
}

// attribute is one parsed name=value token.
type attribute struct {
	name    string
	value   string
	nameCol int
	valCol  int
}

type dirSpec struct {
	attrs    []string // allowed attribute names
	required []string
	inline   bool // the rest of the line is inline text
}

var dirSpecs = map[string]dirSpec{
	"@doc":     {},
	"@toc":     {attrs: []string{"title"}},
	"@h1":      {inline: true},
	"@h2":      {inline: true},
	"@h3":      {inline: true},
	"@h4":      {inline: true},
	"@h1*":     {inline: true},
	"@h2*":     {inline: true},
	"@h3*":     {inline: true},
	"@h4*":     {inline: true},
	"@q":       {},
	"@block":   {attrs: []string{"align", "indent", "right-indent", "font", "size", "leading"}},
	"@ul":      {},
	"@ol":      {attrs: []string{"start"}},
	"@li":      {inline: true},
	"@table":   {attrs: []string{"cols", "align"}, required: []string{"cols"}},
	"@hrule":   {},
	"@pre":     {},
	"@fig":     {attrs: []string{"height", "width"}, required: []string{"height"}},
	"@rule":    {},
	"@vspace":  {attrs: []string{"height"}, required: []string{"height"}},
	"@newpage": {},
	"@end":     {},
}

func isAttrNameChar(r rune) bool {
	return (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') || r == '-'
}

func isBareChar(r rune) bool {
	return isAttrNameChar(r) || r == '.' || r == '+' || r == '%'
}

// parseAttrs reads the attribute tokens of a directive starting at rune
// index i. It returns the attributes or the first error (name checks, then
// lexical value checks, token by token).
func (p *parser) parseAttrs(no int, l []rune, i int, spec dirSpec) ([]attribute, *diag.Error) {
	var out []attribute
	for {
		for i < len(l) && l[i] == ' ' {
			i++
		}
		if i >= len(l) {
			return out, nil
		}
		ns := i
		for i < len(l) && isAttrNameChar(l[i]) {
			i++
		}
		if i == ns || i >= len(l) || l[i] != '=' {
			return nil, p.errAt(no, ns+1, diag.BadAttribute)
		}
		name := string(l[ns:i])
		known := false
		for _, a := range spec.attrs {
			if a == name {
				known = true
			}
		}
		if !known {
			return nil, p.errAt(no, ns+1, diag.BadAttribute)
		}
		for _, a := range out {
			if a.name == name {
				return nil, p.errAt(no, ns+1, diag.BadAttribute)
			}
		}
		i++ // '='
		vs := i
		at := attribute{name: name, nameCol: ns + 1, valCol: vs + 1}
		if i < len(l) && l[i] == '"' {
			j := i + 1
			for j < len(l) && l[j] != '"' {
				j++
			}
			if j >= len(l) {
				return nil, p.errAt(no, vs+1, diag.BadAttributeValue)
			}
			at.value = string(l[i+1 : j])
			i = j + 1
		} else {
			j := i
			for j < len(l) && isBareChar(l[j]) {
				j++
			}
			if j == i {
				return nil, p.errAt(no, vs+1, diag.BadAttributeValue)
			}
			at.value = string(l[i:j])
			i = j
		}
		if i < len(l) && l[i] != ' ' {
			return nil, p.errAt(no, vs+1, diag.BadAttributeValue)
		}
		out = append(out, at)
	}
}

func find(attrs []attribute, name string) *attribute {
	for i := range attrs {
		if attrs[i].name == name {
			return &attrs[i]
		}
	}
	return nil
}

// placement checks where a directive may appear. It returns the error code
// or "".
func (p *parser) placement(name string) string {
	t := p.top()
	switch name {
	case "@doc":
		if t != nil || p.topSeen > 0 {
			return diag.BlockNotAllowed
		}
		return ""
	case "@toc":
		if p.hasTOC {
			if t != nil && (t.kind == fkDoc || t.kind == fkTable || t.kind == fkFig || t.kind == fkList) {
				return diag.BlockNotAllowed
			}
			return diag.DuplicateTOC
		}
		if t == nil && (p.topSeen == 0 || (p.topSeen == 1 && p.hasDoc)) {
			return ""
		}
		return diag.BlockNotAllowed
	case "@end":
		if t == nil {
			return diag.UnexpectedEnd
		}
		return ""
	case "@li":
		if t != nil && (t.kind == fkList || t.kind == fkItem) {
			return ""
		}
		return diag.BlockNotAllowed
	case "@hrule":
		if t != nil && t.kind == fkTable {
			return ""
		}
		return diag.BlockNotAllowed
	}
	if t == nil || t.kind == fkQuote || t.kind == fkBlock || t.kind == fkItem {
		return ""
	}
	return diag.BlockNotAllowed
}

func (p *parser) directive(no int, l []rune, first int) *diag.Error {
	end := first
	for end < len(l) && l[end] != ' ' {
		end++
	}
	name := string(l[first:end])
	spec, ok := dirSpecs[name]
	if !ok {
		return p.errAt(no, first+1, diag.UnknownBlock)
	}
	var attrs []attribute
	if !spec.inline {
		var e *diag.Error
		attrs, e = p.parseAttrs(no, l, end, spec)
		if e != nil {
			return e
		}
		for _, r := range spec.required {
			if find(attrs, r) == nil {
				return p.errAt(no, first+1, diag.MissingAttribute)
			}
		}
	}
	if code := p.placement(name); code != "" {
		return p.errAt(no, first+1, code)
	}
	bad := func(a *attribute) *diag.Error { return p.errAt(no, a.valCol, diag.BadAttributeValue) }

	switch name {
	case "@doc":
		p.hasDoc = true
		p.begin()
		p.stack = append(p.stack, &open{kind: fkDoc, line: no, meta: map[string]bool{}})
	case "@toc":
		p.begin()
		toc := &TOC{}
		if a := find(attrs, "title"); a != nil {
			toc.Title, toc.HasTitle = a.value, true
		}
		p.hasTOC = true
		p.doc.TOC = toc
	case "@h1", "@h2", "@h3", "@h4", "@h1*", "@h2*", "@h3*", "@h4*":
		p.begin()
		var t text
		i := end
		for i < len(l) && l[i] == ' ' {
			i++
		}
		t.addLine(l, i, no)
		in, e := p.sc.scan(&t, true)
		if e != nil {
			return e
		}
		p.emit(&Heading{Level: int(name[2] - '0'), Star: strings.HasSuffix(name, "*"), Text: in})
	case "@li":
		tp := p.top()
		if tp.kind == fkItem {
			p.closeItem()
		}
		var t text
		i := end
		for i < len(l) && l[i] == ' ' {
			i++
		}
		t.addLine(l, i, no)
		it := &Item{}
		p.stack = append(p.stack, &open{kind: fkItem, line: no, item: it})
		p.pend = pending{active: true, item: true, t: t}
	case "@q":
		p.begin()
		p.stack = append(p.stack, &open{kind: fkQuote, line: no})
	case "@block":
		g := &Group{}
		for i := range attrs {
			a := &attrs[i]
			switch a.name {
			case "align":
				if !validAlign(a.value) {
					return bad(a)
				}
				g.Align, g.HasAlign = a.value, true
			case "font":
				if a.value != "serif" && a.value != "sans" && a.value != "mono" {
					return bad(a)
				}
				g.Font, g.HasFont = a.value, true
			case "indent", "right-indent", "size", "leading":
				v, ok := dim.ParseLength(a.value)
				if !ok {
					return bad(a)
				}
				switch a.name {
				case "indent":
					if v < 0 {
						return bad(a)
					}
					g.Indent, g.HasIndent = v, true
				case "right-indent":
					if v < 0 {
						return bad(a)
					}
					g.RightIndent, g.HasRight = v, true
				case "size":
					if v < 1000 || v > 200000 {
						return bad(a)
					}
					g.Size, g.HasSize = v, true
				case "leading":
					if v < 1000 {
						return bad(a)
					}
					g.Leading, g.HasLeading = v, true
				}
			}
		}
		p.begin()
		p.stack = append(p.stack, &open{kind: fkBlock, line: no, group: g})
	case "@ul", "@ol":
		lst := &List{Ordered: name == "@ol", Start: 1}
		if a := find(attrs, "start"); a != nil {
			v, ok := dim.ParseInteger(a.value)
			if !ok || v < 1 || v > 100000 {
				return bad(a)
			}
			lst.Start = v
		}
		p.begin()
		p.stack = append(p.stack, &open{kind: fkList, line: no, list: lst})
	case "@table":
		tb := &Table{}
		colsA := find(attrs, "cols")
		alignA := find(attrs, "align")
		for i := range attrs {
			a := &attrs[i]
			switch a.name {
			case "cols":
				v, ok := dim.ParseInteger(a.value)
				if !ok || v < 1 || v > 20 {
					return bad(a)
				}
				tb.Cols = int(v)
			case "align":
				for _, c := range a.value {
					if c != 'l' && c != 'r' && c != 'c' {
						return bad(a)
					}
				}
			}
		}
		if alignA != nil {
			if len(alignA.value) != tb.Cols {
				return bad(alignA)
			}
			tb.Align = []byte(alignA.value)
		} else {
			tb.Align = []byte(strings.Repeat("l", tb.Cols))
		}
		_ = colsA
		p.begin()
		p.stack = append(p.stack, &open{kind: fkTable, line: no, table: tb})
	case "@hrule":
		t := p.top()
		t.table.Rows = append(t.table.Rows, TableElem{Rule: true})
	case "@pre":
		p.begin()
		p.inPre = true
		p.pre = &Pre{}
		p.preLine = no
	case "@fig":
		f := &Figure{}
		for i := range attrs {
			a := &attrs[i]
			v, ok := dim.ParseLength(a.value)
			if !ok || v < 0 {
				return bad(a)
			}
			if a.name == "height" {
				f.Height = v
			} else {
				f.Width, f.HasWidth = v, true
			}
		}
		p.begin()
		p.stack = append(p.stack, &open{kind: fkFig, line: no, fig: f})
	case "@rule":
		p.begin()
		p.emit(&Rule{})
	case "@vspace":
		a := find(attrs, "height")
		v, ok := dim.ParseLength(a.value)
		if !ok || v < 0 {
			return bad(a)
		}
		p.begin()
		p.emit(&VSpace{Height: v})
	case "@newpage":
		p.begin()
		p.emit(&NewPage{})
	case "@end":
		return p.closeTop()
	}
	return nil
}

func validAlign(s string) bool {
	return s == "justify" || s == "left" || s == "right" || s == "center"
}

// closeItem closes the open @li item and attaches it to its list.
func (p *parser) closeItem() {
	t := p.top()
	t.item.Children = t.children
	p.stack = p.stack[:len(p.stack)-1]
	lst := p.top()
	lst.list.Items = append(lst.list.Items, t.item)
}

// closeTop handles @end: it closes the innermost open block.
func (p *parser) closeTop() *diag.Error {
	t := p.top()
	if t.kind == fkItem {
		p.closeItem()
		t = p.top()
	}
	switch t.kind {
	case fkFig:
		in, e := p.sc.scan(&t.cap, true)
		if e != nil {
			return e
		}
		t.fig.Caption = in
	}
	p.stack = p.stack[:len(p.stack)-1]
	var b Block
	switch t.kind {
	case fkDoc:
		return nil
	case fkQuote:
		b = &Quote{Children: t.children}
	case fkBlock:
		t.group.Children = t.children
		b = t.group
	case fkList:
		b = t.list
	case fkTable:
		b = t.table
	case fkFig:
		b = t.fig
	}
	p.emit(b)
	return nil
}
