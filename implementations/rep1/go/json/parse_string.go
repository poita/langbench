package jsoncanon

// str parses a string starting at the opening quote and returns its decoded
// contents. The input is already known to be valid UTF-8, so raw bytes can be
// copied through unchanged.
func (p *parser) str() (string, error) {
	d := p.data
	i := p.pos + 1
	start := i
	// Fast path: no escapes.
	for i < len(d) {
		c := d[i]
		if c == '"' {
			p.pos = i + 1
			return string(d[start:i]), nil
		}
		if c == '\\' {
			break
		}
		if c < 0x20 {
			p.pos = i
			return "", p.errf("control character in string")
		}
		i++
	}
	buf := make([]byte, 0, i-start+16)
	buf = append(buf, d[start:i]...)
	for i < len(d) {
		c := d[i]
		switch {
		case c == '"':
			p.pos = i + 1
			return string(buf), nil
		case c < 0x20:
			p.pos = i
			return "", p.errf("control character in string")
		case c != '\\':
			buf = append(buf, c)
			i++
			continue
		}
		// Escape sequence.
		i++
		if i >= len(d) {
			break
		}
		switch d[i] {
		case '"', '\\', '/':
			buf = append(buf, d[i])
		case 'b':
			buf = append(buf, '\b')
		case 'f':
			buf = append(buf, '\f')
		case 'n':
			buf = append(buf, '\n')
		case 'r':
			buf = append(buf, '\r')
		case 't':
			buf = append(buf, '\t')
		case 'u':
			r, ok := hex4(d, i+1)
			if !ok {
				p.pos = i
				return "", p.errf("invalid \\u escape")
			}
			i += 4
			switch {
			case r >= 0xD800 && r <= 0xDBFF:
				if i+2 < len(d) && d[i+1] == '\\' && d[i+2] == 'u' {
					lo, ok := hex4(d, i+3)
					if ok && lo >= 0xDC00 && lo <= 0xDFFF {
						r = 0x10000 + (r-0xD800)<<10 + (lo - 0xDC00)
						i += 6
						break
					}
				}
				p.pos = i
				return "", p.errf("unpaired high surrogate")
			case r >= 0xDC00 && r <= 0xDFFF:
				p.pos = i
				return "", p.errf("unpaired low surrogate")
			}
			buf = appendRune(buf, r)
		default:
			p.pos = i
			return "", p.errf("invalid escape")
		}
		i++
	}
	p.pos = len(d)
	return "", p.errf("unterminated string")
}

// hex4 decodes four ASCII hex digits at d[i:].
func hex4(d []byte, i int) (rune, bool) {
	if i+4 > len(d) {
		return 0, false
	}
	var r rune
	for _, c := range d[i : i+4] {
		switch {
		case c >= '0' && c <= '9':
			c -= '0'
		case c >= 'a' && c <= 'f':
			c = c - 'a' + 10
		case c >= 'A' && c <= 'F':
			c = c - 'A' + 10
		default:
			return 0, false
		}
		r = r<<4 | rune(c)
	}
	return r, true
}

// appendRune appends the UTF-8 encoding of the scalar value r.
func appendRune(b []byte, r rune) []byte {
	switch {
	case r < 0x80:
		return append(b, byte(r))
	case r < 0x800:
		return append(b, 0xC0|byte(r>>6), 0x80|byte(r)&0x3F)
	case r < 0x10000:
		return append(b, 0xE0|byte(r>>12), 0x80|byte(r>>6)&0x3F, 0x80|byte(r)&0x3F)
	}
	return append(b, 0xF0|byte(r>>18), 0x80|byte(r>>12)&0x3F, 0x80|byte(r>>6)&0x3F, 0x80|byte(r)&0x3F)
}
