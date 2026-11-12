package inline

import (
	"example.com/commonmark/ast"
	"example.com/commonmark/internal/scan"
)

// delimiter is an entry of the delimiter stack: a run of '*' or '_' that may
// open or close emphasis.
type delimiter struct {
	ch       byte
	origLen  int // length of the run as scanned; used by the rule of 3
	canOpen  bool
	canClose bool
	node     *ast.Node // the text node holding the delimiter characters
	pos      int       // index just after the run in the content
	prev     *delimiter
	next     *delimiter
}

// delimiterRun scans a run of '*' or '_' and pushes it on the stack if it
// can open or close emphasis.
func (p *parser) delimiterRun() {
	s := p.s
	c := s[p.pos]
	start := p.pos
	for p.pos < len(s) && s[p.pos] == c {
		p.pos++
	}
	before, after := byte('\n'), byte('\n')
	if start > 0 {
		before = s[start-1]
	}
	if p.pos < len(s) {
		after = s[p.pos]
	}
	afterWS, beforeWS := scan.IsSpace(after), scan.IsSpace(before)
	afterP, beforeP := scan.IsPunct(after), scan.IsPunct(before)
	left := !afterWS && (!afterP || beforeWS || beforeP)
	right := !beforeWS && (!beforeP || afterWS || afterP)
	var canOpen, canClose bool
	if c == '*' {
		canOpen, canClose = left, right
	} else {
		canOpen = left && (!right || beforeP)
		canClose = right && (!left || afterP)
	}
	n := p.text(s[start:p.pos])
	if canOpen || canClose {
		d := &delimiter{ch: c, origLen: p.pos - start, canOpen: canOpen, canClose: canClose,
			node: n, pos: p.pos, prev: p.delims}
		if p.delims != nil {
			p.delims.next = d
		}
		p.delims = d
	}
}

func (p *parser) removeDelimiter(d *delimiter) {
	if d.prev != nil {
		d.prev.next = d.next
	}
	if d.next != nil {
		d.next.prev = d.prev
	} else {
		p.delims = d.prev
	}
}

func bottomIndex(d *delimiter) int {
	i := d.origLen % 3
	if d.canOpen {
		i += 3
	}
	if d.ch == '_' {
		i += 6
	}
	return i
}

// processEmphasis resolves the delimiters whose position is at least bottom
// into emphasis nodes and then removes them from the stack.
func (p *parser) processEmphasis(bottom int) {
	var openersBottom [12]int
	for i := range openersBottom {
		openersBottom[i] = bottom
	}
	var closer *delimiter
	for d := p.delims; d != nil && d.pos >= bottom; d = d.prev {
		closer = d
	}
	for closer != nil {
		if !closer.canClose {
			closer = closer.next
			continue
		}
		idx := bottomIndex(closer)
		opener := closer.prev
		for ; opener != nil && opener.pos >= openersBottom[idx]; opener = opener.prev {
			if opener.canOpen && opener.ch == closer.ch {
				odd := (closer.canOpen || opener.canClose) &&
					closer.origLen%3 != 0 && (opener.origLen+closer.origLen)%3 == 0
				if !odd {
					break
				}
			}
		}
		if opener == nil || opener.pos < openersBottom[idx] {
			openersBottom[idx] = closer.pos
			old := closer
			closer = closer.next
			if !old.canOpen {
				p.removeDelimiter(old)
			}
			continue
		}

		on, cn := opener.node, closer.node
		use := 1
		if len(on.Literal) >= 2 && len(cn.Literal) >= 2 {
			use = 2
		}
		on.Literal = on.Literal[:len(on.Literal)-use]
		cn.Literal = cn.Literal[use:]
		// Drop the delimiters between opener and closer.
		opener.next = closer
		closer.prev = opener
		kind := ast.Emph
		if use == 2 {
			kind = ast.Strong
		}
		em := ast.New(kind)
		if on.Next != cn {
			em.AdoptRange(on.Next, cn.Prev)
		}
		on.InsertAfter(em)
		if on.Literal == "" {
			on.Unlink()
			p.removeDelimiter(opener)
		}
		if cn.Literal == "" {
			cn.Unlink()
			next := closer.next
			p.removeDelimiter(closer)
			closer = next
		}
	}
	for p.delims != nil && p.delims.pos >= bottom {
		p.delims = p.delims.prev
	}
	if p.delims != nil {
		p.delims.next = nil
	}
}
