package markdown

// This file implements phase 2: parsing the raw text of paragraphs and
// headings into inline nodes (cmark's inlines.c): a left-to-right scan with a
// delimiter stack for emphasis and a bracket stack for links and images.

// delimiter is an entry of the delimiter stack (a doubly linked list).
type delimiter struct {
	prev, next *delimiter
	text       *node
	ch         byte
	origLen    int
	canOpen    bool
	canClose   bool
	position   int
}

// bracket is an entry of the bracket stack.
type bracket struct {
	image    bool
	text     *node
	position int
}

type subject struct {
	s          string
	pos        int
	parent     *node
	lastDelim  *delimiter
	brackets   []bracket
	linkClosed bool

	// Backtick memo: last[k] is the start of the most recent run of k backticks
	// met by a closer search; scanned is set once a search reached the end.
	backticks [101]int
	scanned   bool
}

// parseBlockInlines parses the inline content of every leaf block below n.
// Block nesting is bounded, so plain recursion is fine here.
func parseBlockInlines(n *node) {
	if n.typ == nParagraph || n.typ == nHeading {
		parseInlines(n)
		return
	}
	for c := n.first; c != nil; c = c.next {
		parseBlockInlines(c)
	}
}

func parseInlines(block *node) {
	sub := &subject{
		s:          rtrimSpace(string(block.content)),
		parent:     block,
		linkClosed: true,
	}
	block.content = nil
	for sub.pos < len(sub.s) {
		sub.parseInline()
	}
	sub.processEmphasis(0)
}

func (s *subject) peek(i int) byte {
	if i >= 0 && i < len(s.s) {
		return s.s[i]
	}
	return 0
}

func (s *subject) add(n *node) { s.parent.appendChild(n) }

func (s *subject) addText(text string) {
	s.add(&node{typ: nText, literal: text})
}

func isSpecial(c byte) bool {
	switch c {
	case '\n', '`', '\\', '&', '<', '*', '_', '[', ']', '!':
		return true
	}
	return false
}

func (s *subject) parseInline() {
	c := s.s[s.pos]
	switch c {
	case '\n':
		s.handleNewline()
	case '`':
		s.handleBackticks()
	case '\\':
		s.handleBackslash()
	case '&':
		s.handleEntity()
	case '<':
		s.handlePointyBrace()
	case '*', '_':
		s.handleDelim(c)
	case '[':
		s.pos++
		n := &node{typ: nText, literal: "["}
		s.add(n)
		s.brackets = append(s.brackets, bracket{text: n, position: s.pos})
		s.linkClosed = false
	case '!':
		s.pos++
		if s.peek(s.pos) == '[' {
			s.pos++
			n := &node{typ: nText, literal: "!["}
			s.add(n)
			s.brackets = append(s.brackets, bracket{image: true, text: n, position: s.pos})
		} else {
			s.addText("!")
		}
	case ']':
		s.handleCloseBracket()
	default:
		start := s.pos
		end := start + 1
		for end < len(s.s) && !isSpecial(s.s[end]) {
			end++
		}
		text := s.s[start:end]
		s.pos = end
		if end < len(s.s) && s.s[end] == '\n' {
			text = rtrimSpace(text)
		}
		s.addText(text)
	}
}

func (s *subject) handleNewline() {
	nl := s.pos
	s.pos++
	if nl > 1 && s.s[nl-1] == ' ' && s.s[nl-2] == ' ' {
		s.add(&node{typ: nLinebreak})
	} else {
		s.add(&node{typ: nSoftbreak})
	}
	for s.pos < len(s.s) && isSpaceOrTab(s.s[s.pos]) {
		s.pos++
	}
}

func (s *subject) handleBackslash() {
	s.pos++
	switch c := s.peek(s.pos); {
	case c != 0 && isPunct(c):
		s.pos++
		s.addText(string(c))
	case c == '\n':
		s.pos++
		s.add(&node{typ: nLinebreak})
	default:
		s.addText("\\")
	}
}

func (s *subject) handleEntity() {
	if dec, n := matchEntity(s.s, s.pos); n > 0 {
		s.pos += n
		s.addText(dec)
		return
	}
	s.pos++
	s.addText("&")
}

