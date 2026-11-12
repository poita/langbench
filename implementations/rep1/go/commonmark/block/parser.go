// Package block implements the first phase of CommonMark parsing: it reads a
// document line by line and builds the tree of block structures (block
// quotes, lists, list items, paragraphs, headings, thematic breaks and code
// blocks). The raw text of paragraphs and headings is left in the nodes'
// ParseState.Content for the inline phase.
//
// The algorithm is the one in Appendix A of the CommonMark specification, as
// implemented by cmark: every line is matched against the chain of open
// blocks, new blocks are opened, and the rest of the line is added to the
// innermost open leaf.
package block

import (
	"strings"

	"example.com/commonmark/ast"
	"example.com/commonmark/internal/scan"
)

// Parse builds the block tree of src. Paragraph and heading nodes carry their
// unparsed text in State.Content; code blocks carry their text in Literal.
func Parse(src string) *ast.Node {
	p := &parser{doc: ast.New(ast.Document)}
	p.doc.State.Open = true
	p.tip = p.doc
	for len(src) > 0 {
		var line string
		if i := strings.IndexByte(src, '\n'); i < 0 {
			line, src = src, ""
		} else {
			line, src = src[:i], src[i+1:]
		}
		p.processLine(line)
	}
	for p.tip != nil {
		p.tip = p.finalize(p.tip)
	}
	return p.doc
}

type parser struct {
	doc *ast.Node
	tip *ast.Node // innermost open block

	line   string
	lineNo int

	offset     int  // byte offset into line
	column     int  // column of offset, tabs expanded
	partialTab bool // the tab at offset is partially consumed

	// computed by findNextNonspace
	nextNonspace int
	indent       int
	blank        bool

	lastMatched *ast.Node
}

func (p *parser) peek(i int) byte {
	if i < len(p.line) {
		return p.line[i]
	}
	return 0
}

// findNextNonspace computes the first non-space/tab position at or after the
// current offset, the indentation up to it and whether the line is blank
// from here.
func (p *parser) findNextNonspace() {
	i, col := p.offset, p.column
	for i < len(p.line) {
		c := p.line[i]
		if c == ' ' {
			col++
		} else if c == '\t' {
			col += 4 - col%4
		} else {
			break
		}
		i++
	}
	p.blank = i >= len(p.line)
	p.nextNonspace = i
	p.indent = col - p.column
}

