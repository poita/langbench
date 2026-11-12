package markdown

import "strings"

// blockParser implements the first phase of the conversion: it reads the
// document line by line and builds the tree of blocks.
type blockParser struct {
	doc *node

	line   string
	lineNo int

	offset     int // byte offset into line
	column     int // column of offset, tabs expanded to multiples of 4
	partialTab bool

	nextNonspace       int
	nextNonspaceColumn int
	indent             int
	blank              bool

	allMatched  bool
	lastMatched *node
}

func parseBlocks(src string) *node {
	p := &blockParser{doc: &node{kind: kDocument, open: true}}
	for len(src) > 0 {
		var line string
		if i := strings.IndexByte(src, '\n'); i >= 0 {
			line, src = src[:i], src[i+1:]
		} else {
			line, src = src, ""
		}
		p.processLine(line)
	}
	for b := p.tip(); b != nil; b = b.parent {
		p.finalize(b)
	}
	return p.doc
}

// at returns the byte at index i of the current line; the end of the line
// reads as '\n'.
func (p *blockParser) at(i int) byte {
	if i < len(p.line) {
		return p.line[i]
	}
	return '\n'
}

func isSpaceOrTab(c byte) bool { return c == ' ' || c == '\t' }

// tip is the innermost open block.
func (p *blockParser) tip() *node {
	t := p.doc
	for t.last != nil && t.last.open {
		t = t.last
	}
	return t
}

func (p *blockParser) findNextNonspace() {
	i, col := p.offset, p.column
	for {
		c := p.at(i)
		if c == ' ' {
			i++
			col++
		} else if c == '\t' {
			i++
			col += 4 - col%4
		} else {
			break
		}
	}
	p.blank = p.at(i) == '\n'
	p.nextNonspace = i
	p.nextNonspaceColumn = col
	p.indent = col - p.column
}

// advance moves the position forward by count characters, or by count
// columns when columns is true (a tab may then be partially consumed).
func (p *blockParser) advance(count int, columns bool) {
	for count > 0 && p.offset < len(p.line) {
		c := p.line[p.offset]
		if c == '\t' {
			toTab := 4 - p.column%4
			if columns {
				p.partialTab = toTab > count
				n := toTab
				if count < n {
					n = count
				}
				p.column += n
				if !p.partialTab {
					p.offset++
				}
				count -= n
			} else {
				p.partialTab = false
				p.column += toTab
				p.offset++
				count--
			}
		} else {
			p.partialTab = false
			p.offset++
			p.column++
			count--
		}
	}
}

// addLine appends the rest of the current line to a leaf block.
func (p *blockParser) addLine(n *node) {
	if p.partialTab {
		p.offset++
		for i := 4 - p.column%4; i > 0; i-- {
			n.content = append(n.content, ' ')
		}
	}
	if p.offset < len(p.line) {
		n.content = append(n.content, p.line[p.offset:]...)
	}
	n.content = append(n.content, '\n')
}

func canContain(parent, child kind) bool {
	switch parent {
	case kDocument, kBlockQuote, kItem:
		return child != kItem
	case kList:
		return child == kItem
	}
	return false
}

func acceptsLines(k kind) bool {
	return k == kParagraph || k == kHeading || k == kCodeBlock
}

func (p *blockParser) addChild(parent *node, k kind) *node {
	for !canContain(parent.kind, k) {
		p.finalize(parent)
		parent = parent.parent
	}
	n := &node{kind: k, open: true, startLine: p.lineNo}
	parent.appendChild(n)
	return n
}

