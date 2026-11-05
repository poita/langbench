package markdown

// This file implements phase 1: the line-driven block parser. It mirrors the
// structure of cmark's blocks.c.

const codeIndent = 4

type parser struct {
	src        string
	doc        *node
	current    *node // the innermost open block before/after each line
	lineNumber int

	line                 string // current line including its terminating '\n'
	offset, column       int
	firstNonspace        int
	firstNonspaceColumn  int
	indent               int
	blank                bool
	partiallyConsumedTab bool
}

func newParser(src string) *parser {
	doc := &node{typ: nDocument, open: true}
	return &parser{src: src, doc: doc, current: doc}
}

// parse runs the block phase over the whole source and returns the document.
func (p *parser) parse() *node {
	src := p.src
	for pos := 0; pos < len(src); {
		end := pos
		for end < len(src) && src[end] != '\n' {
			end++
		}
		if end < len(src) {
			p.processLine(src[pos : end+1])
			pos = end + 1
		} else {
			p.processLine(src[pos:] + "\n")
			pos = end
		}
	}
	for p.current != p.doc {
		p.current = p.finalize(p.current)
	}
	p.finalize(p.doc)
	return p.doc
}

func (p *parser) peek(i int) byte {
	if i < len(p.line) {
		return p.line[i]
	}
	return 0
}

func (p *parser) findFirstNonspace() {
	p.firstNonspace = p.offset
	p.firstNonspaceColumn = p.column
	charsToTab := codeIndent - p.column%codeIndent
	var c byte
	for {
		c = p.peek(p.firstNonspace)
		if c == ' ' {
			p.firstNonspace++
			p.firstNonspaceColumn++
			charsToTab--
			if charsToTab == 0 {
				charsToTab = codeIndent
			}
		} else if c == '\t' {
			p.firstNonspace++
			p.firstNonspaceColumn += charsToTab
			charsToTab = codeIndent
		} else {
			break
		}
	}
	p.indent = p.firstNonspaceColumn - p.column
	p.blank = c == '\n' || c == 0
}

// advanceOffset moves forward by count characters, or by count columns when
// columns is true (a tab may then be partially consumed).
func (p *parser) advanceOffset(count int, columns bool) {
	for count > 0 {
		c := p.peek(p.offset)
		if c == 0 {
			break
		}
		if c == '\t' {
			charsToTab := codeIndent - p.column%codeIndent
			if columns {
				p.partiallyConsumedTab = charsToTab > count
				adv := count
				if charsToTab < adv {
					adv = charsToTab
				}
				p.column += adv
				if !p.partiallyConsumedTab {
					p.offset++
				}
				count -= adv
			} else {
				p.partiallyConsumedTab = false
				p.column += charsToTab
				p.offset++
				count--
			}
		} else {
			p.partiallyConsumedTab = false
			p.offset++
			p.column++
			count--
		}
	}
}

func canContain(parent *node, t nodeType) bool {
	switch parent.typ {
	case nDocument, nBlockQuote, nItem:
		return t != nItem
	case nList:
		return t == nItem
	}
	return false
}

func acceptsLines(t nodeType) bool {
	return t == nParagraph || t == nHeading || t == nCodeBlock
}

func lastChildIsOpen(n *node) bool { return n.last != nil && n.last.open }

// addChild appends a new open block of type t to parent, closing blocks that
// cannot contain it.
func (p *parser) addChild(parent *node, t nodeType) *node {
	for !canContain(parent, t) {
		parent = p.finalize(parent)
	}
	c := &node{typ: t, open: true, startLine: p.lineNumber}
	parent.appendChild(c)
	return c
}

func (p *parser) processLine(line string) {
	p.lineNumber++
	p.line = line
	p.offset, p.column = 0, 0
	p.blank = false
	p.partiallyConsumedTab = false

	container, finished := p.checkOpenBlocks()
	if finished {
		return
	}
	lastMatched := container
	container = p.openNewBlocks(container)
	p.addTextToContainer(container, lastMatched)
}

