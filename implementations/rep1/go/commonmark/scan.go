package commonmark

// Block-level scanners. Each one examines a line in place from a byte
// position and never allocates.

// scanATXStart matches 1-6 '#' followed by spaces/tabs or the end of the
// line. It returns the heading level and the index just after the '#'s
// and all the spaces/tabs that follow them.
func scanATXStart(line []byte, i int) (level, end int, ok bool) {
	j := i
	for j < len(line) && line[j] == '#' {
		j++
	}
	level = j - i
	if level < 1 || level > 6 {
		return 0, 0, false
	}
	if j < len(line) && !isSpaceOrTab(line[j]) {
		return 0, 0, false
	}
	for j < len(line) && isSpaceOrTab(line[j]) {
		j++
	}
	return level, j, true
}

// scanThematicBreak reports whether line[i:] is a thematic break: three or
// more of '*', '-' or '_' (all the same) interleaved with spaces/tabs.
func scanThematicBreak(line []byte, i int) bool {
	if i >= len(line) {
		return false
	}
	c := line[i]
	if c != '*' && c != '-' && c != '_' {
		return false
	}
	n := 0
	for ; i < len(line); i++ {
		switch {
		case line[i] == c:
			n++
		case isSpaceOrTab(line[i]):
		default:
			return false
		}
	}
	return n >= 3
}

// scanFenceStart matches an opening code fence at line[i:]: three or more
// backticks (with no backtick in the rest of the line) or three or more
// tildes. It returns the fence character and the run length.
func scanFenceStart(line []byte, i int) (ch byte, n int, ok bool) {
	if i >= len(line) || (line[i] != '`' && line[i] != '~') {
		return 0, 0, false
	}
	ch = line[i]
	j := i
	for j < len(line) && line[j] == ch {
		j++
	}
	n = j - i
	if n < 3 {
		return 0, 0, false
	}
	if ch == '`' {
		for k := j; k < len(line); k++ {
			if line[k] == '`' {
				return 0, 0, false
			}
		}
	}
	return ch, n, true
}

// scanFenceClose returns the length of the run of ch at line[i:] when it
// is followed only by spaces/tabs, or 0 otherwise.
func scanFenceClose(line []byte, i int, ch byte) int {
	j := i
	for j < len(line) && line[j] == ch {
		j++
	}
	n := j - i
	for ; j < len(line); j++ {
		if !isSpaceOrTab(line[j]) {
			return 0
		}
	}
	return n
}

// scanSetextUnderline returns 1 for a run of '=' and 2 for a run of '-'
// followed only by spaces/tabs, or 0 if line[i:] is not an underline.
func scanSetextUnderline(line []byte, i int) int {
	if i >= len(line) || (line[i] != '=' && line[i] != '-') {
		return 0
	}
	c := line[i]
	j := i
	for j < len(line) && line[j] == c {
		j++
	}
	for ; j < len(line); j++ {
		if !isSpaceOrTab(line[j]) {
			return 0
		}
	}
	if c == '=' {
		return 1
	}
	return 2
}

// listMarker describes a list marker found at the start of a list item.
type listMarker struct {
	ordered bool
	char    byte // bullet character, or '.' / ')' for ordered lists
	start   int  // number of an ordered marker
	width   int  // marker width in bytes, delimiter included
}

// scanListMarker parses a list marker at line[i:]. When interrupts is true
// the marker would interrupt a paragraph, which requires non-blank content
// after it and, for ordered lists, the number 1.
func scanListMarker(line []byte, i int, interrupts bool) (m listMarker, ok bool) {
	at := func(k int) byte {
		if k < len(line) {
			return line[k]
		}
		return '\n'
	}
	c := at(i)
	pos := i
	switch {
	case c == '*' || c == '-' || c == '+':
		pos++
		if !isWhitespace(at(pos)) {
			return m, false
		}
		m.char = c
	case isDigit(c):
		start, digits := 0, 0
		for {
			start = start*10 + int(at(pos)-'0')
			pos++
			digits++
			if digits >= 9 || !isDigit(at(pos)) {
				break
			}
		}
		d := at(pos)
		if d != '.' && d != ')' {
			return m, false
		}
		pos++
		if !isWhitespace(at(pos)) {
			return m, false
		}
		m.ordered, m.char, m.start = true, d, start
	default:
		return m, false
	}
	if interrupts {
		if m.ordered && m.start != 1 {
			return m, false
		}
		k := pos
		for k < len(line) && isSpaceOrTab(line[k]) {
			k++
		}
		if k >= len(line) {
			return m, false
		}
	}
	m.width = pos - i
	return m, true
}
