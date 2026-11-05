package commonmark

import "strconv"

// renderer turns the block tree into HTML. Inline content is parsed when
// its leaf block is rendered, so only one block's inlines exist at a time.
type renderer struct {
	out []byte
	ip  inlineParser
}

func renderHTML(root *block, sizeHint int) []byte {
	r := &renderer{out: make([]byte, 0, sizeHint+sizeHint/2)}
	for c := root.first; c != nil; c = c.next {
		r.block(c)
	}
	return r.out
}

// cr starts a new line unless the output is empty or already at one.
func (r *renderer) cr() {
	if n := len(r.out); n > 0 && r.out[n-1] != '\n' {
		r.out = append(r.out, '\n')
	}
}

func (r *renderer) str(s string) { r.out = append(r.out, s...) }

func (r *renderer) block(b *block) {
	switch b.kind {
	case kBlockQuote:
		r.cr()
		r.str("<blockquote>\n")
		for c := b.first; c != nil; c = c.next {
			r.block(c)
		}
		r.cr()
		r.str("</blockquote>\n")
	case kList:
		r.cr()
		switch {
		case !b.ordered:
			r.str("<ul>\n")
		case b.start == 1:
			r.str("<ol>\n")
		default:
			r.str("<ol start=\"")
			r.out = strconv.AppendInt(r.out, int64(b.start), 10)
			r.str("\">\n")
		}
		for c := b.first; c != nil; c = c.next {
			r.block(c)
		}
		if b.ordered {
			r.str("</ol>\n")
		} else {
			r.str("</ul>\n")
		}
	case kItem:
		r.cr()
		r.str("<li>")
		for c := b.first; c != nil; c = c.next {
			r.block(c)
		}
		r.str("</li>\n")
	case kParagraph:
		if g := b.parent.parent; g != nil && g.kind == kList && g.tight {
			r.inlines(b.content)
			return
		}
		r.cr()
		r.str("<p>")
		r.inlines(b.content)
		r.str("</p>\n")
	case kHeading:
		r.cr()
		tag := "<h" + strconv.Itoa(b.level) + ">"
		r.str(tag)
		r.inlines(b.content)
		r.str("</h" + strconv.Itoa(b.level) + ">\n")
	case kThematicBreak:
		r.cr()
		r.str("<hr />\n")
	case kCodeBlock:
		r.cr()
		r.str("<pre><code")
		if len(b.info) > 0 {
			word := b.info
			for i, c := range word {
				if isWhitespace(c) {
					word = word[:i]
					break
				}
			}
			r.str(" class=\"")
			if len(word) < 9 || string(word[:9]) != "language-" {
				r.str("language-")
			}
			r.out = appendEscaped(r.out, word)
			r.str("\"")
		}
		r.str(">")
		r.out = appendEscaped(r.out, b.content)
		r.str("</code></pre>\n")
	}
}

// inlines parses content and appends its HTML. The tree is walked
// iteratively because inline nesting can be thousands of levels deep.
func (r *renderer) inlines(content []byte) {
	ip := &r.ip
	root := ip.parse(content)
	nodes := ip.nodes
	imgDepth := 0
	n := nodes[root].first
	for n != 0 {
		nd := &nodes[n]
		r.enter(ip, nd, &imgDepth)
		if nd.first != 0 {
			n = nd.first
			continue
		}
		for {
			nd = &nodes[n]
			r.exit(ip, nd, &imgDepth)
			if nd.next != 0 {
				n = nd.next
				break
			}
			n = nd.parent
			if n == root {
				n = 0
				break
			}
		}
	}
}

func (r *renderer) enter(ip *inlineParser, nd *inode, imgDepth *int) {
	if *imgDepth > 0 {
		switch nd.kind {
		case inText, inCode:
			r.out = appendEscaped(r.out, nd.text)
		case inSoftbreak, inLinebreak:
			r.out = append(r.out, ' ')
		case inImage:
			*imgDepth++
		}
		return
	}
	switch nd.kind {
	case inText:
		r.out = appendEscaped(r.out, nd.text)
	case inSoftbreak:
		r.out = append(r.out, '\n')
	case inLinebreak:
		r.str("<br />\n")
	case inCode:
		r.str("<code>")
		r.out = appendEscaped(r.out, nd.text)
		r.str("</code>")
	case inEmph:
		r.str("<em>")
	case inStrong:
		r.str("<strong>")
	case inLink:
		li := &ip.links[nd.link]
		r.str("<a href=\"")
		r.out = appendHref(r.out, li.dest)
		r.str("\"")
		if li.hasTitle {
			r.str(" title=\"")
			r.out = appendEscaped(r.out, li.title)
			r.str("\"")
		}
		r.str(">")
	case inImage:
		li := &ip.links[nd.link]
		r.str("<img src=\"")
		r.out = appendHref(r.out, li.dest)
		r.str("\" alt=\"")
		*imgDepth = 1
	}
}

func (r *renderer) exit(ip *inlineParser, nd *inode, imgDepth *int) {
	if *imgDepth > 0 {
		if nd.kind == inImage {
			*imgDepth--
			if *imgDepth == 0 {
				li := &ip.links[nd.link]
				r.str("\"")
				if li.hasTitle {
					r.str(" title=\"")
					r.out = appendEscaped(r.out, li.title)
					r.str("\"")
				}
				r.str(" />")
			}
		}
		return
	}
	switch nd.kind {
	case inEmph:
		r.str("</em>")
	case inStrong:
		r.str("</strong>")
	case inLink:
		r.str("</a>")
	}
}
