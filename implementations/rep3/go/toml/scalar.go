package toml

import (
	"math"
	"strconv"
)

func isDigit(c byte) bool { return c >= '0' && c <= '9' }

// tokenEnd reports whether c ends a bare scalar token.
func tokenEnd(c byte) bool {
	switch c {
	case ' ', '\t', '\n', '\r', '#', ',', ']', '}':
		return true
	}
	return false
}

// scalar parses a bare scalar token (boolean, number or date-time).
func (p *parser) scalar() *Node {
	start := p.pos
	for p.pos < len(p.src) && !tokenEnd(p.src[p.pos]) {
		p.pos++
	}
	// A date followed by a space and a time-looking token is one date-time.
	if p.pos-start == 10 && p.pos+3 < len(p.src) && p.src[p.pos] == ' ' &&
		isDigit(p.src[p.pos+1]) && isDigit(p.src[p.pos+2]) && p.src[p.pos+3] == ':' &&
		isDateShape(p.src[start:p.pos]) {
		p.pos++
		for p.pos < len(p.src) && !tokenEnd(p.src[p.pos]) {
			p.pos++
		}
	}
	tok := p.src[start:p.pos]
	if len(tok) == 0 {
		p.fail("expected value")
	}
	var n *Node
	switch {
	case string(tok) == "true" || string(tok) == "false":
		n = NewScalar(Bool, string(tok))
	case len(tok) >= 5 && isDigit(tok[0]) && isDigit(tok[1]) && isDigit(tok[2]) && isDigit(tok[3]) && tok[4] == '-':
		n = parseDateTime(tok, true)
	case len(tok) >= 3 && isDigit(tok[0]) && isDigit(tok[1]) && tok[2] == ':':
		n = parseDateTime(tok, false)
	default:
		n = parseNumber(tok)
	}
	if n == nil {
		p.failAt(start, "invalid value")
	}
	return n
}

// isDateShape reports whether tok looks like DDDD-DD-DD.
func isDateShape(tok []byte) bool {
	if len(tok) != 10 {
		return false
	}
	for i, c := range tok {
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

// parseNumber parses an integer or float token. It returns nil if invalid.
func parseNumber(tok []byte) *Node {
	// Special floats.
	switch s := string(tok); s {
	case "inf", "+inf":
		return NewScalar(Float, "inf")
	case "-inf":
		return NewScalar(Float, "-inf")
	case "nan", "+nan", "-nan":
		return NewScalar(Float, "nan")
	}
	// Prefixed integers (no sign allowed).
	if len(tok) > 2 && tok[0] == '0' {
		var base uint64
		switch tok[1] {
		case 'x':
			base = 16
		case 'o':
			base = 8
		case 'b':
			base = 2
		}
		if base != 0 {
			return parsePrefixedInt(tok[2:], base)
		}
	}
	i := 0
	neg := false
	if i < len(tok) && (tok[i] == '+' || tok[i] == '-') {
		neg = tok[i] == '-'
		i++
	}
	// Integer part.
	intStart := i
	if i >= len(tok) || !isDigit(tok[i]) {
		return nil
	}
	if tok[i] == '0' {
		i++
	} else {
		i = scanDigits(tok, i)
		if i < 0 {
			return nil
		}
	}
	intEnd := i
	if i == len(tok) {
		return decimalInt(tok[intStart:intEnd], neg)
	}
	// Float: fraction and/or exponent.
	if tok[i] == '.' {
		i++
		i = scanDigits(tok, i)
		if i < 0 {
			return nil
		}
	}
	if i < len(tok) && (tok[i] == 'e' || tok[i] == 'E') {
		i++
		if i < len(tok) && (tok[i] == '+' || tok[i] == '-') {
			i++
		}
		i = scanDigits(tok, i)
		if i < 0 {
			return nil
		}
	}
	if i != len(tok) {
		return nil
	}
	clean := make([]byte, 0, len(tok))
	for _, c := range tok {
		if c != '_' {
			clean = append(clean, c)
		}
	}
	f, err := strconv.ParseFloat(string(clean), 64)
	if err != nil {
		// Out-of-range values come back as ±Inf (or 0); anything else is invalid.
		if ne, ok := err.(*strconv.NumError); !ok || ne.Err != strconv.ErrRange {
			return nil
		}
	}
	if math.IsNaN(f) {
		return nil
	}
	return NewScalar(Float, formatFloat(f))
}

// scanDigits scans digit ( "_"? digit )* starting at i, returning the index
// after it, or -1 if there is no digit at i or an underscore is misplaced.
func scanDigits(tok []byte, i int) int {
	if i >= len(tok) || !isDigit(tok[i]) {
		return -1
	}
	i++
	for i < len(tok) {
		if isDigit(tok[i]) {
			i++
		} else if tok[i] == '_' {
			if i+1 >= len(tok) || !isDigit(tok[i+1]) {
				return -1
			}
			i += 2
		} else {
			break
		}
	}
	return i
}

// decimalInt converts the digits (possibly with underscores) of a decimal
// integer, applying the sign, with a 64-bit range check on the value.
func decimalInt(digits []byte, neg bool) *Node {
	var mag uint64
	for _, c := range digits {
		if c == '_' {
			continue
		}
		d := uint64(c - '0')
		if mag > (math.MaxUint64-d)/10 {
			return nil
		}
		mag = mag*10 + d
	}
	return signedInt(mag, neg)
}

func signedInt(mag uint64, neg bool) *Node {
	if neg {
		if mag > 1<<63 {
			return nil
		}
		return NewScalar(Integer, strconv.FormatInt(-int64(mag), 10))
	}
	if mag > math.MaxInt64 {
		return nil
	}
	return NewScalar(Integer, strconv.FormatInt(int64(mag), 10))
}

// parsePrefixedInt parses the digits after 0x / 0o / 0b.
func parsePrefixedInt(digits []byte, base uint64) *Node {
	var mag uint64
	prevDigit := false
	for i, c := range digits {
		if c == '_' {
			if !prevDigit || i == len(digits)-1 {
				return nil
			}
			prevDigit = false
			continue
		}
		h, ok := hexVal(c)
		if !ok || uint64(h) >= base {
			return nil
		}
		prevDigit = true
		if mag > (math.MaxUint64-uint64(h))/base {
			return nil
		}
		mag = mag*base + uint64(h)
	}
	if !prevDigit {
		return nil
	}
	return signedInt(mag, false)
}