// advance moves count characters (or count columns, if columns is set) ahead.
// A tab that is only partly consumed stays at the current offset.
func (p *parser) advance(count int, columns bool) {
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

func (p *parser) advanceToNonspace() { p.advance(p.nextNonspace-p.offset, false) }

// addLine appends the rest of the line to n's content.
func (p *parser) addLine(n *ast.Node) {
	s := n.State
	if p.partialTab {
		p.offset++
		for i := 4 - p.column%4; i > 0; i-- {
			s.Content = append(s.Content, ' ')
		}
	}
	s.Content = append(s.Content, p.line[p.offset:]...)
	s.Content = append(s.Content, '\n')
}

func canContain(parent *ast.Node, k ast.Kind) bool {
	switch parent.Kind {
	case ast.Document, ast.BlockQuote, ast.Item:
		return k != ast.Item
	case ast.List:
		return k == ast.Item
	}
	return false
}

// closeUnmatched closes the open blocks below the last matched block.
func (p *parser) closeUnmatched() {
	for p.tip != p.lastMatched {
		p.tip = p.finalize(p.tip)
	}
}

// addChild adds a new open block of kind k below parent, closing blocks
// until one that can hold it is found.
func (p *parser) addChild(parent *ast.Node, k ast.Kind) *ast.Node {
	p.closeUnmatched()
	for !canContain(parent, k) {
		parent = p.finalize(parent)
	}
	n := ast.New(k)
	n.State.Open = true
	n.State.StartLine = p.lineNo
	parent.AppendChild(n)
	return n
}

const (
	cont = iota // block continues
	fail        // block does not match this line
	done        // line fully consumed (closing fence)
)

// continueBlock checks whether the open block b matches the current line and
// consumes its line prefix if so.
func (p *parser) continueBlock(b *ast.Node) int {
	s := b.State
	switch b.Kind {
	case ast.BlockQuote:
		if p.indent <= 3 && p.peek(p.nextNonspace) == '>' {
			p.advance(p.nextNonspace+1-p.offset, false)
			if scan.IsSpaceOrTab(p.peek(p.offset)) {
				p.advance(1, true)
			}
			return cont
		}
	case ast.Item:
		if p.indent >= s.MarkerOffset+s.Padding {
			p.advance(s.MarkerOffset+s.Padding, true)
			return cont
		}
		if p.blank && b.FirstChild != nil {
			p.advanceToNonspace()
			return cont
		}
	case ast.List, ast.ThematicBreak:
		return cont
	case ast.CodeBlock:
		if !s.Fenced {
			if p.indent >= 4 {
				p.advance(4, true)
				return cont
			}
			if p.blank {
				p.advanceToNonspace()
				return cont
			}
			return fail
		}
		if p.indent <= 3 && p.closingFence(s) {
			p.tip = p.finalize(b)
			return done
		}
		for i := s.FenceOffset; i > 0 && scan.IsSpaceOrTab(p.peek(p.offset)); i-- {
			p.advance(1, true)
		}
		return cont
	case ast.Paragraph:
		if !p.blank {
			return cont
		}
	}
	return fail
}

// closingFence reports whether the line is a closing fence for the fenced
// code block whose state is s.
func (p *parser) closingFence(s *ast.ParseState) bool {
	i := p.nextNonspace
	if p.peek(i) != s.FenceChar {
		return false
	}
	for i < len(p.line) && p.line[i] == s.FenceChar {
		i++
	}
	if i-p.nextNonspace < s.FenceLength {
		return false
	}
	for ; i < len(p.line); i++ {
		if !scan.IsSpaceOrTab(p.line[i]) {
			return false
		}
	}
	return true
}

func (p *parser) processLine(line string) {
	p.line = line
	p.lineNo++
	p.offset, p.column, p.partialTab = 0, 0, false

	// Step 1: continue open blocks.
	container := p.doc
	allMatched := true
	for {
		child := container.LastChild
		if child == nil || !child.State.Open {
			break
		}
		p.findNextNonspace()
		switch p.continueBlock(child) {
		case done:
			return
		case fail:
			allMatched = false
		}
		if !allMatched {
			break
		}
		container = child
	}
	p.lastMatched = container
	oldTip := p.tip

	// Step 2: open new blocks.
	maybeLazy := oldTip.Kind == ast.Paragraph
	for container.Kind != ast.CodeBlock {
		p.findNextNonspace()
		indented := p.indent >= 4
		c := p.peek(p.nextNonspace)
		rest := p.line[p.nextNonspace:]

		if !indented && c == '>' {
			p.advance(p.nextNonspace+1-p.offset, false)
			if scan.IsSpaceOrTab(p.peek(p.offset)) {
				p.advance(1, true)
			}
			container = p.addChild(container, ast.BlockQuote)
		} else if level := atxLevel(rest); !indented && level > 0 {
			j := p.nextNonspace + level
			for j < len(p.line) && scan.IsSpaceOrTab(p.line[j]) {
				j++
			}
			p.advance(j-p.offset, false)
			container = p.addChild(container, ast.Heading)
			container.Level = level
			break
		} else if ch, n := openingFence(rest); !indented && n > 0 {
			container = p.addChild(container, ast.CodeBlock)
			s := container.State
			s.Fenced, s.FenceChar, s.FenceLength = true, ch, n
			s.FenceOffset = p.nextNonspace - p.offset
			p.advance(p.nextNonspace+n-p.offset, false)
			break
		} else if lev := setextLevel(rest); !indented && container.Kind == ast.Paragraph && lev > 0 {
			container.Kind = ast.Heading
			container.Level = lev
			container.State.Setext = true
			p.advance(len(p.line)-p.offset, false)
			break
		} else if !indented && isThematicBreak(rest) {
			container = p.addChild(container, ast.ThematicBreak)
			p.advance(len(p.line)-p.offset, false)
			break
		} else if d, w := p.parseListMarker(container.Kind == ast.Paragraph); !indented && w > 0 && p.indent < 4 {
			markerOffset := p.indent
			p.advanceToNonspace()
			p.advance(w, false)
			savedTab, savedOff, savedCol := p.partialTab, p.offset, p.column
			for p.column-savedCol <= 5 && scan.IsSpaceOrTab(p.peek(p.offset)) {
				p.advance(1, true)
			}
			n := p.column - savedCol
			padding := w + n
			if n >= 5 || n < 1 || p.offset >= len(p.line) {
				padding = w + 1
				p.partialTab, p.offset, p.column = savedTab, savedOff, savedCol
				if n > 0 {
					p.advance(1, true)
				}
			}
			if container.Kind != ast.List || !sameList(container.List, d) {
				container = p.addChild(container, ast.List)
				container.List = d
			}
			container = p.addChild(container, ast.Item)
			container.State.MarkerOffset = markerOffset
			container.State.Padding = padding
		} else if indented && !maybeLazy && !p.blank {
			p.advance(4, true)
			container = p.addChild(container, ast.CodeBlock)
			break
		} else {
			break
		}
		maybeLazy = false
	}

	// Step 3: add the text of the line.
	p.findNextNonspace()
	if p.blank && container.LastChild != nil {
		container.LastChild.State.LastLineBlank = true
	}
	s := container.State
	s.LastLineBlank = p.blank &&
		container.Kind != ast.BlockQuote && container.Kind != ast.Heading &&
		container.Kind != ast.ThematicBreak &&
		!(container.Kind == ast.CodeBlock && s.Fenced) &&
		!(container.Kind == ast.Item && container.FirstChild == nil && s.StartLine == p.lineNo)
	for a := container.Parent; a != nil; a = a.Parent {
		a.State.LastLineBlank = false
	}

	if oldTip != p.lastMatched && container == p.lastMatched && !p.blank && oldTip.Kind == ast.Paragraph {
		p.addLine(oldTip) // lazy continuation
		return
	}
	p.closeUnmatched()
	switch {
	case container.Kind == ast.CodeBlock:
		p.addLine(container)
	case p.blank:
	case container.Kind == ast.Heading || container.Kind == ast.Paragraph:
		if container.Kind == ast.Heading && !s.Setext {
			p.line = chopClosingHashes(p.line, p.offset)
		}
		p.advanceToNonspace()
		p.addLine(container)
	default:
		container = p.addChild(container, ast.Paragraph)
		p.advanceToNonspace()
		p.addLine(container)
	}
	p.tip = container
}

// finalize closes b and returns its parent.
func (p *parser) finalize(b *ast.Node) *ast.Node {
	s := b.State
	s.Open = false
	switch b.Kind {
	case ast.CodeBlock:
		finalizeCode(b)
	case ast.List:
		b.List.Tight = isTight(b)
	}
	return b.Parent
}

func finalizeCode(b *ast.Node) {
	s := b.State
	content := string(s.Content)
	s.Content = nil
	if s.Fenced {
		nl := strings.IndexByte(content, '\n')
		info := content[:nl]
		b.Literal = content[nl+1:]
		b.Info = scan.Unescape(scan.TrimSpace(scan.DecodeEntities(info)))
		return
	}
	// Indented: drop trailing blank lines.
	i := len(content) - 1
	for i >= 0 && (content[i] == ' ' || content[i] == '\t' || content[i] == '\n') {
		i--
	}
	if i < 0 {
		b.Literal = "\n"
		return
	}
	if nl := strings.IndexByte(content[i:], '\n'); nl >= 0 {
		content = content[:i+nl]
	}
	b.Literal = content + "\n"
}

// chopClosingHashes removes the optional closing sequence of an ATX heading
// from line[from:] and returns the line cut after the heading text.
func chopClosingHashes(line string, from int) string {
	rest := scan.TrimRightSpace(line[from:])
	n := len(rest) - 1
	for n >= 0 && rest[n] == '#' {
		n--
	}
	if n != len(rest)-1 && (n < 0 || scan.IsSpace(rest[n])) {
		if n < 0 {
			n = 0
		}
		rest = scan.TrimRightSpace(rest[:n])
	}
	return line[:from+len(rest)]
}