// handleBackticks parses a code span, using cmark's backtick memo.
func (s *subject) handleBackticks() {
	start := s.pos
	for s.pos < len(s.s) && s.s[s.pos] == '`' {
		s.pos++
	}
	n := s.pos - start
	p := s.pos
	if end := s.findCloser(n, p); end >= 0 {
		content := s.s[p:end]
		s.pos = end + n
		buf := []byte(content)
		for i, c := range buf {
			if c == '\n' {
				buf[i] = ' '
			}
		}
		if len(buf) >= 2 && buf[0] == ' ' && buf[len(buf)-1] == ' ' && !allSpaces(buf) {
			buf = buf[1 : len(buf)-1]
		}
		s.add(&node{typ: nCode, literal: string(buf)})
		return
	}
	s.addText(s.s[start:p])
}

func allSpaces(b []byte) bool {
	for _, c := range b {
		if c != ' ' {
			return false
		}
	}
	return true
}

// findCloser looks for a run of exactly n backticks at or after p and returns
// its start, or -1.
func (s *subject) findCloser(n, p int) int {
	if n > 100 {
		// Runs longer than the memo are not produced by valid input; search plainly.
		return s.findPlain(n, p)
	}
	if s.scanned && s.backticks[n] <= p {
		return -1
	}
	for i := p; i < len(s.s); {
		if s.s[i] != '`' {
			i++
			continue
		}
		j := i
		for j < len(s.s) && s.s[j] == '`' {
			j++
		}
		k := j - i
		if k <= 100 {
			s.backticks[k] = i
		}
		if k == n {
			return i
		}
		i = j
	}
	s.scanned = true
	return -1
}

func (s *subject) findPlain(n, p int) int {
	for i := p; i < len(s.s); {
		if s.s[i] != '`' {
			i++
			continue
		}
		j := i
		for j < len(s.s) && s.s[j] == '`' {
			j++
		}
		if j-i == n {
			return i
		}
		i = j
	}
	return -1
}

// handlePointyBrace parses an autolink; otherwise '<' is plain text.
func (s *subject) handlePointyBrace() {
	if end, email := scanAutolink(s.s, s.pos+1); end > 0 {
		raw := s.s[s.pos+1 : end]
		s.pos = end + 1
		dest := decodeEntities(raw)
		if email {
			dest = "mailto:" + dest
		}
		link := &node{typ: nLink, dest: trimSpace(dest)}
		link.appendChild(&node{typ: nText, literal: decodeEntities(raw)})
		s.add(link)
		return
	}
	s.pos++
	s.addText("<")
}

// scanAutolink matches a URI or email autolink body starting at i (just after
// '<'). It returns the index of the closing '>' and whether it is an email.
func scanAutolink(str string, i int) (end int, email bool) {
	n := len(str)
	// URI autolink.
	if i < n && isAlpha(str[i]) {
		j := i + 1
		for j < n && (isAlnum(str[j]) || str[j] == '.' || str[j] == '+' || str[j] == '-') {
			j++
		}
		if l := j - i - 1; l >= 1 && l <= 31 && j < n && str[j] == ':' {
			for k := j + 1; k < n; k++ {
				c := str[k]
				if c == '>' {
					return k, false
				}
				if c <= 0x20 || c == '<' {
					break
				}
			}
		}
	}
	// Email autolink.
	j := i
	for j < n && isEmailLocal(str[j]) {
		j++
	}
	if j == i || j >= n || str[j] != '@' {
		return 0, false
	}
	j++
	for {
		start := j
		for j < n && (isAlnum(str[j]) || str[j] == '-') {
			j++
		}
		if j == start || j-start > 63 || !isAlnum(str[start]) || !isAlnum(str[j-1]) {
			return 0, false
		}
		if j < n && str[j] == '.' {
			j++
			continue
		}
		if j < n && str[j] == '>' {
			return j, true
		}
		return 0, false
	}
}

func isEmailLocal(c byte) bool {
	if isAlnum(c) {
		return true
	}
	switch c {
	case '.', '!', '#', '$', '%', '&', '\'', '*', '+', '/', '=', '?', '^', '_', '`', '{', '|', '}', '~', '-':
		return true
	}
	return false
}

