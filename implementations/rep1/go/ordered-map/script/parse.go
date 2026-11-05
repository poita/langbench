package script

// cursor walks a byte slice line by line without allocating.
type cursor struct {
	buf []byte
	pos int
}

// line returns the next line without its terminator (a trailing '\r' is
// tolerated and dropped). ok is false at end of input.
func (c *cursor) line() (l []byte, ok bool) {
	if c.pos >= len(c.buf) {
		return nil, false
	}
	start := c.pos
	end := start
	for end < len(c.buf) && c.buf[end] != '\n' {
		end++
	}
	c.pos = end + 1
	if end > start && c.buf[end-1] == '\r' {
		end--
	}
	return c.buf[start:end], true
}

// token splits the next space-delimited token off the front of line.
func token(line []byte) (tok, rest []byte) {
	i := 0
	for i < len(line) && line[i] != ' ' {
		i++
	}
	if i < len(line) {
		return line[:i], line[i+1:]
	}
	return line, nil
}

// parseInt parses an optionally negative decimal integer. The magnitude is
// accumulated unsigned so that -9223372036854775808 does not overflow.
func parseInt(b []byte) int64 {
	neg := false
	if len(b) > 0 && b[0] == '-' {
		neg = true
		b = b[1:]
	}
	var u uint64
	for _, ch := range b {
		u = u*10 + uint64(ch-'0')
	}
	if neg {
		return int64(-u)
	}
	return int64(u)
}

// parseCount parses a non-negative decimal integer, saturating at MaxInt64.
func parseCount(b []byte) int64 {
	var u uint64
	for _, ch := range b {
		u = u*10 + uint64(ch-'0')
		if u > 1<<62 {
			return 1 << 62
		}
	}
	return int64(u)
}
