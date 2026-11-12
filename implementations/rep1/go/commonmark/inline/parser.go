// Package inline implements the second phase of CommonMark parsing: turning
// the raw text of a paragraph or heading into inline nodes (text, breaks, code
// spans, emphasis, links, images and autolinks).
//
// The parser works left to right in one pass. Emphasis uses a delimiter stack
// and the process-emphasis algorithm with openers_bottom bounds; links and
// images use a bracket stack. All of them run in time linear in the length
// of the content.
package inline

import (
	"strings"

	"example.com/commonmark/ast"
	"example.com/commonmark/internal/scan"
)

// ParseAll parses the inline content of every paragraph and heading in the
// block tree rooted at root.
func ParseAll(root *ast.Node) {
	ast.Walk(root, func(n *ast.Node, entering bool) ast.WalkStatus {
		if !entering {
			return ast.Continue
		}
		if n.Kind == ast.Paragraph || n.Kind == ast.Heading {
			Parse(n)
			return ast.SkipChildren
		}
		return ast.Continue
	})
}

// Parse parses the raw content stored in the block's ParseState and appends
// the resulting inline nodes to block.
func Parse(block *ast.Node) {
	content := scan.TrimRightSpace(string(block.State.Content))
	block.State.Content = nil
	p := &parser{s: content, parent: block, linkClosed: true}
	for p.pos < len(p.s) {
		p.parseInline()
	}
	p.processEmphasis(0)
}

type bracket struct {
	node     *ast.Node
	image    bool
	position int
	prev     *bracket
}

type parser struct {
	s      string
	pos    int
	parent *ast.Node

	delims   *delimiter // top of the delimiter stack
	brackets *bracket   // top of the bracket stack

	linkClosed bool

	// backtick memo: last[k] is the start of the most recent run of k
	// backticks seen by a scan; scanned records that a scan hit the end.
	last    []int
	scanned bool
}

func (p *parser) text(s string) *ast.Node {
	n := &ast.Node{Kind: ast.Text, Literal: s}
	p.parent.AppendChild(n)
	return n
}

func (p *parser) add(k ast.Kind) *ast.Node {
	n := &ast.Node{Kind: k}
	p.parent.AppendChild(n)
	return n
}

func isSpecial(c byte) bool {
	switch c {
	case '\n', '`', '\\', '&', '<', '*', '_', '[', ']', '!':
		return true
	}
	return false
}

func (p *parser) parseInline() {
	s := p.s
	switch s[p.pos] {
	case '\n':
		if p.pos >= 2 && s[p.pos-1] == ' ' && s[p.pos-2] == ' ' {
			p.add(ast.Linebreak)
		} else {
			p.add(ast.Softbreak)
		}
		p.pos++
		for p.pos < len(s) && scan.IsSpaceOrTab(s[p.pos]) {
			p.pos++
		}
	case '`':
		p.codeSpan()
	case '\\':
		switch {
		case p.pos+1 < len(s) && scan.IsPunct(s[p.pos+1]):
			p.text(s[p.pos+1 : p.pos+2])
			p.pos += 2
		case p.pos+1 < len(s) && s[p.pos+1] == '\n':
			p.add(ast.Linebreak)
			p.pos += 2
		default:
			p.text("\\")
			p.pos++
		}
	case '&':
		if dec, n := scan.MatchEntity(s[p.pos+1:]); n > 0 {
			p.text(dec)
			p.pos += 1 + n
		} else {
			p.text("&")
			p.pos++
		}
	case '<':
		p.autolink()
	case '*', '_':
		p.delimiterRun()
	case '[':
		p.pos++
		n := p.text("[")
		p.brackets = &bracket{node: n, position: p.pos, prev: p.brackets}
		p.linkClosed = false
	case '!':
		if p.pos+1 < len(s) && s[p.pos+1] == '[' {
			p.pos += 2
			n := p.text("![")
			p.brackets = &bracket{node: n, image: true, position: p.pos, prev: p.brackets}
		} else {
			p.pos++
			p.text("!")
		}
	case ']':
		p.closeBracket()
	default:
		start := p.pos
		p.pos++
		for p.pos < len(s) && !isSpecial(s[p.pos]) {
			p.pos++
		}
		end := p.pos
		if end < len(s) && s[end] == '\n' {
			for end > start && scan.IsSpaceOrTab(s[end-1]) {
				end--
			}
		}
		if end > start {
			p.text(s[start:end])
		}
	}
}

// codeSpan handles a run of backticks at the current position.
func (p *parser) codeSpan() {
	s := p.s
	start := p.pos
	for p.pos < len(s) && s[p.pos] == '`' {
		p.pos++
	}
	n := p.pos - start
	open := p.pos
	end := p.findClosingBackticks(open, n)
	if end < 0 {
		p.text(s[start:open])
		return
	}
	content := s[open : end-n]
	if strings.IndexByte(content, '\n') >= 0 {
		content = strings.ReplaceAll(content, "\n", " ")
	}
	if len(content) >= 2 && content[0] == ' ' && content[len(content)-1] == ' ' &&
		strings.Trim(content, " ") != "" {
		content = content[1 : len(content)-1]
	}
	c := p.add(ast.Code)
	c.Literal = content
	p.pos = end
}

// findClosingBackticks scans for a run of exactly n backticks starting at or
// after from and returns the position just after it, or -1. It maintains the
// memo that makes repeated failing searches cost O(1).
func (p *parser) findClosingBackticks(from, n int) int {
	if p.scanned && n < len(p.last) && p.last[n] <= from {
		return -1
	}
	if p.scanned && n >= len(p.last) {
		return -1
	}
	s := p.s
	i := from
	for {
		j := strings.IndexByte(s[i:], '`')
		if j < 0 {
			break
		}
		i += j
		k := i
		for k < len(s) && s[k] == '`' {
			k++
		}
		run := k - i
		for len(p.last) <= run {
			p.last = append(p.last, 0)
		}
		p.last[run] = i
		if run == n {
			return k
		}
		i = k
	}
	p.scanned = true
	return -1
}
