package toml

import (
	"errors"
	"math"
	"strconv"
	"strings"
)

func isDigit(c byte) bool { return c >= '0' && c <= '9' }

func isTokenChar(c byte) bool {
	return isDigit(c) || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' ||
		c == '_' || c == '+' || c == '-' || c == '.' || c == ':'
}

// scalarToken parses a bare scalar: boolean, number or date/time.
func (p *parser) scalarToken() Node {
	start := p.pos
	for p.pos < len(p.data) && isTokenChar(p.data[p.pos]) {
		p.pos++
	}
	tok := string(p.data[start:p.pos])
	if tok == "" {
		p.fail("unexpected character %q", p.data[p.pos])
	}
	switch tok {
	case "true", "false":
		return &Value{TypeBool, tok}
	case "inf", "+inf":
		return &Value{TypeFloat, "inf"}
	case "-inf":
		return &Value{TypeFloat, "-inf"}
	case "nan", "+nan", "-nan":
		return &Value{TypeFloat, "nan"}
	}
	if _, ok := digits(tok, 4); ok && len(tok) > 4 && tok[4] == '-' {
		return p.dateToken(tok)
	}
	if len(tok) > 2 && tok[2] == ':' {
		text, rest, ok := parseTime(tok)
		if !ok || rest != "" {
			p.fail("invalid time")
		}
		return &Value{TypeTimeLocal, text}
	}
	v, ok := parseNumber(tok)
	if !ok {
		p.fail("invalid value %q", tok)
	}
	return v
}

// parseNumber parses a TOML integer or float literal.
func parseNumber(s string) (*Value, bool) {
	if len(s) > 2 && s[0] == '0' {
		base := 0
		var isDig func(byte) bool
		switch s[1] {
		case 'x':
			base, isDig = 16, func(c byte) bool { return hexVal(c) >= 0 }
		case 'o':
			base, isDig = 8, func(c byte) bool { return c >= '0' && c <= '7' }
		case 'b':
			base, isDig = 2, func(c byte) bool { return c == '0' || c == '1' }
		}
		if base != 0 {
			end, ok := scanDigits(s, 2, isDig)
			if !ok || end != len(s) {
				return nil, false
			}
			n, err := strconv.ParseInt(strings.ReplaceAll(s[2:], "_", ""), base, 64)
			if err != nil {
				return nil, false
			}
			return &Value{TypeInteger, strconv.FormatInt(n, 10)}, true
		}
	}

	i := 0
	if s[0] == '+' || s[0] == '-' {
		i++
	}
	if i >= len(s) {
		return nil, false
	}
	if s[i] == '0' {
		i++
	} else if s[i] >= '1' && s[i] <= '9' {
		var ok bool
		if i, ok = scanDigits(s, i, isDigit); !ok {
			return nil, false
		}
	} else {
		return nil, false
	}
	if i == len(s) {
		n, err := strconv.ParseInt(strings.ReplaceAll(s, "_", ""), 10, 64)
		if err != nil {
			return nil, false
		}
		return &Value{TypeInteger, strconv.FormatInt(n, 10)}, true
	}

	if s[i] == '.' {
		var ok bool
		if i, ok = scanDigits(s, i+1, isDigit); !ok {
			return nil, false
		}
	}
	if i < len(s) && (s[i] == 'e' || s[i] == 'E') {
		i++
		if i < len(s) && (s[i] == '+' || s[i] == '-') {
			i++
		}
		var ok bool
		if i, ok = scanDigits(s, i, isDigit); !ok {
			return nil, false
		}
	}
	if i != len(s) {
		return nil, false
	}
	f, err := strconv.ParseFloat(strings.ReplaceAll(s, "_", ""), 64)
	if err != nil && !errors.Is(err, strconv.ErrRange) {
		return nil, false
	}
	return &Value{TypeFloat, formatFloat(f)}, true
}

// scanDigits scans digits starting at s[i] with single underscores allowed
// between digits, and returns the index after the last digit. At least one
// digit is required.
func scanDigits(s string, i int, isDig func(byte) bool) (int, bool) {
	if i >= len(s) || !isDig(s[i]) {
		return i, false
	}
	i++
	for i < len(s) {
		switch {
		case isDig(s[i]):
			i++
		case s[i] == '_' && i+1 < len(s) && isDig(s[i+1]):
			i += 2
		default:
			return i, true
		}
	}
	return i, true
}

// formatFloat renders f in the canonical text form for floats.
func formatFloat(f float64) string {
	switch {
	case math.IsNaN(f):
		return "nan"
	case math.IsInf(f, 1):
		return "inf"
	case math.IsInf(f, -1):
		return "-inf"
	}
	return strconv.FormatFloat(f, 'e', 16, 64)
}
