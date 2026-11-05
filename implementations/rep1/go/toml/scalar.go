package toml

import (
	"errors"
	"math"
	"strconv"
)

// scalar parses a bare token: boolean, integer, float or date-time.
func (p *parser) scalar() Node {
	src := p.src
	start := p.pos
	end := p.scanToken()
	tok := src[start:end]
	if len(tok) == 0 {
		p.fail("expected value")
	}
	n := p.classify(start, tok)
	p.pos = end
	return n
}

// classify turns a bare token into a value. The cursor stays at the start of
// the token so that errors point at it.
func (p *parser) classify(start int, tok []byte) Node {
	switch s := string(tok); s {
	case "true", "false":
		return &Value{Bool, s}
	case "inf", "+inf":
		return &Value{Float, "inf"}
	case "-inf":
		return &Value{Float, "-inf"}
	case "nan", "+nan", "-nan":
		return &Value{Float, "nan"}
	}
	switch {
	case len(tok) >= 5 && tok[4] == '-' && isDigit(tok[0]) && isDigit(tok[1]) && isDigit(tok[2]) && isDigit(tok[3]):
		return p.dateTime(start, tok)
	case len(tok) >= 3 && tok[2] == ':' && isDigit(tok[0]):
		return p.dateTime(start, tok)
	}
	return p.number(start, tok)
}

// scanToken returns the end of the bare token starting at the cursor. A
// token ends at whitespace, a comma, a closing bracket or brace, a comment or
// a newline — except that "YYYY-MM-DD HH:" continues across the space.
func (p *parser) scanToken() int {
	src := p.src
	i := p.pos
	for i < len(src) {
		switch src[i] {
		case ' ', '\t', '\r', '\n', ',', ']', '}', '#':
			if src[i] == ' ' && i-p.pos == 10 && isDate(src[p.pos:i]) &&
				i+3 < len(src) && isDigit(src[i+1]) && isDigit(src[i+2]) && src[i+3] == ':' {
				i++
				continue
			}
			return i
		}
		i++
	}
	return i
}

func isDigit(c byte) bool { return c >= '0' && c <= '9' }

// isDate reports whether b has the shape DDDD-DD-DD.
func isDate(b []byte) bool {
	if len(b) != 10 {
		return false
	}
	for i, c := range b {
		if i == 4 || i == 7 {
			if c != '-' {
				return false
			}
		} else if !isDigit(c) {
			return false
		}
	}
	return true
}

// number parses an integer or float token.
func (p *parser) number(start int, tok []byte) Node {
	neg := false
	i := 0
	if tok[0] == '+' || tok[0] == '-' {
		neg = tok[0] == '-'
		i = 1
	}
	rest := tok[i:]
	if len(rest) == 0 {
		p.fail("invalid number")
	}
	// Prefixed integers.
	if len(rest) >= 2 && rest[0] == '0' && (rest[1] == 'x' || rest[1] == 'o' || rest[1] == 'b') {
		if i != 0 {
			p.fail("prefixed integers cannot have a sign")
		}
		var base uint64
		switch rest[1] {
		case 'x':
			base = 16
		case 'o':
			base = 8
		default:
			base = 2
		}
		digits := rest[2:]
		if len(digits) == 0 {
			p.fail("invalid integer")
		}
		var v uint64
		prevDigit := false
		for j, c := range digits {
			if c == '_' {
				if !prevDigit || j == len(digits)-1 {
					p.fail("misplaced underscore")
				}
				prevDigit = false
				continue
			}
			d, ok := hexVal(c)
			if !ok || uint64(d) >= base {
				p.fail("invalid digit in integer")
			}
			if v > (1<<63-1-uint64(d))/base {
				p.fail("integer out of range")
			}
			v = v*base + uint64(d)
			prevDigit = true
		}
		return &Value{Integer, strconv.FormatUint(v, 10)}
	}
	// Decimal integer part.
	j := p.decimalDigits(rest, 0)
	if j == 0 {
		p.fail("invalid number")
	}
	if rest[0] == '0' && j > 1 {
		p.fail("leading zeros are not allowed")
	}
	if j == len(rest) {
		var mag uint64
		for _, c := range rest {
			if c == '_' {
				continue
			}
			d := uint64(c - '0')
			if mag > (1<<64-1-d)/10 {
				p.fail("integer out of range")
			}
			next := mag*10 + d
			mag = next
		}
		if neg && mag != 0 {
			if mag > 1<<63 {
				p.fail("integer out of range")
			}
			if mag == 1<<63 {
				return &Value{Integer, "-9223372036854775808"}
			}
			return &Value{Integer, "-" + strconv.FormatUint(mag, 10)}
		}
		if mag > 1<<63-1 {
			p.fail("integer out of range")
		}
		return &Value{Integer, strconv.FormatUint(mag, 10)}
	}
	// Float: fraction and/or exponent.
	if rest[j] == '.' {
		k := p.decimalDigits(rest, j+1)
		if k == j+1 {
			p.fail("invalid float")
		}
		j = k
	}
	if j < len(rest) && (rest[j] == 'e' || rest[j] == 'E') {
		k := j + 1
		if k < len(rest) && (rest[k] == '+' || rest[k] == '-') {
			k++
		}
		e := p.decimalDigits(rest, k)
		if e == k {
			p.fail("invalid float exponent")
		}
		j = e
	}
	if j != len(rest) {
		p.fail("invalid number")
	}
	clean := make([]byte, 0, len(tok))
	for _, c := range tok {
		if c != '_' {
			clean = append(clean, c)
		}
	}
	f, err := strconv.ParseFloat(string(clean), 64)
	if err != nil && !errors.Is(err, strconv.ErrRange) {
		p.fail("invalid float")
	}
	switch {
	case math.IsInf(f, 1):
		return &Value{Float, "inf"}
	case math.IsInf(f, -1):
		return &Value{Float, "-inf"}
	}
	return &Value{Float, strconv.FormatFloat(f, 'e', 16, 64)}
}