// handleDelim scans a run of '*' or '_' and pushes it on the delimiter stack.
func (s *subject) handleDelim(c byte) {
	start := s.pos
	for s.pos < len(s.s) && s.s[s.pos] == c {
		s.pos++
	}
	n := s.pos - start
	before, after := byte('\n'), byte('\n')
	if start > 0 {
		before = s.s[start-1]
	}
	if s.pos < len(s.s) {
		after = s.s[s.pos]
	}
	// Non-ASCII neighbours count as ordinary characters (see package docs).
	beforeSpace, afterSpace := isSpace(before), isSpace(after)
	beforePunct, afterPunct := isPunct(before), isPunct(after)
	left := !afterSpace && (!afterPunct || beforeSpace || beforePunct)
	right := !beforeSpace && (!beforePunct || afterSpace || afterPunct)
	var canOpen, canClose bool
	if c == '*' {
		canOpen, canClose = left, right
	} else {
		canOpen = left && (!right || beforePunct)
		canClose = right && (!left || afterPunct)
	}
	text := &node{typ: nText, literal: s.s[start:s.pos]}
	s.add(text)
	if canOpen || canClose {
		d := &delimiter{
			prev: s.lastDelim, text: text, ch: c, origLen: n,
			canOpen: canOpen, canClose: canClose, position: s.pos,
		}
		if s.lastDelim != nil {
			s.lastDelim.next = d
		}
		s.lastDelim = d
	}
}

func (s *subject) removeDelim(d *delimiter) {
	if d.prev != nil {
		d.prev.next = d.next
	}
	if d.next != nil {
		d.next.prev = d.prev
	} else {
		s.lastDelim = d.prev
	}
}

// processEmphasis resolves delimiter entries at or after stackBottom.
func (s *subject) processEmphasis(stackBottom int) {
	var openersBottom [12]int
	for i := range openersBottom {
		openersBottom[i] = stackBottom
	}
	closer := s.lastDelim
	if closer == nil || closer.position < stackBottom {
		return
	}
	for closer.prev != nil && closer.prev.position >= stackBottom {
		closer = closer.prev
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
		var opener *delimiter
		for o := closer.prev; o != nil && o.position >= openersBottom[kind]; o = o.prev {
			if o.canOpen && o.ch == closer.ch {
				odd := (closer.canOpen || o.canClose) && closer.origLen%3 != 0 && (o.origLen+closer.origLen)%3 == 0
				if !odd {
					opener = o
					break
				}
			}
		}
		if opener == nil {
			openersBottom[kind] = closer.position
			next := closer.next
			if !closer.canOpen {
				s.removeDelim(closer)
			}
			closer = next
			continue
		}
		use := 1
		if len(closer.text.literal) >= 2 && len(opener.text.literal) >= 2 {
			use = 2
		}
		opener.text.literal = opener.text.literal[:len(opener.text.literal)-use]
		closer.text.literal = closer.text.literal[use:]
		// Drop the delimiters between opener and closer.
		for d := closer.prev; d != nil && d != opener; {
			prev := d.prev
			s.removeDelim(d)
			d = prev
		}
		// Wrap the nodes between the two text nodes.
		typ := nEmph
		if use == 2 {
			typ = nStrong
		}
		wrapper := &node{typ: typ}
		for cur := opener.text.next; cur != nil && cur != closer.text; {
			next := cur.next
			cur.unlink()
			wrapper.appendChild(cur)
			cur = next
		}
		opener.text.insertAfter(wrapper)
		if opener.text.literal == "" {
			opener.text.unlink()
			s.removeDelim(opener)
		}
		if closer.text.literal == "" {
			closer.text.unlink()
			next := closer.next
			s.removeDelim(closer)
			closer = next
		}
	}
	// Remove all remaining entries at or after stackBottom.
	for s.lastDelim != nil && s.lastDelim.position >= stackBottom {
		s.lastDelim = s.lastDelim.prev
	}
	if s.lastDelim != nil {
		s.lastDelim.next = nil
	}
}

