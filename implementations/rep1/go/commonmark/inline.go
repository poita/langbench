package commonmark

import "bytes"

// inlineKind identifies the type of an inline node.
type inlineKind uint8

const (
	inRoot inlineKind = iota
	inText
	inSoftbreak
	inLinebreak
	inCode
	inEmph
	inStrong
	inLink
	inImage
)

// inode is a node of the inline tree. Nodes live in an arena and refer to
// each other by index; index 0 means "none".
type inode struct {
	text                            []byte // literal of text and code nodes
	parent, first, last, next, prev int32
	link                            int32 // index into inlineParser.links
	kind                            inlineKind
}

// linkInfo holds the destination and title of a link or image.
type linkInfo struct {
	dest, title []byte
	hasTitle    bool
}

// delim is an entry of the delimiter stack (a doubly linked list over a
// slice; index 0 is the "none" sentinel).
type delim struct {
	prev, next int32
	node       int32 // the text node holding the delimiter run
	pos        int32 // content index just after the run
	length     int32 // original run length
	ch         byte
	canOpen    bool
	canClose   bool
}

// bracket is an entry of the bracket stack.
type bracket struct {
	node  int32
	pos   int32 // content index just after the '['
	image bool
}

// specialChars marks the bytes that end a plain-text run.
var specialChars [256]bool

func init() {
	for _, c := range []byte("\n`\\&<*_[]!") {
		specialChars[c] = true
	}
}

// inlineParser implements phase 2 for one leaf block at a time. All its
// storage is reused between blocks.
type inlineParser struct {
	s    []byte
	pos  int
	root int32

	nodes  []inode
	links  []linkInfo
	delims []delim
	top    int32 // top of the delimiter stack

	brackets   []bracket
	linkClosed bool

	// Code span memo: the start of the backtick run of each length most
	// recently met by a closer search, and whether a search reached the end.
	btLast    [128]int
	btScanned bool
}

// parse parses content into the inline tree and returns the root node.
func (ip *inlineParser) parse(content []byte) int32 {
	s := trimRightWhitespace(content)
	ip.s, ip.pos = s, 0
	ip.nodes = append(ip.nodes[:0], inode{}, inode{kind: inRoot})
	ip.root = 1
	ip.links = append(ip.links[:0], linkInfo{})
	ip.delims = append(ip.delims[:0], delim{})
	ip.top = 0
	ip.brackets = ip.brackets[:0]
	ip.linkClosed = true
	ip.btLast = [128]int{}
	ip.btScanned = false

	for ip.pos < len(s) {
		switch s[ip.pos] {
		case '\n':
			ip.handleNewline()
		case '`':
			ip.handleBackticks()
		case '\\':
			ip.handleBackslash()
		case '&':
			ip.handleEntity()
		case '<':
			ip.handleLessThan()
		case '*', '_':
			ip.handleDelimRun()
		case '[':
			ip.addText(s[ip.pos : ip.pos+1])
			ip.brackets = append(ip.brackets, bracket{ip.lastChild(), int32(ip.pos + 1), false})
			ip.linkClosed = false
			ip.pos++
		case '!':
			if ip.pos+1 < len(s) && s[ip.pos+1] == '[' {
				ip.addText(s[ip.pos : ip.pos+2])
				ip.brackets = append(ip.brackets, bracket{ip.lastChild(), int32(ip.pos + 2), true})
				ip.pos += 2
			} else {
				ip.addText(s[ip.pos : ip.pos+1])
				ip.pos++
			}
		case ']':
			ip.handleCloseBracket()
		default:
			ip.handleText()
		}
	}
	ip.processEmphasis(0)
	return ip.root
}

// ---- node helpers ---------------------------------------------------

func (ip *inlineParser) newNode(kind inlineKind, text []byte) int32 {
	ip.nodes = append(ip.nodes, inode{kind: kind, text: text})
	return int32(len(ip.nodes) - 1)
}

func (ip *inlineParser) lastChild() int32 { return ip.nodes[ip.root].last }

// appendChild appends n to the end of parent's children.
func (ip *inlineParser) appendChild(parent, n int32) {
	p := &ip.nodes[parent]
	ip.nodes[n].parent = parent
	ip.nodes[n].prev = p.last
	ip.nodes[n].next = 0
	if p.last != 0 {
		ip.nodes[p.last].next = n
	} else {
		p.first = n
	}
	p.last = n
}

