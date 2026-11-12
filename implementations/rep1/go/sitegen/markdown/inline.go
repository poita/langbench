package markdown

import "strings"

// delim is an entry of the delimiter stack: a run of '*' or '_' that may open
// or close emphasis.
type delim struct {
	prev, next *delim
	ch         byte
	origLen    int
	canOpen    bool
	canClose   bool
	node       *node
	pos        int // index just after the run
}

// bracket is an entry of the bracket stack: a '[' or '![' that may open a
// link or image.
type bracket struct {
	prev  *bracket
	node  *node
	pos   int // index just after the '['
	image bool
}

// inlineParser parses the content of one paragraph or heading.
type inlineParser struct {
	s      string
	pos    int
	parent *node

	top      *delim // top of the delimiter stack
	brackets *bracket

	linkClosed bool

	backtickLast    []int // position of the last backtick run of each length met
	backtickScanned bool
}

// parseInlines parses content into inline children of parent.
func parseInlines(parent *node, content string) {
	content = strings.TrimRight(content, " \t\n\v\f\r")
	p := &inlineParser{s: content, parent: parent, linkClosed: true}
	p.parse()
	p.processEmphasis(0)
}

var specialByte = func() (t [256]bool) {
	for _, c := range []byte("\n`\\&<*_[]!") {
		t[c] = true
	}
	return
}()

func (p *inlineParser) addText(lit string) *node {
	n := &node{kind: kText, lit: lit}
	p.parent.appendChild(n)
	return n
}

func (p *inlineParser) parse() {
	s := p.s
	for p.pos < len(s) {
		c := s[p.pos]
		switch c {
		case '\n':
			if p.pos >= 2 && s[p.pos-1] == ' ' && s[p.pos-2] == ' ' {
				p.parent.appendChild(&node{kind: kLineBreak})
			} else {
				p.parent.appendChild(&node{kind: kSoftBreak})
			}
			p.pos++
			for p.pos < len(s) && isSpaceOrTab(s[p.pos]) {
				p.pos++
			}
		case '`':
			p.codeSpan()
		case '\\':
			switch {
			case p.pos+1 < len(s) && isASCIIPunct(s[p.pos+1]):
				p.addText(s[p.pos+1 : p.pos+2])
				p.pos += 2
			case p.pos+1 < len(s) && s[p.pos+1] == '\n':
				p.parent.appendChild(&node{kind: kLineBreak})
				p.pos += 2
			default:
				p.addText("\\")
				p.pos++
			}
		case '&':
			if lit, end, ok := matchEntity(s, p.pos); ok {
				p.addText(lit)
				p.pos = end
			} else {
				p.addText("&")
				p.pos++
			}
		case '<':
			if end, dest, text, ok := scanAutolink(s, p.pos); ok {
				l := &node{kind: kLink, dest: dest}
				l.appendChild(&node{kind: kText, lit: text})
				p.parent.appendChild(l)
				p.pos = end
			} else {
				p.addText("<")
				p.pos++
			}
		case '*', '_':
			p.delimiterRun()
		case '[':
			n := p.addText("[")
			p.pos++
			p.brackets = &bracket{prev: p.brackets, node: n, pos: p.pos}
			p.linkClosed = false
		case '!':
			if p.pos+1 < len(s) && s[p.pos+1] == '[' {
				n := p.addText("![")
				p.pos += 2
				p.brackets = &bracket{prev: p.brackets, node: n, pos: p.pos, image: true}
			} else {
				p.addText("!")
				p.pos++
			}
		case ']':
			p.closeBracket()
		default:
			end := p.pos + 1
			for end < len(s) && !specialByte[s[end]] {
				end++
			}
			text := s[p.pos:end]
			if end < len(s) && s[end] == '\n' {
				text = strings.TrimRight(text, " \t\n\v\f\r")
			}
			if text != "" {
				p.addText(text)
			}
			p.pos = end
		}
	}
}

