package inline

import (
	"example.com/commonmark/ast"
	"example.com/commonmark/internal/scan"
)

// closeBracket handles a ']' at the current position.
func (p *parser) closeBracket() {
	p.pos++
	opener := p.brackets
	if opener == nil {
		p.text("]")
		return
	}
	if !opener.image && p.linkClosed {
		p.brackets = opener.prev
		p.text("]")
		return
	}
	dest, title, hasTitle, end, ok := scanLinkTail(p.s, p.pos)
	if !ok {
		p.brackets = opener.prev
		p.text("]")
		return
	}
	kind := ast.Link
	if opener.image {
		kind = ast.Image
	}
	n := ast.New(kind)
	n.Dest = scan.Unescape(scan.DecodeEntities(dest))
	if hasTitle {
		n.HasTitle = true
		n.Title = scan.Unescape(scan.DecodeEntities(title))
	}
	n.AdoptRange(opener.node.Next, p.parent.LastChild)
	opener.node.Unlink()
	p.parent.AppendChild(n)
	p.processEmphasis(opener.position)
	p.brackets = opener.prev
	if !opener.image {
		p.linkClosed = true
	}
	p.pos = end
}

func skipSpace(s string, i int) int {
	for i < len(s) && scan.IsSpace(s[i]) {
		i++
	}
	return i
}

// scanLinkTail parses "(destination title)" starting at the '(' at s[i]. It
// returns the raw (still escaped) destination and title and the index after
// the closing parenthesis.
func scanLinkTail(s string, i int) (dest, title string, hasTitle bool, end int, ok bool) {
	if i >= len(s) || s[i] != '(' {
		return
	}
	i = skipSpace(s, i+1)
	ds, de, next := scanDestination(s, i)
	if next < 0 {
		return
	}
	dest = scan.TrimSpace(s[ds:de])
	i = next
	j := skipSpace(s, i)
	if j > i && j < len(s) {
		if e := scanTitle(s, j); e >= 0 {
			title, hasTitle = s[j+1:e-1], true
			j = e
		}
	}
	j = skipSpace(s, j)
	if j >= len(s) || s[j] != ')' {
		return "", "", false, 0, false
	}
	return dest, title, hasTitle, j + 1, true
}

// scanDestination scans a link destination at s[i:]. It returns the bounds
// of the destination text and the index after it, or next < 0.
func scanDestination(s string, i int) (start, end, next int) {
	n := len(s)
	if i < n && s[i] == '<' {
		return scanAngle(s, i)
	}
	start = i
	depth := 0
	for i < n {
		c := s[i]
		switch {
		case c == '\\' && i+1 < n && scan.IsPunct(s[i+1]):
			i += 2
			continue
		case c == '(':
			depth++
			i++
			if depth > 32 {
				return 0, 0, -1
			}
			continue
		case c == ')':
			if depth == 0 {
				goto out
			}
			depth--
			i++
			continue
		case scan.IsSpace(c):
			goto out
		}
		i++
	}
out:
	if i >= n || depth != 0 {
		return 0, 0, -1
	}
	return start, i, i
}

// scanAngle scans the <...> form of a destination; s[i] is the '<'.
func scanAngle(s string, i int) (start, end, next int) {
	n := len(s)
	start = i + 1
	i++
	for i < n {
		switch s[i] {
		case '>':
			if i+1 >= n {
				return 0, 0, -1
			}
			return start, i, i + 1
		case '\\':
			i += 2
		case '\n', '<':
			return 0, 0, -1
		default:
			i++
		}
	}
	return 0, 0, -1
}

// scanTitle returns the end (exclusive) of the longest title starting at
// s[i], which is '"', '\” or '(', or -1 if there is none. Inside a title
// the closing delimiter (and '(' for the parenthesised form) may only occur
// preceded by a backslash. The scan keeps the set of reachable positions in
// three booleans, so it is linear in the text it examines.
func scanTitle(s string, i int) int {
	open := s[i]
	closer := open
	switch open {
	case '"', '\'':
	case '(':
		closer = ')'
	default:
		return -1
	}
	best := -1
	// a, b, c: whether positions j, j+1, j+2 can be reached by a valid
	// prefix of the title body.
	a, b, c := true, false, false
	for j := i + 1; j < len(s); j++ {
		if !a && !b {
			break
		}
		if a {
			ch := s[j]
			if ch == closer {
				best = j + 1
			} else if ch != 0 && !(open == '(' && ch == '(') {
				b = true
			}
			if ch == '\\' && j+1 < len(s) && scan.IsPunct(s[j+1]) {
				c = true
			}
		}
		a, b, c = b, c, false
	}
	return best
}