func (p *blockParser) processLine(line string) {
	p.line = line
	p.lineNo++
	p.offset, p.column, p.partialTab = 0, 0, false

	// Step 1: continue open blocks.
	container := p.doc
	p.allMatched = true
	for last := container.last; last != nil && last.open; last = container.last {
		b := last
		p.findNextNonspace()
		matched := true
		switch b.kind {
		case kBlockQuote:
			if p.indent <= 3 && p.at(p.nextNonspace) == '>' {
				p.advance(p.indent+1, true)
				if isSpaceOrTab(p.at(p.offset)) {
					p.advance(1, true)
				}
			} else {
				matched = false
			}
		case kItem:
			if p.indent >= b.markerOffset+b.padding {
				p.advance(b.markerOffset+b.padding, true)
			} else if p.blank && b.first != nil {
				p.advance(p.nextNonspace-p.offset, false)
			} else {
				matched = false
			}
		case kCodeBlock:
			if b.fenced {
				if p.indent <= 3 && p.at(p.nextNonspace) == b.fenceChar && p.isClosingFence(b) {
					p.finalize(b)
					return
				}
				for i := b.fenceOffset; i > 0 && isSpaceOrTab(p.at(p.offset)); i-- {
					p.advance(1, true)
				}
			} else if p.indent >= 4 {
				p.advance(4, true)
			} else if p.blank {
				p.advance(p.nextNonspace-p.offset, false)
			} else {
				matched = false
			}
		case kHeading:
			matched = false
		case kParagraph:
			matched = !p.blank
		}
		if !matched {
			p.allMatched = false
			break
		}
		container = b
	}
	p.lastMatched = container
	oldTip := p.tip()

	// Step 2: start new blocks.
	maybeLazy := oldTip.kind == kParagraph
	for container.kind != kCodeBlock {
		p.findNextNonspace()
		indented := p.indent >= 4
		c := p.at(p.nextNonspace)
		if !indented && c == '>' {
			p.advance(p.nextNonspace+1-p.offset, false)
			if isSpaceOrTab(p.at(p.offset)) {
				p.advance(1, true)
			}
			container = p.addChild(container, kBlockQuote)
		} else if !indented && c == '#' && p.startATX(&container) {
			// opened
		} else if !indented && (c == '`' || c == '~') && p.startFence(&container) {
			// opened
		} else if !indented && container.kind == kParagraph && (c == '=' || c == '-') && p.startSetext(container) {
			// converted
		} else if !indented && (c == '*' || c == '_' || c == '-') && p.isThematicBreak() {
			container = p.addChild(container, kThematicBreak)
			p.advance(len(p.line)-p.offset, false)
		} else if p.indent < 4 && p.startItem(&container) {
			// opened
		} else if indented && !maybeLazy && !p.blank {
			p.advance(4, true)
			container = p.addChild(container, kCodeBlock)
		} else {
			break
		}
		if acceptsLines(container.kind) {
			break
		}
		maybeLazy = false
	}

	// Step 3: add the text of the line.
	p.findNextNonspace()
	if p.blank && container.last != nil {
		container.last.lastLineBlank = true
	}
	ck := container.kind
	container.lastLineBlank = p.blank && ck != kBlockQuote && ck != kHeading && ck != kThematicBreak &&
		!(ck == kCodeBlock && container.fenced) &&
		!(ck == kItem && container.first == nil && container.startLine == p.lineNo)
	for t := container.parent; t != nil; t = t.parent {
		t.lastLineBlank = false
	}

	if !p.allMatched && container == p.lastMatched && !p.blank && oldTip.kind == kParagraph {
		// Lazy continuation line.
		p.addLine(oldTip)
		return
	}
	for b := oldTip; b != p.lastMatched; b = b.parent {
		p.finalize(b)
	}
	switch {
	case container.kind == kCodeBlock:
		p.addLine(container)
	case p.blank:
		// nothing to add
	case acceptsLines(container.kind):
		if container.kind == kHeading {
			p.addHeadingLine(container)
		} else {
			p.advance(p.nextNonspace-p.offset, false)
			p.addLine(container)
		}
	default:
		container = p.addChild(container, kParagraph)
		p.advance(p.nextNonspace-p.offset, false)
		p.addLine(container)
	}
}

// addHeadingLine appends the text of an ATX heading line, without the
// optional closing sequence of '#' characters.
func (p *blockParser) addHeadingLine(h *node) {
	line := p.line
	end := len(line)
	for end > 0 && isWhitespace(line[end-1]) {
		end--
	}
	n := end - 1
	for n >= 0 && line[n] == '#' {
		n--
	}
	if n != end-1 && n >= 0 && isSpaceOrTab(line[n]) {
		end = n
		for end > 0 && isWhitespace(line[end-1]) {
			end--
		}
	}
	p.advance(p.nextNonspace-p.offset, false)
	if p.offset < end {
		h.content = append(h.content, line[p.offset:end]...)
	}
	h.content = append(h.content, '\n')
}

func isWhitespace(c byte) bool {
	return c == ' ' || c == '\t' || c == '\n' || c == '\v' || c == '\f' || c == '\r'
}

// isClosingFence reports whether the rest of the line, starting at the first
// non-space character, closes the fenced code block b.
func (p *blockParser) isClosingFence(b *node) bool {
	i := p.nextNonspace
	n := 0
	for p.at(i) == b.fenceChar {
		i++
		n++
	}
	if n < b.fenceLen {
		return false
	}
	for isSpaceOrTab(p.at(i)) {
		i++
	}
	return p.at(i) == '\n'
}

func (p *blockParser) startATX(container **node) bool {
	i := p.nextNonspace
	n := 0
	for p.at(i) == '#' && n < 7 {
		i++
		n++
	}
	if n < 1 || n > 6 {
		return false
	}
	if c := p.at(i); !isSpaceOrTab(c) && c != '\n' {
		return false
	}
	for isSpaceOrTab(p.at(i)) {
		i++
	}
	p.advance(i-p.offset, false)
	h := p.addChild(*container, kHeading)
	h.level = n
	*container = h
	return true
}

func (p *blockParser) startFence(container **node) bool {
	i := p.nextNonspace
	c := p.at(i)
	n := 0
	for p.at(i) == c {
		i++
		n++
	}
	if n < 3 {
		return false
	}
	if c == '`' && strings.IndexByte(p.line[min(i, len(p.line)):], '`') >= 0 {
		return false
	}
	b := p.addChild(*container, kCodeBlock)
	b.fenced = true
	b.fenceChar = c
	b.fenceLen = n
	b.fenceOffset = p.nextNonspace - p.offset
	p.advance(i-p.offset, false)
	*container = b
	return true
}