// checkOpenBlocks implements step 1: walk down the chain of open blocks as
// long as they accept the line. finished is true when the line closed a
// fenced code block and needs no further processing.
func (p *parser) checkOpenBlocks() (container *node, finished bool) {
	container = p.doc
	matched := true
loop:
	for lastChildIsOpen(container) {
		container = container.last
		p.findFirstNonspace()
		switch container.typ {
		case nBlockQuote:
			if p.indent <= 3 && p.peek(p.firstNonspace) == '>' {
				p.advanceOffset(p.firstNonspace+1-p.offset, false)
				if isSpaceOrTab(p.peek(p.offset)) {
					p.advanceOffset(1, true)
				}
			} else {
				matched = false
				break loop
			}
		case nItem:
			if p.indent >= container.list.markerOffset+container.list.padding {
				p.advanceOffset(container.list.markerOffset+container.list.padding, true)
			} else if p.blank && container.first != nil {
				p.advanceOffset(p.firstNonspace-p.offset, false)
			} else {
				matched = false
				break loop
			}
		case nCodeBlock:
			if !container.fenced {
				if p.indent >= codeIndent {
					p.advanceOffset(codeIndent, true)
				} else if p.blank {
					p.advanceOffset(p.firstNonspace-p.offset, false)
				} else {
					matched = false
					break loop
				}
			} else {
				run := 0
				if p.indent <= 3 && p.peek(p.firstNonspace) == container.fenceChar {
					run = p.scanCloseFence(p.firstNonspace, container.fenceChar)
				}
				if run >= container.fenceLen {
					// Closing fence: the line is consumed.
					p.current = p.finalize(container)
					return nil, true
				}
				for i := container.fenceOffset; i > 0 && isSpaceOrTab(p.peek(p.offset)); i-- {
					p.advanceOffset(1, true)
				}
			}
		case nHeading:
			matched = false
			break loop
		case nParagraph:
			if p.blank {
				matched = false
				break loop
			}
		}
	}
	if !matched {
		container = container.parent
	}
	return container, false
}

// scanCloseFence returns the length of the run of ch at pos if only spaces and
// tabs follow it, else 0.
func (p *parser) scanCloseFence(pos int, ch byte) int {
	i := pos
	for p.peek(i) == ch {
		i++
	}
	n := i - pos
	if n < 3 {
		return 0
	}
	for isSpaceOrTab(p.peek(i)) {
		i++
	}
	if c := p.peek(i); c != '\n' && c != 0 {
		return 0
	}
	return n
}

// scanATX matches an ATX heading start at pos and returns the heading level
// and the length of the match including trailing spaces and tabs.
func (p *parser) scanATX(pos int) (level, length int) {
	i := pos
	for p.peek(i) == '#' {
		i++
	}
	level = i - pos
	if level < 1 || level > 6 {
		return 0, 0
	}
	c := p.peek(i)
	if c != ' ' && c != '\t' && c != '\n' && c != 0 {
		return 0, 0
	}
	for isSpaceOrTab(p.peek(i)) {
		i++
	}
	return level, i - pos
}

// scanOpenFence matches the start of a fenced code block at pos.
func (p *parser) scanOpenFence(pos int) (ch byte, length int) {
	c := p.peek(pos)
	if c != '`' && c != '~' {
		return 0, 0
	}
	i := pos
	for p.peek(i) == c {
		i++
	}
	if i-pos < 3 {
		return 0, 0
	}
	if c == '`' {
		for j := i; p.peek(j) != '\n' && p.peek(j) != 0; j++ {
			if p.peek(j) == '`' {
				return 0, 0
			}
		}
	}
	return c, i - pos
}

// scanSetext matches a setext underline at pos: 1 for '=', 2 for '-', else 0.
func (p *parser) scanSetext(pos int) int {
	c := p.peek(pos)
	if c != '=' && c != '-' {
		return 0
	}
	i := pos
	for p.peek(i) == c {
		i++
	}
	for isSpaceOrTab(p.peek(i)) {
		i++
	}
	if e := p.peek(i); e != '\n' && e != 0 {
		return 0
	}
	if c == '=' {
		return 1
	}
	return 2
}

// scanThematicBreak reports whether the line from pos is a thematic break.
func (p *parser) scanThematicBreak(pos int) bool {
	c := p.peek(pos)
	if c != '*' && c != '_' && c != '-' {
		return false
	}
	count := 0
	for i := pos; ; i++ {
		d := p.peek(i)
		switch {
		case d == c:
			count++
		case d == ' ' || d == '\t':
		case d == '\n' || d == 0:
			return count >= 3
		default:
			return false
		}
	}
}