// codeSpan handles a run of backticks at p.pos.
func (p *inlineParser) codeSpan() {
	s := p.s
	start := p.pos
	for p.pos < len(s) && s[p.pos] == '`' {
		p.pos++
	}
	n := p.pos - start
	closing := p.findBackticks(n, p.pos)
	if closing < 0 {
		p.addText(s[start:p.pos])
		return
	}
	content := strings.ReplaceAll(s[p.pos:closing], "\n", " ")
	if len(content) >= 2 && content[0] == ' ' && content[len(content)-1] == ' ' && strings.Trim(content, " ") != "" {
		content = content[1 : len(content)-1]
	}
	p.parent.appendChild(&node{kind: kCode, lit: content})
	p.pos = closing + n
}

// findBackticks looks for a run of exactly n backticks at or after from. It
// reproduces the memo of the reference implementation: the position of the
// last run of each length seen, and whether a scan has reached the end.
func (p *inlineParser) findBackticks(n, from int) int {
	if p.backtickScanned && p.lastBacktick(n) <= from {
		return -1
	}
	s := p.s
	i := from
	for i < len(s) {
		j := strings.IndexByte(s[i:], '`')
		if j < 0 {
			break
		}
		start := i + j
		k := 0
		for start+k < len(s) && s[start+k] == '`' {
			k++
		}
		for len(p.backtickLast) <= k {
			p.backtickLast = append(p.backtickLast, 0)
		}
		p.backtickLast[k] = start
		if k == n {
			return start
		}
		i = start + k
	}
	p.backtickScanned = true
	return -1
}

func (p *inlineParser) lastBacktick(n int) int {
	if n < len(p.backtickLast) {
		return p.backtickLast[n]
	}
	return 0
}

func isASCIIPunct(c byte) bool {
	return c >= '!' && c <= '/' || c >= ':' && c <= '@' || c >= '[' && c <= '`' || c >= '{' && c <= '~'
}

func (p *inlineParser) delimiterRun() {
	s := p.s
	start := p.pos
	c := s[start]
	for p.pos < len(s) && s[p.pos] == c {
		p.pos++
	}
	n := p.pos - start
	before, after := byte('\n'), byte('\n')
	if start > 0 {
		before = s[start-1]
	}
	if p.pos < len(s) {
		after = s[p.pos]
	}
	beforeSpace, afterSpace := isWhitespace(before), isWhitespace(after)
	beforePunct, afterPunct := isASCIIPunct(before), isASCIIPunct(after)
	left := !afterSpace && (!afterPunct || beforeSpace || beforePunct)
	right := !beforeSpace && (!beforePunct || afterSpace || afterPunct)
	var canOpen, canClose bool
	if c == '*' {
		canOpen, canClose = left, right
	} else {
		canOpen = left && (!right || beforePunct)
		canClose = right && (!left || afterPunct)
	}
	node := p.addText(s[start:p.pos])
	if canOpen || canClose {
		d := &delim{prev: p.top, ch: c, origLen: n, canOpen: canOpen, canClose: canClose, node: node, pos: p.pos}
		if p.top != nil {
			p.top.next = d
		}
		p.top = d
	}
}

// removeDelim unlinks d from the delimiter stack.
func (p *inlineParser) removeDelim(d *delim) {
	if d.prev != nil {
		d.prev.next = d.next
	}
	if d.next != nil {
		d.next.prev = d.prev
	} else {
		p.top = d.prev
	}
}

