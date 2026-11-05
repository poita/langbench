package commonmark

import "bytes"

// blockParser implements phase 1 of the CommonMark algorithm: it consumes
// the input line by line and maintains the chain of open blocks.
type blockParser struct {
	line   []byte
	lineNo int

	// Position within the line: byte offset, the column it corresponds to
	// (tabs advance to the next multiple of 4) and whether the tab at
	// offset has been partially consumed.
	offset     int
	column     int
	partialTab bool

	// Results of findFirstNonspace for the current position.
	firstNonspace int
	indent        int
	blank         bool

	root *block
	// tip is the innermost open block ("current" in cmark).
	tip *block
}

func parseBlocks(src []byte) *block {
	root := &block{kind: kDocument, open: true}
	p := &blockParser{root: root, tip: root}
	for len(src) > 0 {
		var line []byte
		if i := bytes.IndexByte(src, '\n'); i >= 0 {
			line, src = src[:i], src[i+1:]
		} else {
			line, src = src, nil
		}
		p.processLine(line)
	}
	for p.tip != p.root {
		p.tip = p.finalize(p.tip)
	}
	p.finalize(p.root)
	return root
}

func (p *blockParser) peek(i int) byte {
	if i < len(p.line) {
		return p.line[i]
	}
	return '\n'
}

// findFirstNonspace computes the first non-space/tab position at or after
// the current offset, the indentation in columns and the blank flag.
func (p *blockParser) findFirstNonspace() {
	i, col := p.offset, p.column
	toTab := 4 - col%4
	for i < len(p.line) {
		c := p.line[i]
		if c == ' ' {
			i++
			col++
			toTab--
			if toTab == 0 {
				toTab = 4
			}
		} else if c == '\t' {
			i++
			col += toTab
			toTab = 4 - col%4
		} else {
			break
		}
	}
	p.firstNonspace = i
	p.indent = col - p.column
	p.blank = i >= len(p.line)
}