// parseListMarker matches a list marker at pos. It returns its width, or 0.
func (p *parser) parseListMarker(pos int, interruptsParagraph bool) (data *listData, width int) {
	c := p.peek(pos)
	i := pos
	data = &listData{}
	switch {
	case c == '*' || c == '-' || c == '+':
		i++
		if !isSpace(p.peek(i)) && p.peek(i) != 0 {
			return nil, 0
		}
		if interruptsParagraph {
			j := i
			for isSpaceOrTab(p.peek(j)) {
				j++
			}
			if p.peek(j) == '\n' || p.peek(j) == 0 {
				return nil, 0
			}
		}
		data.bullet = c
	case isDigit(c):
		start, digits := 0, 0
		for {
			start = start*10 + int(p.peek(i)-'0')
			i++
			digits++
			if digits >= 9 || !isDigit(p.peek(i)) {
				break
			}
		}
		d := p.peek(i)
		if d != '.' && d != ')' {
			return nil, 0
		}
		i++
		if !isSpace(p.peek(i)) && p.peek(i) != 0 {
			return nil, 0
		}
		if interruptsParagraph {
			j := i
			for isSpaceOrTab(p.peek(j)) {
				j++
			}
			if start != 1 || p.peek(j) == '\n' || p.peek(j) == 0 {
				return nil, 0
			}
		}
		data.ordered = true
		data.start = start
		data.delim = d
	default:
		return nil, 0
	}
	return data, i - pos
}

func listsMatch(a, b *listData) bool {
	return a.ordered == b.ordered && a.delim == b.delim && a.bullet == b.bullet
}

// openNewBlocks implements step 2: start new container and leaf blocks.
func (p *parser) openNewBlocks(container *node) *node {
	maybeLazy := p.current.typ == nParagraph
	for container.typ != nCodeBlock {
		p.findFirstNonspace()
		indented := p.indent >= codeIndent
		c := p.peek(p.firstNonspace)
		contType := container.typ

		if !indented && c == '>' {
			p.advanceOffset(p.firstNonspace+1-p.offset, false)
			if isSpaceOrTab(p.peek(p.offset)) {
				p.advanceOffset(1, true)
			}
			container = p.addChild(container, nBlockQuote)
		} else if level, n := p.scanATX(p.firstNonspace); !indented && n > 0 {
			p.advanceOffset(p.firstNonspace+n-p.offset, false)
			container = p.addChild(container, nHeading)
			container.level = level
		} else if fc, n := p.scanOpenFence(p.firstNonspace); !indented && n > 0 {
			container = p.addChild(container, nCodeBlock)
			container.fenced = true
			container.fenceChar = fc
			container.fenceLen = n
			container.fenceOffset = p.firstNonspace - p.offset
			p.advanceOffset(p.firstNonspace+n-p.offset, false)
		} else if lev := p.scanSetext(p.firstNonspace); !indented && contType == nParagraph && lev > 0 {
			container.typ = nHeading
			container.level = lev
			container.setext = true
			p.advanceOffset(len(p.line)-1-p.offset, false)
		} else if !indented && p.scanThematicBreak(p.firstNonspace) {
			container = p.addChild(container, nThematicBreak)
			p.advanceOffset(len(p.line)-1-p.offset, false)
		} else if data, w := p.parseListMarker(p.firstNonspace, contType == nParagraph); p.indent < codeIndent && w > 0 {
			data.markerOffset = p.indent
			p.advanceOffset(p.firstNonspace+w-p.offset, false)
			// Compute the padding.
			savedTab, savedOffset, savedColumn := p.partiallyConsumedTab, p.offset, p.column
			for p.column-savedColumn <= 5 && isSpaceOrTab(p.peek(p.offset)) {
				p.advanceOffset(1, true)
			}
			i := p.column - savedColumn
			if e := p.peek(p.offset); i >= 5 || i < 1 || e == '\n' || e == 0 {
				data.padding = w + 1
				p.offset, p.column, p.partiallyConsumedTab = savedOffset, savedColumn, savedTab
				if i > 0 {
					p.advanceOffset(1, true)
				}
			} else {
				data.padding = w + i
			}
			if contType != nList || !listsMatch(container.list, data) {
				container = p.addChild(container, nList)
				container.list = &listData{
					ordered: data.ordered, delim: data.delim, bullet: data.bullet, start: data.start,
				}
			}
			container = p.addChild(container, nItem)
			container.list = data
		} else if indented && !maybeLazy && !p.blank {
			p.advanceOffset(codeIndent, true)
			container = p.addChild(container, nCodeBlock)
		} else {
			break
		}
		if acceptsLines(container.typ) {
			break
		}
		maybeLazy = false
	}
	return container
}