func (p *blockParser) startSetext(container *node) bool {
	i := p.nextNonspace
	c := p.at(i)
	for p.at(i) == c {
		i++
	}
	for isSpaceOrTab(p.at(i)) {
		i++
	}
	if p.at(i) != '\n' {
		return false
	}
	container.kind = kHeading
	if c == '=' {
		container.level = 1
	} else {
		container.level = 2
	}
	p.advance(len(p.line)-p.offset, false)
	return true
}

func (p *blockParser) isThematicBreak() bool {
	i := p.nextNonspace
	c := p.at(i)
	n := 0
	for ; ; i++ {
		d := p.at(i)
		if d == c {
			n++
		} else if !isSpaceOrTab(d) {
			break
		}
	}
	return n >= 3 && p.at(i) == '\n'
}

func isDigit(c byte) bool { return c >= '0' && c <= '9' }

func (p *blockParser) startItem(container **node) bool {
	interrupts := (*container).kind == kParagraph
	pos := p.nextNonspace
	c := p.at(pos)
	var ordered bool
	var bullet, delim byte
	start := 0
	if c == '*' || c == '-' || c == '+' {
		bullet = c
		pos++
	} else if isDigit(c) {
		ordered = true
		digits := 0
		for isDigit(p.at(pos)) {
			start = start*10 + int(p.at(pos)-'0')
			pos++
			digits++
			if digits > 9 {
				return false
			}
		}
		d := p.at(pos)
		if d != '.' && d != ')' {
			return false
		}
		if interrupts && start != 1 {
			return false
		}
		delim = d
		pos++
	} else {
		return false
	}
	if d := p.at(pos); !isSpaceOrTab(d) && d != '\n' {
		return false
	}
	if interrupts {
		i := pos
		for isSpaceOrTab(p.at(i)) {
			i++
		}
		if p.at(i) == '\n' {
			return false
		}
	}
	width := pos - p.nextNonspace
	markerOffset := p.indent

	p.advance(pos-p.offset, false)
	saveOffset, saveColumn, savePartial := p.offset, p.column, p.partialTab
	for p.column-saveColumn <= 5 && isSpaceOrTab(p.at(p.offset)) {
		p.advance(1, true)
	}
	n := p.column - saveColumn
	var padding int
	if n >= 5 || n < 1 || p.at(p.offset) == '\n' {
		padding = width + 1
		p.offset, p.column, p.partialTab = saveOffset, saveColumn, savePartial
		if n > 0 {
			p.advance(1, true)
		}
	} else {
		padding = width + n
	}

	ct := *container
	if ct.kind != kList || ct.ordered != ordered || ct.bullet != bullet || ct.delim != delim {
		l := p.addChild(ct, kList)
		l.ordered, l.bullet, l.delim, l.start = ordered, bullet, delim, start
		ct = l
	}
	item := p.addChild(ct, kItem)
	item.markerOffset = markerOffset
	item.padding = padding
	*container = item
	return true
}

// finalize closes block b.
func (p *blockParser) finalize(b *node) {
	if !b.open {
		return
	}
	b.open = false
	switch b.kind {
	case kCodeBlock:
		content := b.content
		b.content = nil
		if b.fenced {
			nl := indexByte(content, '\n')
			rest := content[nl+1:]
			info := unescapeEntities(string(content[:nl]))
			info = strings.TrimFunc(info, func(r rune) bool { return r < 128 && isWhitespace(byte(r)) })
			b.info = unescapeBackslashes(info)
			b.lit = string(rest)
		} else {
			// Remove trailing blank lines, then end with a single newline.
			i := len(content) - 1
			for i >= 0 && (isSpaceOrTab(content[i]) || content[i] == '\n' || content[i] == '\r') {
				i--
			}
			if i < 0 {
				content = nil
			} else {
				if j := indexByte(content[i:], '\n'); j >= 0 {
					content = content[:i+j]
				}
			}
			b.lit = string(content) + "\n"
		}
	case kList:
		b.tight = true
	items:
		for item := b.first; item != nil; item = item.next {
			if item.lastLineBlank && item.next != nil {
				b.tight = false
				break
			}
			for sub := item.first; sub != nil; sub = sub.next {
				if (item.next != nil || sub.next != nil) && endsWithBlankLine(sub) {
					b.tight = false
					break items
				}
			}
		}
	}
}

func indexByte(b []byte, c byte) int {
	for i, x := range b {
		if x == c {
			return i
		}
	}
	return -1
}

// endsWithBlankLine reports whether block n ends with a blank line, with the
// memoisation of the reference implementation: each block is inspected
// recursively at most once and later queries return its own flag.
func endsWithBlankLine(n *node) bool {
	for cur := n; cur != nil; {
		if cur.lastLineChecked {
			return cur.lastLineBlank
		}
		cur.lastLineChecked = true
		if (cur.kind == kList || cur.kind == kItem) && cur.last != nil {
			cur = cur.last
		} else {
			return cur.lastLineBlank
		}
	}
	return false
}
