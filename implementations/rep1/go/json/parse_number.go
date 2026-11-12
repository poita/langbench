package jsoncanon

// number parses a number lexeme and returns it in canonical textual form.
func (p *parser) number() (Value, error) {
	d := p.data
	start := p.pos
	i := start
	if d[i] == '-' {
		i++
	}
	if i >= len(d) {
		p.pos = i
		return Value{}, p.errf("invalid number")
	}
	switch c := d[i]; {
	case c == '0':
		i++
	case c >= '1' && c <= '9':
		for i < len(d) && isDigit(d[i]) {
			i++
		}
	default:
		p.pos = i
		return Value{}, p.errf("invalid number")
	}
	if i < len(d) && d[i] == '.' {
		i++
		fs := i
		for i < len(d) && isDigit(d[i]) {
			i++
		}
		if i == fs {
			p.pos = i
			return Value{}, p.errf("digits required after decimal point")
		}
	}
	mantEnd := i
	if i < len(d) && (d[i] == 'e' || d[i] == 'E') {
		i++
		neg := false
		if i < len(d) && (d[i] == '+' || d[i] == '-') {
			neg = d[i] == '-'
			i++
		}
		ds := i
		for i < len(d) && isDigit(d[i]) {
			i++
		}
		if i == ds {
			p.pos = i
			return Value{}, p.errf("digits required in exponent")
		}
		// Strip leading zeros of the exponent.
		z := ds
		for z < i-1 && d[z] == '0' {
			z++
		}
		digits := d[z:i]
		buf := make([]byte, 0, mantEnd-start+1+1+len(digits))
		buf = append(buf, d[start:mantEnd]...)
		buf = append(buf, 'e')
		if neg && digits[0] != '0' {
			buf = append(buf, '-')
		}
		buf = append(buf, digits...)
		p.pos = i
		return Value{Kind: Number, Text: string(buf)}, nil
	}
	p.pos = i
	return Value{Kind: Number, Text: string(d[start:i])}, nil
}

func isDigit(c byte) bool { return c >= '0' && c <= '9' }