// addLine appends text (normally the rest of the current line) to a leaf
// block, expanding a partially consumed tab into spaces.
func (p *parser) addLine(n *node, text string) {
	if p.partiallyConsumedTab {
		p.offset++
		charsToTab := codeIndent - p.column%codeIndent
		for i := 0; i < charsToTab; i++ {
			n.content = append(n.content, ' ')
		}
		if len(text) > 0 {
			text = text[1:]
		}
	}
	n.content = append(n.content, text...)
}

// chopTrailingHashes removes the optional closing sequence of an ATX heading
// and the trailing whitespace of its content.
func chopTrailingHashes(s string) string {
	s = rtrimSpace(s)
	n := len(s) - 1
	for n >= 0 && s[n] == '#' {
		n--
	}
	if n != len(s)-1 && (n < 0 || isSpaceOrTab(s[n])) {
		s = rtrimSpace(s[:n+1])
	}
	return s
}

// addTextToContainer implements step 3.
func (p *parser) addTextToContainer(container, lastMatched *node) {
	p.findFirstNonspace()

	if p.blank && container.last != nil {
		container.last.lastLineBlank = true
	}
	container.lastLineBlank = p.blank && container.typ != nBlockQuote && container.typ != nHeading &&
		container.typ != nThematicBreak && !(container.typ == nCodeBlock && container.fenced) &&
		!(container.typ == nItem && container.first == nil && container.startLine == p.lineNumber)
	for t := container.parent; t != nil; t = t.parent {
		t.lastLineBlank = false
	}

	if p.current != lastMatched && container == lastMatched && !p.blank && p.current.typ == nParagraph {
		// Lazy continuation line.
		p.addLine(p.current, p.line[p.offset:])
		return
	}
	for p.current != lastMatched {
		p.current = p.finalize(p.current)
	}
	switch {
	case container.typ == nCodeBlock:
		p.addLine(container, p.line[p.offset:])
	case p.blank:
		// nothing to add
	case acceptsLines(container.typ):
		p.advanceOffset(p.firstNonspace-p.offset, false)
		text := p.line[p.offset:]
		if container.typ == nHeading && !container.setext {
			text = chopTrailingHashes(text)
		}
		p.addLine(container, text)
	default:
		container = p.addChild(container, nParagraph)
		p.advanceOffset(p.firstNonspace-p.offset, false)
		p.addLine(container, p.line[p.offset:])
	}
	p.current = container
}

// finalize closes block b and returns its parent.
func (p *parser) finalize(b *node) *node {
	parent := b.parent
	b.open = false
	switch b.typ {
	case nCodeBlock:
		content := string(b.content)
		b.content = nil
		if !b.fenced {
			b.literal = trimTrailingBlankLines(content) + "\n"
		} else {
			nl := 0
			for nl < len(content) && content[nl] != '\n' {
				nl++
			}
			b.info = unescapeBackslashes(trimSpace(decodeEntities(content[:nl])))
			if nl < len(content) {
				b.literal = content[nl+1:]
			}
		}
	case nList:
		b.list.tight = true
	items:
		for item := b.first; item != nil; item = item.next {
			if item.lastLineBlank && item.next != nil {
				b.list.tight = false
				break
			}
			for sub := item.first; sub != nil; sub = sub.next {
				if (item.next != nil || sub.next != nil) && endsWithBlankLine(sub) {
					b.list.tight = false
					break items
				}
			}
		}
	}
	return parent
}

// trimTrailingBlankLines strips trailing blank lines from indented code.
func trimTrailingBlankLines(s string) string {
	i := len(s) - 1
	for i >= 0 && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r') {
		i--
	}
	if i < 0 {
		return ""
	}
	for j := i; j < len(s); j++ {
		if s[j] == '\n' {
			return s[:j]
		}
	}
	return s
}

// endsWithBlankLine reports whether a block ends with a blank line. Like
// cmark it memoises its answers in lastLineChecked, which affects later calls.
func endsWithBlankLine(n *node) bool {
	for cur := n; ; {
		if cur.lastLineChecked {
			return cur.lastLineBlank
		}
		cur.lastLineChecked = true
		if (cur.typ == nList || cur.typ == nItem) && cur.last != nil {
			cur = cur.last
		} else {
			return cur.lastLineBlank
		}
	}
}