// unlink removes n from its parent's child list.
func (ip *inlineParser) unlink(n int32) {
	nd := &ip.nodes[n]
	p := &ip.nodes[nd.parent]
	if nd.prev != 0 {
		ip.nodes[nd.prev].next = nd.next
	} else {
		p.first = nd.next
	}
	if nd.next != 0 {
		ip.nodes[nd.next].prev = nd.prev
	} else {
		p.last = nd.prev
	}
	nd.parent, nd.prev, nd.next = 0, 0, 0
}

// addText appends a text node to the current inline container.
func (ip *inlineParser) addText(t []byte) {
	if len(t) == 0 {
		return
	}
	ip.appendChild(ip.root, ip.newNode(inText, t))
}

// wrapBetween creates a node of the given kind containing all siblings
// strictly between nodes a and b, and inserts it between them.
func (ip *inlineParser) wrapBetween(kind inlineKind, a, b int32) int32 {
	w := ip.newNode(kind, nil)
	parent := ip.nodes[a].parent
	first := ip.nodes[a].next
	var last int32
	if first != b {
		last = ip.nodes[b].prev
		for n := first; ; n = ip.nodes[n].next {
			ip.nodes[n].parent = w
			if n == last {
				break
			}
		}
		ip.nodes[w].first, ip.nodes[w].last = first, last
		ip.nodes[first].prev = 0
		ip.nodes[last].next = 0
	}
	ip.nodes[w].parent = parent
	ip.nodes[w].prev = a
	ip.nodes[w].next = b
	ip.nodes[a].next = w
	ip.nodes[b].prev = w
	return w
}

// ---- simple constructs ---------------------------------------------

func (ip *inlineParser) handleText() {
	s := ip.s
	start := ip.pos
	i := start + 1
	for i < len(s) && !specialChars[s[i]] {
		i++
	}
	end := i
	if i < len(s) && s[i] == '\n' {
		for end > start && isWhitespace(s[end-1]) {
			end--
		}
	}
	ip.addText(s[start:end])
	ip.pos = i
}

func (ip *inlineParser) handleNewline() {
	s := ip.s
	i := ip.pos
	kind := inSoftbreak
	if i >= 2 && s[i-1] == ' ' && s[i-2] == ' ' {
		kind = inLinebreak
	}
	ip.appendChild(ip.root, ip.newNode(kind, nil))
	i++
	for i < len(s) && isSpaceOrTab(s[i]) {
		i++
	}
	ip.pos = i
}

func (ip *inlineParser) handleBackslash() {
	s := ip.s
	i := ip.pos
	switch {
	case i+1 < len(s) && isASCIIPunct(s[i+1]):
		ip.addText(s[i+1 : i+2])
		ip.pos += 2
	case i+1 < len(s) && s[i+1] == '\n':
		ip.appendChild(ip.root, ip.newNode(inLinebreak, nil))
		ip.pos += 2
	default:
		ip.addText(s[i : i+1])
		ip.pos++
	}
}

func (ip *inlineParser) handleEntity() {
	if dec, end, ok := matchEntity(ip.s, ip.pos); ok {
		ip.addText(dec)
		ip.pos = end
		return
	}
	ip.addText(ip.s[ip.pos : ip.pos+1])
	ip.pos++
}

func (ip *inlineParser) handleLessThan() {
	if text, email, end, ok := scanAutolink(ip.s, ip.pos); ok {
		dest := decodeEntities(text)
		label := dest
		if email {
			dest = append([]byte("mailto:"), dest...)
		}
		ip.links = append(ip.links, linkInfo{dest: dest})
		n := ip.newNode(inLink, nil)
		ip.nodes[n].link = int32(len(ip.links) - 1)
		ip.appendChild(ip.root, n)
		ip.appendChild(n, ip.newNode(inText, label))
		ip.pos = end
		return
	}
	ip.addText(ip.s[ip.pos : ip.pos+1])
	ip.pos++
}