// handleCloseBracket handles ']'.
func (s *subject) handleCloseBracket() {
	s.pos++
	if len(s.brackets) == 0 {
		s.addText("]")
		return
	}
	opener := s.brackets[len(s.brackets)-1]
	if !opener.image && s.linkClosed {
		s.brackets = s.brackets[:len(s.brackets)-1]
		s.addText("]")
		return
	}
	dest, title, hasTitle, end, ok := s.parseInlineLinkTail(s.pos)
	if !ok {
		s.brackets = s.brackets[:len(s.brackets)-1]
		s.addText("]")
		return
	}
	s.pos = end
	typ := nLink
	if opener.image {
		typ = nImage
	}
	link := &node{typ: typ, dest: dest, title: title, hasTitle: hasTitle}
	for cur := opener.text.next; cur != nil; {
		next := cur.next
		cur.unlink()
		link.appendChild(cur)
		cur = next
	}
	opener.text.insertAfter(link)
	opener.text.unlink()
	s.processEmphasis(opener.position)
	s.brackets = s.brackets[:len(s.brackets)-1]
	if !opener.image {
		s.linkClosed = true
	}
}

func (s *subject) skipSpaces(i int) int {
	for i < len(s.s) && isSpace(s.s[i]) {
		i++
	}
	return i
}

// parseInlineLinkTail parses "(destination title)" starting at i, just after
// the closing bracket. It returns the cleaned destination and title and the
// index just after the closing parenthesis.
func (s *subject) parseInlineLinkTail(i int) (dest, title string, hasTitle bool, end int, ok bool) {
	if s.peek(i) != '(' {
		return
	}
	start := s.skipSpaces(i + 1)
	n := s.scanLinkDest(start)
	if n < 0 {
		return
	}
	endURL := start + n
	startTitle := s.skipSpaces(endURL)
	endTitle := startTitle
	if startTitle != endURL {
		endTitle = startTitle + s.scanLinkTitle(startTitle)
	}
	endAll := s.skipSpaces(endTitle)
	if s.peek(endAll) != ')' {
		return
	}
	rawDest := s.s[start:endURL]
	if len(rawDest) > 0 && rawDest[0] == '<' {
		rawDest = rawDest[1 : len(rawDest)-1]
	}
	dest = unescapeBackslashes(decodeEntities(trimSpace(rawDest)))
	if endTitle > startTitle {
		title = unescapeBackslashes(decodeEntities(s.s[startTitle+1 : endTitle-1]))
		hasTitle = true
	}
	return dest, title, hasTitle, endAll + 1, true
}

// scanLinkDest returns the length of the link destination starting at i, or -1.
func (s *subject) scanLinkDest(i int) int {
	str := s.s
	if i < len(str) && str[i] == '<' {
		j := i + 1
		for j < len(str) {
			c := str[j]
			if c == '>' {
				j++
				break
			} else if c == '\\' {
				j += 2
			} else if c == '\n' || c == '<' {
				return -1
			} else {
				j++
			}
		}
		if j >= len(str) {
			return -1
		}
		return j - i
	}
	j := i
	nesting := 0
	for j < len(str) {
		c := str[j]
		if c == '\\' && j+1 < len(str) && isPunct(str[j+1]) {
			j += 2
		} else if c == '(' {
			nesting++
			j++
			if nesting > 32 {
				return -1
			}
		} else if c == ')' {
			if nesting == 0 {
				break
			}
			nesting--
			j++
		} else if isSpace(c) {
			break
		} else {
			j++
		}
	}
	if j >= len(str) || nesting != 0 {
		return -1
	}
	return j - i
}

// scanLinkTitle returns the length of the title starting at i (including its
// delimiters), or 0. Where several matches exist the longest wins: the closing
// delimiter (and, for parenthesised titles, also '(') may appear inside the
// title only when preceded by a backslash.
func (s *subject) scanLinkTitle(i int) int {
	str := s.s
	if i >= len(str) {
		return 0
	}
	open := str[i]
	var closeCh byte
	switch open {
	case '"', '\'':
		closeCh = open
	case '(':
		closeCh = ')'
	default:
		return 0
	}
	best := 0
	for j := i + 1; j < len(str); j++ {
		c := str[j]
		escaped := j-1 > i && str[j-1] == '\\'
		if c == closeCh {
			best = j - i + 1
			if !escaped {
				return best
			}
		} else if open == '(' && c == '(' && !escaped {
			return best
		}
	}
	return best
}