// advance moves the position forward by count characters (or, when columns
// is true, count columns, possibly consuming only part of a tab).
func (p *blockParser) advance(count int, columns bool) {
	for count > 0 && p.offset < len(p.line) {
		if p.line[p.offset] == '\t' {
			toTab := 4 - p.column%4
			if columns {
				p.partialTab = toTab > count
				n := min(count, toTab)
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

// addLine appends the rest of the line plus a newline to b's content,
// expanding a partially consumed tab into spaces.
func (p *blockParser) addLine(b *block) {
	off := p.offset
	if p.partialTab {
		off++
		for n := 4 - p.column%4; n > 0; n-- {
			b.content = append(b.content, ' ')
		}
	}
	if off < len(p.line) {
		b.content = append(b.content, p.line[off:]...)
	}
	b.content = append(b.content, '\n')
}

func (p *blockParser) processLine(line []byte) {
	p.line = line
	p.lineNo++
	p.offset, p.column, p.partialTab = 0, 0, false

	// Step 1: continue open blocks.
	lastMatched, allMatched, stop := p.checkOpenBlocks()
	if stop {
		return
	}
	// Step 2: start new blocks.
	container := p.openNewBlocks(lastMatched, allMatched)
	// Step 3: add the text of the line.
	p.addText(container, lastMatched)
}

// checkOpenBlocks walks the chain of open blocks and returns the last
// block that matched the line. stop is true when the line was a closing
// code fence and needs no further processing.
func (p *blockParser) checkOpenBlocks() (container *block, allMatched, stop bool) {
	container = p.root
	for container.last != nil && container.last.open {
		container = container.last
		p.findFirstNonspace()
		ok := true
		switch container.kind {
		case kBlockQuote:
			if p.indent <= 3 && p.peek(p.firstNonspace) == '>' {
				p.advance(p.firstNonspace+1-p.offset, false)
				if isSpaceOrTab(p.peek(p.offset)) {
					p.advance(1, true)
				}
			} else {
				ok = false
			}
		case kItem:
			if p.indent >= container.markerOffset+container.padding {
				p.advance(container.markerOffset+container.padding, true)
			} else if p.blank && container.first != nil {
				p.advance(p.firstNonspace-p.offset, false)
			} else {
				ok = false
			}
		case kCodeBlock:
			if !container.fenced {
				if p.indent >= 4 {
					p.advance(4, true)
				} else if p.blank {
					p.advance(p.firstNonspace-p.offset, false)
				} else {
					ok = false
				}
			} else {
				if p.indent <= 3 && p.peek(p.firstNonspace) == container.fenceChar &&
					scanFenceClose(p.line, p.firstNonspace, container.fenceChar) >= container.fenceLen {
					p.tip = p.finalize(container)
					return nil, false, true
				}
				for i := container.fenceOffset; i > 0 && isSpaceOrTab(p.peek(p.offset)); i-- {
					p.advance(1, true)
				}
			}
		case kHeading:
			ok = false
		case kParagraph:
			if p.blank {
				ok = false
			}
		}
		if !ok {
			return container.parent, false, false
		}
	}
	return container, true, false
}

// addChild adds a new block of the given kind below container, closing
// blocks that cannot hold it.
func (p *blockParser) addChild(container *block, kind blockKind) *block {
	for !canContain(container.kind, kind) {
		container = p.finalize(container)
	}
	b := &block{kind: kind, open: true, startLine: p.lineNo}
	container.appendChild(b)
	return b
}

func (p *blockParser) openNewBlocks(container *block, allMatched bool) *block {
	maybeLazy := p.tip.kind == kParagraph
	for container.kind != kCodeBlock {
		p.findFirstNonspace()
		indented := p.indent >= 4
		c := p.peek(p.firstNonspace)
		fn := p.firstNonspace

		if !indented && c == '>' {
			p.advance(fn+1-p.offset, false)
			if isSpaceOrTab(p.peek(p.offset)) {
				p.advance(1, true)
			}
			container = p.addChild(container, kBlockQuote)
		} else if level, end, ok := scanATXStartIf(!indented, p.line, fn); ok {
			p.advance(end-p.offset, false)
			container = p.addChild(container, kHeading)
			container.level = level
		} else if fc, n, ok := scanFenceStartIf(!indented, p.line, fn); ok {
			off := fn - p.offset
			container = p.addChild(container, kCodeBlock)
			container.fenced = true
			container.fenceChar = fc
			container.fenceLen = n
			container.fenceOffset = off
			p.advance(fn+n-p.offset, false)
		} else if lev := p.setextLevel(!indented && container.kind == kParagraph, fn); lev > 0 {
			container.kind = kHeading
			container.level = lev
			container.setext = true
			p.advance(len(p.line)-p.offset, false)
		} else if !indented && scanThematicBreak(p.line, fn) {
			container = p.addChild(container, kThematicBreak)
			p.advance(len(p.line)-p.offset, false)
		} else if m, ok := p.listStart(indented, container, fn); ok {
			container = p.openListItem(container, m)
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
	return container
}

func scanATXStartIf(cond bool, line []byte, i int) (int, int, bool) {
	if !cond {
		return 0, 0, false
	}
	return scanATXStart(line, i)
}

func scanFenceStartIf(cond bool, line []byte, i int) (byte, int, bool) {
	if !cond {
		return 0, 0, false
	}
	return scanFenceStart(line, i)
}

func (p *blockParser) setextLevel(cond bool, fn int) int {
	if !cond {
		return 0
	}
	return scanSetextUnderline(p.line, fn)
}

func (p *blockParser) listStart(indented bool, container *block, fn int) (listMarker, bool) {
	if indented {
		return listMarker{}, false
	}
	return scanListMarker(p.line, fn, container.kind == kParagraph)
}

// openListItem consumes the marker and the padding after it and opens the
// list (when needed) and the list item.
func (p *blockParser) openListItem(container *block, m listMarker) *block {
	markerOffset := p.indent
	p.advance(p.firstNonspace-p.offset, false)
	p.advance(m.width, true)

	saveOffset, saveColumn, savePartial := p.offset, p.column, p.partialTab
	for p.column-saveColumn <= 5 && isSpaceOrTab(p.peek(p.offset)) {
		p.advance(1, true)
	}
	n := p.column - saveColumn
	var padding int
	if n >= 5 || n < 1 || p.offset >= len(p.line) {
		padding = m.width + 1
		p.offset, p.column, p.partialTab = saveOffset, saveColumn, savePartial
		if n > 0 {
			p.advance(1, true)
		}
	} else {
		padding = m.width + n
	}

	if container.kind != kList || container.ordered != m.ordered || container.listChar != m.char {
		container = p.addChild(container, kList)
		container.ordered = m.ordered
		container.listChar = m.char
		container.start = m.start
	}
	item := p.addChild(container, kItem)
	item.markerOffset = markerOffset
	item.padding = padding
	return item
}

func (p *blockParser) addText(container, lastMatched *block) {
	p.findFirstNonspace()
	if p.blank && container.last != nil {
		container.last.lastLineBlank = true
	}
	lastBlank := p.blank
	switch container.kind {
	case kBlockQuote, kHeading, kThematicBreak:
		lastBlank = false
	case kCodeBlock:
		if container.fenced {
			lastBlank = false
		}
	case kItem:
		if container.first == nil && container.startLine == p.lineNo {
			lastBlank = false
		}
	}
	container.lastLineBlank = lastBlank
	for t := container.parent; t != nil; t = t.parent {
		t.lastLineBlank = false
	}

	if p.tip != lastMatched && container == lastMatched && !p.blank && p.tip.kind == kParagraph {
		// Lazy continuation line.
		p.addLine(p.tip)
		return
	}
	for p.tip != lastMatched {
		p.tip = p.finalize(p.tip)
	}
	switch {
	case container.kind == kCodeBlock:
		p.addLine(container)
	case p.blank:
	case acceptsLines(container.kind):
		if container.kind == kHeading && !container.setext {
			p.line = chopTrailingHashes(p.line)
			p.findFirstNonspace()
		}
		p.advance(p.firstNonspace-p.offset, false)
		p.addLine(container)
	default:
		container = p.addChild(container, kParagraph)
		p.advance(p.firstNonspace-p.offset, false)
		p.addLine(container)
	}
	p.tip = container
}

// chopTrailingHashes removes trailing whitespace and the optional closing
// sequence of an ATX heading from line.
func chopTrailingHashes(line []byte) []byte {
	line = trimRightWhitespace(line)
	if len(line) == 0 {
		return line
	}
	n := len(line) - 1
	for n >= 0 && line[n] == '#' {
		n--
	}
	if n != len(line)-1 && (n < 0 || isSpaceOrTab(line[n])) {
		return trimRightWhitespace(line[:max(n, 0)])
	}
	return line
}

// finalize closes b and returns its parent.
func (p *blockParser) finalize(b *block) *block {
	b.open = false
	switch b.kind {
	case kCodeBlock:
		if b.fenced {
			i := bytes.IndexByte(b.content, '\n')
			if i < 0 {
				i = len(b.content)
			}
			b.info = cleanInfo(b.content[:i])
			if i < len(b.content) {
				i++
			}
			b.content = b.content[i:]
		} else {
			b.content = trimTrailingBlankLines(b.content)
		}
	case kList:
		b.tight = listIsTight(b)
	}
	return b.parent
}

// cleanInfo decodes entities, trims and unescapes a fence info string.
func cleanInfo(s []byte) []byte {
	s = decodeEntities(s)
	s = trimWhitespace(s)
	return unescapeBackslashes(s)
}

// trimTrailingBlankLines drops trailing blank lines of an indented code
// block and makes sure the content ends in exactly one newline.
func trimTrailingBlankLines(s []byte) []byte {
	i := len(s) - 1
	for ; i >= 0; i-- {
		if c := s[i]; c != ' ' && c != '\t' && c != '\n' && c != '\r' {
			break
		}
	}
	if i < 0 {
		return append(s[:0], '\n')
	}
	if j := bytes.IndexByte(s[i:], '\n'); j >= 0 {
		s = s[:i+j]
	}
	return append(s, '\n')
}

// listIsTight implements the tight/loose test, including the per-block
// memoisation of "ends with a blank line" that cmark uses.
func listIsTight(list *block) bool {
	for item := list.first; item != nil; item = item.next {
		if item.lastLineBlank && item.next != nil {
			return false
		}
		for sub := item.first; sub != nil; sub = sub.next {
			if (item.next != nil || sub.next != nil) && endsWithBlankLine(sub) {
				return false
			}
		}
	}
	return true
}

func endsWithBlankLine(b *block) bool {
	for cur := b; cur != nil; {
		if cur.lastLineChecked {
			return cur.lastLineBlank
		}
		cur.lastLineChecked = true
		if (cur.kind != kList && cur.kind != kItem) || cur.last == nil {
			return cur.lastLineBlank
		}
		cur = cur.last
	}
	return false
}