// handleBackticks parses a code span, using the per-length memo of the
// positions of backtick runs to keep the search linear.
func (ip *inlineParser) handleBackticks() {
	s := ip.s
	start := ip.pos
	p := start
	for p < len(s) && s[p] == '`' {
		p++
	}
	n := p - start
	if end, ok := ip.findBacktickCloser(p, n); ok {
		content := make([]byte, 0, end-n-p)
		for _, c := range s[p : end-n] {
			if c == '\n' {
				c = ' '
			}
			content = append(content, c)
		}
		if len(content) >= 2 && content[0] == ' ' && content[len(content)-1] == ' ' &&
			len(bytes.TrimLeft(content, " ")) > 0 {
			content = content[1 : len(content)-1]
		}
		ip.appendChild(ip.root, ip.newNode(inCode, content))
		ip.pos = end
		return
	}
	ip.addText(s[start:p])
	ip.pos = p
}

// findBacktickCloser looks for a run of exactly n backticks at or after p
// and returns the index just after it.
func (ip *inlineParser) findBacktickCloser(p, n int) (int, bool) {
	if n >= len(ip.btLast) {
		return ip.scanBackticks(p, n, false)
	}
	if ip.btScanned && ip.btLast[n] <= p {
		return 0, false
	}
	return ip.scanBackticks(p, n, true)
}

func (ip *inlineParser) scanBackticks(p, n int, memo bool) (int, bool) {
	s := ip.s
	for {
		i := bytes.IndexByte(s[p:], '`')
		if i < 0 {
			if memo {
				ip.btScanned = true
			}
			return 0, false
		}
		st := p + i
		e := st
		for e < len(s) && s[e] == '`' {
			e++
		}
		k := e - st
		if memo && k < len(ip.btLast) {
			ip.btLast[k] = st
		}
		if k == n {
			return e, true
		}
		p = e
	}
}

// ---- emphasis delimiters --------------------------------------------

func (ip *inlineParser) handleDelimRun() {
	s := ip.s
	start := ip.pos
	ch := s[start]
	end := start
	for end < len(s) && s[end] == ch {
		end++
	}
	before, after := byte('\n'), byte('\n')
	if start > 0 {
		before = s[start-1]
	}
	if end < len(s) {
		after = s[end]
	}
	afterWS, beforeWS := isWhitespace(after), isWhitespace(before)
	afterP, beforeP := isASCIIPunct(after), isASCIIPunct(before)
	left := !afterWS && (!afterP || beforeWS || beforeP)
	right := !beforeWS && (!beforeP || afterWS || afterP)
	var canOpen, canClose bool
	if ch == '*' {
		canOpen, canClose = left, right
	} else {
		canOpen = left && (!right || beforeP)
		canClose = right && (!left || afterP)
	}
	ip.addText(s[start:end])
	ip.pos = end
	if canOpen || canClose {
		ip.delims = append(ip.delims, delim{
			prev: ip.top, node: ip.lastChild(), pos: int32(end),
			length: int32(end - start), ch: ch, canOpen: canOpen, canClose: canClose,
		})
		id := int32(len(ip.delims) - 1)
		if ip.top != 0 {
			ip.delims[ip.top].next = id
		}
		ip.top = id
	}
}

// removeDelim unlinks entry d from the delimiter stack.
func (ip *inlineParser) removeDelim(d int32) {
	e := &ip.delims[d]
	if e.prev != 0 {
		ip.delims[e.prev].next = e.next
	}
	if e.next != 0 {
		ip.delims[e.next].prev = e.prev
	} else {
		ip.top = e.prev
	}
}