// processEmphasis resolves the delimiters whose position is at least bottom.
func (p *inlineParser) processEmphasis(bottom int) {
	// Find the first entry at or above bottom.
	closer := p.top
	if closer == nil || closer.pos < bottom {
		return
	}
	for closer.prev != nil && closer.prev.pos >= bottom {
		closer = closer.prev
	}
	var openersBottom [12]int
	for i := range openersBottom {
		openersBottom[i] = bottom
	}
	for closer != nil {
		if !closer.canClose {
			closer = closer.next
			continue
		}
		kind := closer.origLen % 3
		if closer.canOpen {
			kind += 3
		}
		if closer.ch == '_' {
			kind += 6
		}
		var opener *delim
		for o := closer.prev; o != nil && o.pos >= openersBottom[kind]; o = o.prev {
			if o.canOpen && o.ch == closer.ch &&
				(!(closer.canOpen || o.canClose) || closer.origLen%3 == 0 || (o.origLen+closer.origLen)%3 != 0) {
				opener = o
				break
			}
		}
		if opener == nil {
			openersBottom[kind] = closer.pos
			next := closer.next
			if !closer.canOpen {
				p.removeDelim(closer)
			}
			closer = next
			continue
		}
		on, cn := opener.node, closer.node
		use := 1
		if len(on.lit) >= 2 && len(cn.lit) >= 2 {
			use = 2
		}
		on.lit = on.lit[:len(on.lit)-use]
		cn.lit = cn.lit[use:]
		// Drop the delimiters between opener and closer.
		opener.next = closer
		closer.prev = opener
		// Wrap the nodes between the two text nodes.
		w := &node{kind: kEmph}
		if use == 2 {
			w.kind = kStrong
		}
		for n := on.next; n != nil && n != cn; {
			next := n.next
			n.unlink()
			w.appendChild(n)
			n = next
		}
		on.insertAfter(w)
		if on.lit == "" {
			on.unlink()
			p.removeDelim(opener)
		}
		if cn.lit == "" {
			cn.unlink()
			next := closer.next
			p.removeDelim(closer)
			closer = next
		}
	}
	// Remove all entries at or above bottom.
	for p.top != nil && p.top.pos >= bottom {
		p.top = p.top.prev
	}
	if p.top != nil {
		p.top.next = nil
	}
}

func (p *inlineParser) closeBracket() {
	p.pos++ // the ']'
	opener := p.brackets
	if opener == nil {
		p.addText("]")
		return
	}
	if !opener.image && p.linkClosed {
		p.brackets = opener.prev
		p.addText("]")
		return
	}
	dest, title, hasTitle, end, ok := p.parseLinkTail(p.pos)
	if !ok {
		p.brackets = opener.prev
		p.addText("]")
		return
	}
	l := &node{kind: kLink, dest: dest, title: title, hasTitle: hasTitle}
	if opener.image {
		l.kind = kImage
	}
	on := opener.node
	for n := on.next; n != nil; {
		next := n.next
		n.unlink()
		l.appendChild(n)
		n = next
	}
	on.insertAfter(l)
	on.unlink()
	p.processEmphasis(opener.pos)
	p.brackets = opener.prev
	if !opener.image {
		p.linkClosed = true
	}
	p.pos = end
}

// parseLinkTail parses "(destination title)" starting at i, which is the
// position right after the closing bracket.
func (p *inlineParser) parseLinkTail(i int) (dest, title string, hasTitle bool, end int, ok bool) {
	s := p.s
	if i >= len(s) || s[i] != '(' {
		return
	}
	i++
	for i < len(s) && isWhitespace(s[i]) {
		i++
	}
	ds, de, next, found := scanDestination(s, i)
	if !found {
		return
	}
	i = next
	j := i
	for j < len(s) && isWhitespace(s[j]) {
		j++
	}
	var ts, te int
	if j > i {
		if e := scanTitle(s, j); e > 0 {
			ts, te = j, e
			hasTitle = true
			j = e
		}
	}
	for j < len(s) && isWhitespace(s[j]) {
		j++
	}
	if j >= len(s) || s[j] != ')' {
		return
	}
	raw := strings.Trim(s[ds:de], " \t\n\v\f\r")
	dest = unescapeBackslashes(unescapeEntities(raw))
	if hasTitle {
		title = unescapeBackslashes(unescapeEntities(s[ts+1 : te-1]))
	}
	return dest, title, hasTitle, j + 1, true
}