// decimalDigits scans digits with single underscores between digits in b
// starting at i, and returns the index after the run (i if there is none).
// Leading zeros are accepted; the caller checks them where they matter.
func (p *parser) decimalDigits(b []byte, i int) int {
	j := i
	for j < len(b) {
		c := b[j]
		if isDigit(c) {
			j++
			continue
		}
		if c == '_' {
			if j == i || !isDigit(b[j-1]) || j+1 >= len(b) || !isDigit(b[j+1]) {
				p.fail("misplaced underscore")
			}
			j++
			continue
		}
		break
	}
	return j
}

// dateTime validates and canonicalises a date, time or date-time token.
func (p *parser) dateTime(start int, tok []byte) Node {
	n := len(tok)
	hasDate := tok[2] != ':'
	i := 0
	var out []byte
	if hasDate {
		if n < 10 || !isDate(tok[:10]) {
			p.fail("invalid date")
		}
		y := atoi(tok[0:4])
		m := atoi(tok[5:7])
		d := atoi(tok[8:10])
		if y < 1 || m < 1 || m > 12 || d < 1 || d > daysIn(y, m) {
			p.fail("invalid date")
		}
		out = append(out, tok[:10]...)
		i = 10
		if n == 10 {
			return &Value{DateLocal, string(out)}
		}
		if tok[i] != 'T' && tok[i] != 't' && tok[i] != ' ' {
			p.fail("invalid date-time separator")
		}
		out = append(out, 'T')
		i++
	}
	// time: HH:MM:SS[.frac]
	if n < i+8 || tok[i+2] != ':' || tok[i+5] != ':' ||
		!isDigit(tok[i]) || !isDigit(tok[i+1]) || !isDigit(tok[i+3]) ||
		!isDigit(tok[i+4]) || !isDigit(tok[i+6]) || !isDigit(tok[i+7]) {
		p.fail("invalid time")
	}
	if atoi(tok[i:i+2]) > 23 || atoi(tok[i+3:i+5]) > 59 || atoi(tok[i+6:i+8]) > 59 {
		p.fail("time out of range")
	}
	out = append(out, tok[i:i+8]...)
	i += 8
	if i < n && tok[i] == '.' {
		k := i + 1
		for k < n && isDigit(tok[k]) {
			k++
		}
		if k == i+1 {
			p.fail("invalid fractional seconds")
		}
		e := k
		for e > i+1 && tok[e-1] == '0' {
			e--
		}
		if e > i+1 {
			out = append(out, tok[i:e]...)
		}
		i = k
	}
	if i == n {
		if hasDate {
			return &Value{DateTimeLocal, string(out)}
		}
		return &Value{TimeLocal, string(out)}
	}
	if !hasDate {
		p.fail("time-local cannot have an offset")
	}
	off := tok[i:]
	switch {
	case len(off) == 1 && (off[0] == 'Z' || off[0] == 'z'):
		out = append(out, 'Z')
	case len(off) == 6 && (off[0] == '+' || off[0] == '-') && off[3] == ':' &&
		isDigit(off[1]) && isDigit(off[2]) && isDigit(off[4]) && isDigit(off[5]):
		if atoi(off[1:3]) > 23 || atoi(off[4:6]) > 59 {
			p.fail("offset out of range")
		}
		if string(off[1:]) == "00:00" {
			out = append(out, 'Z')
		} else {
			out = append(out, off...)
		}
	default:
		p.fail("invalid offset")
	}
	return &Value{DateTime, string(out)}
}

func atoi(b []byte) int {
	n := 0
	for _, c := range b {
		n = n*10 + int(c-'0')
	}
	return n
}

func daysIn(year, month int) int {
	switch month {
	case 2:
		if year%4 == 0 && (year%100 != 0 || year%400 == 0) {
			return 29
		}
		return 28
	case 4, 6, 9, 11:
		return 30
	}
	return 31
}