// processEmphasis resolves emphasis among the delimiter entries whose
// position is at least bottom, then discards those entries.
func (ip *inlineParser) processEmphasis(bottom int32) {
	var first int32
	for d := ip.top; d != 0 && ip.delims[d].pos >= bottom; d = ip.delims[d].prev {
		first = d
	}
	if first == 0 {
		return
	}
	below := ip.delims[first].prev

	var openersBottom [12]int32
	for i := range openersBottom {
		openersBottom[i] = bottom
	}
	closer := first
	for closer != 0 {
		c := &ip.delims[closer]
		if !c.canClose {
			closer = c.next
			continue
		}
		kind := int(c.length % 3)
		if c.canOpen {
			kind += 3
		}
		if c.ch == '_' {
			kind += 6
		}
		var opener int32
		for o := c.prev; o != 0 && ip.delims[o].pos >= openersBottom[kind]; o = ip.delims[o].prev {
			od := &ip.delims[o]
			if od.canOpen && od.ch == c.ch {
				bothEnds := c.canOpen || od.canClose
				if !bothEnds || c.length%3 == 0 || (od.length+c.length)%3 != 0 {
					opener = o
					break
				}
			}
		}
		if opener == 0 {
			openersBottom[kind] = c.pos
			next := c.next
			if !c.canOpen {
				ip.removeDelim(closer)
			}
			closer = next
			continue
		}

		od := &ip.delims[opener]
		opNode, clNode := od.node, c.node
		use := 1
		if len(ip.nodes[opNode].text) >= 2 && len(ip.nodes[clNode].text) >= 2 {
			use = 2
		}
		ot, ct := ip.nodes[opNode].text, ip.nodes[clNode].text
		ip.nodes[opNode].text = ot[:len(ot)-use]
		ip.nodes[clNode].text = ct[use:]
		// Drop the entries strictly between opener and closer.
		od.next = closer
		c.prev = opener
		kindNode := inEmph
		if use == 2 {
			kindNode = inStrong
		}
		ip.wrapBetween(kindNode, opNode, clNode)
		if len(ip.nodes[opNode].text) == 0 {
			ip.unlink(opNode)
			ip.removeDelim(opener)
		}
		if len(ip.nodes[clNode].text) == 0 {
			ip.unlink(clNode)
			next := c.next
			ip.removeDelim(closer)
			closer = next
		}
	}
	ip.top = below
	if below != 0 {
		ip.delims[below].next = 0
	}
}

// ---- links and images ------------------------------------------------

func (ip *inlineParser) handleCloseBracket() {
	s := ip.s
	if len(ip.brackets) == 0 {
		ip.addText(s[ip.pos : ip.pos+1])
		ip.pos++
		return
	}
	op := ip.brackets[len(ip.brackets)-1]
	if !op.image && ip.linkClosed {
		ip.brackets = ip.brackets[:len(ip.brackets)-1]
		ip.addText(s[ip.pos : ip.pos+1])
		ip.pos++
		return
	}
	info, end, ok := ip.parseInlineLink(ip.pos + 1)
	if !ok {
		ip.brackets = ip.brackets[:len(ip.brackets)-1]
		ip.addText(s[ip.pos : ip.pos+1])
		ip.pos++
		return
	}
	kind := inLink
	if op.image {
		kind = inImage
	}
	ip.links = append(ip.links, info)
	n := ip.wrapAfter(kind, op.node)
	ip.nodes[n].link = int32(len(ip.links) - 1)
	ip.unlink(op.node)
	ip.processEmphasis(op.pos)
	ip.brackets = ip.brackets[:len(ip.brackets)-1]
	if !op.image {
		ip.linkClosed = true
	}
	ip.pos = end
}

// wrapAfter creates a node of the given kind that takes over all the
// nodes following opener and appends it to the container.
func (ip *inlineParser) wrapAfter(kind inlineKind, opener int32) int32 {
	n := ip.newNode(kind, nil)
	ip.appendChild(ip.root, n)
	// appendChild placed n last; now move everything between opener and n.
	first := ip.nodes[opener].next
	if first != n {
		last := ip.nodes[n].prev
		for c := first; ; c = ip.nodes[c].next {
			ip.nodes[c].parent = n
			if c == last {
				break
			}
		}
		ip.nodes[n].first, ip.nodes[n].last = first, last
		ip.nodes[first].prev = 0
		ip.nodes[last].next = 0
		ip.nodes[opener].next = n
		ip.nodes[n].prev = opener
	}
	return n
}

// parseInlineLink parses "(destination title)" starting at s[i] and
// returns the cleaned link data and the index just after the ')'.
func (ip *inlineParser) parseInlineLink(i int) (info linkInfo, end int, ok bool) {
	s := ip.s
	if i >= len(s) || s[i] != '(' {
		return info, 0, false
	}
	i = skipWhitespace(s, i+1)
	raw, endURL, ok := scanDestination(s, i)
	if !ok {
		return info, 0, false
	}
	j := skipWhitespace(s, endURL)
	if j > endURL && j < len(s) && (s[j] == '"' || s[j] == '\'' || s[j] == '(') {
		if e := scanTitle(s, j); e >= 0 {
			info.title = cleanTitle(s[j+1 : e-1])
			info.hasTitle = true
			j = e
		}
	}
	j = skipWhitespace(s, j)
	if j >= len(s) || s[j] != ')' {
		return info, 0, false
	}
	info.dest = cleanDestination(raw)
	return info, j + 1, true
}