// scanDestination scans a link destination starting at s[i]. It returns the
// bounds [start, end) of the destination text (without any angle brackets)
// and next, the index just after the destination.
func scanDestination(s string, i int) (start, end, next int, ok bool) {
	if i < len(s) && s[i] == '<' {
		j := i + 1
		for j < len(s) {
			c := s[j]
			if c == '>' {
				if j+1 >= len(s) {
					return
				}
				return i + 1, j, j + 1, true
			} else if c == '\\' {
				j += 2
			} else if c == '\n' || c == '<' {
				return
			} else {
				j++
			}
		}
		return
	}
	j := i
	depth := 0
loop:
	for j < len(s) {
		c := s[j]
		switch {
		case c == '\\' && j+1 < len(s) && isASCIIPunct(s[j+1]):
			j += 2
		case c == '(':
			depth++
			j++
			if depth > 32 {
				return
			}
		case c == ')':
			if depth == 0 {
				break loop
			}
			depth--
			j++
		case isWhitespace(c):
			if j == i {
				return
			}
			break loop
		default:
			j++
		}
	}
	if j >= len(s) || depth != 0 {
		return
	}
	return i, j, j, true
}

// scanTitle matches a link title starting at s[i] and returns the index just
// after its closing delimiter, or 0 if there is none. Among the possible
// matches it takes the longest: the closing delimiter, and for the
// parenthesised form also '(', may appear inside only after a backslash.
func scanTitle(s string, i int) int {
	if i >= len(s) {
		return 0
	}
	open := s[i]
	var closeCh byte
	switch open {
	case '"', '\'':
		closeCh = open
	case '(':
		closeCh = ')'
	default:
		return 0
	}
	last := 0
	for j := i + 1; j < len(s); j++ {
		c := s[j]
		if c != closeCh && !(open == '(' && c == '(') {
			continue
		}
		if s[j-1] == '\\' {
			if c == closeCh {
				last = j + 1
			}
			continue
		}
		if c == closeCh {
			return j + 1
		}
		break // a bare '(' inside a parenthesised title
	}
	return last
}

// scanAutolink matches an autolink starting at s[i] == '<'. It returns the
// index after the closing '>', the link destination and the link text.
func scanAutolink(s string, i int) (end int, dest, text string, ok bool) {
	j := i + 1
	// URI autolink: scheme ':' non-space characters '>'.
	if j < len(s) && isASCIILetter(s[j]) {
		k := j + 1
		for k < len(s) && k-j < 32 && (isASCIILetter(s[k]) || isDigit(s[k]) || s[k] == '.' || s[k] == '+' || s[k] == '-') {
			k++
		}
		if k-j >= 2 && k < len(s) && s[k] == ':' {
			m := k + 1
			for m < len(s) && s[m] > ' ' && s[m] != '<' && s[m] != '>' {
				m++
			}
			if m < len(s) && s[m] == '>' {
				t := unescapeEntities(s[j:m])
				return m + 1, t, t, true
			}
		}
	}
	// Email autolink.
	k := j
	for k < len(s) && isEmailLocal(s[k]) {
		k++
	}
	if k == j || k >= len(s) || s[k] != '@' {
		return
	}
	m := k + 1
	for {
		ls := m
		for m < len(s) && (isASCIILetter(s[m]) || isDigit(s[m]) || s[m] == '-') {
			m++
		}
		if m == ls || m-ls > 63 || s[ls] == '-' || s[m-1] == '-' {
			return
		}
		if m < len(s) && s[m] == '.' {
			m++
			continue
		}
		break
	}
	if m >= len(s) || s[m] != '>' {
		return
	}
	t := unescapeEntities(s[j:m])
	return m + 1, "mailto:" + t, t, true
}

func isASCIILetter(c byte) bool { return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' }

func isEmailLocal(c byte) bool {
	return isASCIILetter(c) || isDigit(c) || strings.IndexByte(".!#$%&'*+/=?^_`{|}~-", c) >= 0
}
