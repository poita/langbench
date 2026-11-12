package block

import (
	"example.com/commonmark/ast"
	"example.com/commonmark/internal/scan"
)

// atxLevel returns the heading level if s starts an ATX heading, else 0.
func atxLevel(s string) int {
	n := 0
	for n < len(s) && s[n] == '#' {
		n++
	}
	if n < 1 || n > 6 || (n < len(s) && !scan.IsSpaceOrTab(s[n])) {
		return 0
	}
	return n
}

// openingFence reports whether s starts a fenced code block and returns the
// fence character and length.
func openingFence(s string) (byte, int) {
	if len(s) < 3 || (s[0] != '`' && s[0] != '~') {
		return 0, 0
	}
	c := s[0]
	n := 0
	for n < len(s) && s[n] == c {
		n++
	}
	if n < 3 {
		return 0, 0
	}
	if c == '`' {
		for i := n; i < len(s); i++ {
			if s[i] == '`' {
				return 0, 0
			}
		}
	}
	return c, n
}

// setextLevel returns 1 or 2 if s is a setext underline, else 0.
func setextLevel(s string) int {
	if len(s) == 0 || (s[0] != '=' && s[0] != '-') {
		return 0
	}
	c := s[0]
	i := 0
	for i < len(s) && s[i] == c {
		i++
	}
	for ; i < len(s); i++ {
		if !scan.IsSpaceOrTab(s[i]) {
			return 0
		}
	}
	if c == '=' {
		return 1
	}
	return 2
}

// isThematicBreak reports whether s is three or more *, _ or - characters
// (all the same) optionally separated by spaces and tabs.
func isThematicBreak(s string) bool {
	if len(s) == 0 || (s[0] != '*' && s[0] != '_' && s[0] != '-') {
		return false
	}
	c := s[0]
	n := 0
	for i := 0; i < len(s); i++ {
		switch {
		case s[i] == c:
			n++
		case !scan.IsSpaceOrTab(s[i]):
			return false
		}
	}
	return n >= 3
}

// parseListMarker looks for a list marker at nextNonspace. It returns the
// list description and the marker width, or width 0 if there is no marker
// (or, when interrupts is set, the marker may not interrupt a paragraph).
func (p *parser) parseListMarker(interrupts bool) (ast.ListData, int) {
	var d ast.ListData
	line := p.line
	start := p.nextNonspace
	i := start
	atWS := func(i int) bool { return i >= len(line) || scan.IsSpaceOrTab(line[i]) }

	switch c := p.peek(i); {
	case c == '*' || c == '-' || c == '+':
		i++
		d = ast.ListData{Type: ast.Bullet, Delim: c}
	case scan.IsDigit(c):
		num, digits := 0, 0
		for digits < 9 && i < len(line) && scan.IsDigit(line[i]) {
			num = num*10 + int(line[i]-'0')
			i++
			digits++
		}
		if interrupts && num != 1 {
			return d, 0
		}
		if d := p.peek(i); d != '.' && d != ')' {
			return ast.ListData{}, 0
		}
		d = ast.ListData{Type: ast.Ordered, Delim: line[i], Start: num}
		i++
	default:
		return d, 0
	}
	if !atWS(i) {
		return ast.ListData{}, 0
	}
	if interrupts {
		j := i
		for j < len(line) && scan.IsSpaceOrTab(line[j]) {
			j++
		}
		if j >= len(line) {
			return ast.ListData{}, 0
		}
	}
	return d, i - start
}

func sameList(a, b ast.ListData) bool { return a.Type == b.Type && a.Delim == b.Delim }

// isTight computes whether a list that is being closed is tight.
func isTight(list *ast.Node) bool {
	for item := list.FirstChild; item != nil; item = item.Next {
		if item.State.LastLineBlank && item.Next != nil {
			return false
		}
		for sub := item.FirstChild; sub != nil; sub = sub.Next {
			if (item.Next != nil || sub.Next != nil) && endsWithBlankLine(sub) {
				return false
			}
		}
	}
	return true
}

// endsWithBlankLine reports whether n ends with a blank line, with cmark's
// memoisation: a block checked once answers with its own flag afterwards.
func endsWithBlankLine(n *ast.Node) bool {
	s := n.State
	if s.LastLineChecked {
		return s.LastLineBlank
	}
	s.LastLineChecked = true
	if (n.Kind == ast.List || n.Kind == ast.Item) && n.LastChild != nil {
		return endsWithBlankLine(n.LastChild)
	}
	return s.LastLineBlank
}
