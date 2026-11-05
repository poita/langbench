package toml

import (
	"errors"
	"math"
	"math/bits"
	"strconv"
)

func isDigit(c byte) bool { return c >= '0' && c <= '9' }

func isScalarDelim(c byte) bool {
	switch c {
	case ' ', '\t', '\n', '\r', ',', ']', '}', '#':
		return true
	}
	return false
}

// parseScalar parses a bare token: boolean, number or date/time.
func (p *parser) parseScalar() *Node {
	src := p.src
	start := p.pos
	end := start
	for end < len(src) && !isScalarDelim(src[end]) {
		end++
	}
	// A date followed by a space and a complete time is one date-time token.
	if end-start == 10 && end+9 <= len(src) && src[end] == ' ' && looksLikeDate(src[start:end]) && looksLikeTime(src[end+1:end+9]) {
		end += 9
		for end < len(src) && !isScalarDelim(src[end]) {
			end++
		}
	}
	tok := src[start:end]
	p.pos = end
	if len(tok) == 0 {
		p.fail("expected a value")
	}
	switch {
	case string(tok) == "true":
		return newScalar(KindBool, "true")
	case string(tok) == "false":
		return newScalar(KindBool, "false")
	case len(tok) >= 5 && tok[4] == '-' && isDigit(tok[0]) && isDigit(tok[1]) && isDigit(tok[2]) && isDigit(tok[3]):
		if kind, text, ok := parseDateTime(tok); ok {
			return newScalar(kind, text)
		}
		p.failAt(start, "invalid date or time")
	case len(tok) >= 3 && tok[2] == ':' && isDigit(tok[0]) && isDigit(tok[1]):
		if kind, text, ok := parseDateTime(tok); ok {
			return newScalar(kind, text)
		}
		p.failAt(start, "invalid date or time")
	}
	n, ok := parseNumber(tok)
	if !ok {
		p.failAt(start, "invalid value")
	}
	return n
}

func looksLikeDate(s []byte) bool {
	return len(s) == 10 && s[4] == '-' && s[7] == '-' &&
		isDigit(s[0]) && isDigit(s[1]) && isDigit(s[2]) && isDigit(s[3]) &&
		isDigit(s[5]) && isDigit(s[6]) && isDigit(s[8]) && isDigit(s[9])
}

func looksLikeTime(s []byte) bool {
	return len(s) >= 8 && s[2] == ':' && s[5] == ':' &&
		isDigit(s[0]) && isDigit(s[1]) && isDigit(s[3]) && isDigit(s[4]) &&
		isDigit(s[6]) && isDigit(s[7])
}

func atoi2(s []byte) int { return int(s[0]-'0')*10 + int(s[1]-'0') }

func validDate(s []byte) bool {
	if !looksLikeDate(s) {
		return false
	}
	year := atoi2(s[0:2])*100 + atoi2(s[2:4])
	month, day := atoi2(s[5:7]), atoi2(s[8:10])
	if year < 1 || month < 1 || month > 12 || day < 1 {
		return false
	}
	dim := [...]int{31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31}[month-1]
	if month == 2 && (year%4 == 0 && (year%100 != 0 || year%400 == 0)) {
		dim = 29
	}
	return day <= dim
}

// parseTimeOfDay validates "HH:MM:SS[.frac]" at the start of s and returns the
// canonical text and the unconsumed rest.
func parseTimeOfDay(s []byte) (text []byte, rest []byte, ok bool) {
	if !looksLikeTime(s) || atoi2(s[0:2]) > 23 || atoi2(s[3:5]) > 59 || atoi2(s[6:8]) > 59 {
		return nil, nil, false
	}
	text = append(text, s[:8]...)
	i := 8
	if i < len(s) && s[i] == '.' {
		j := i + 1
		for j < len(s) && isDigit(s[j]) {
			j++
		}
		if j == i+1 {
			return nil, nil, false
		}
		end := j
		for end > i+1 && s[end-1] == '0' {
			end--
		}
		if end > i+1 {
			text = append(text, s[i:end]...)
		}
		i = j
	}
	return text, s[i:], true
}

// parseDateTime validates and canonicalises a date, time or date-time token.
func parseDateTime(s []byte) (Kind, string, bool) {
	if s[2] == ':' {
		text, rest, ok := parseTimeOfDay(s)
		if !ok || len(rest) != 0 {
			return 0, "", false
		}
		return KindTimeLocal, string(text), true
	}
	if len(s) < 10 || !validDate(s[:10]) {
		return 0, "", false
	}
	if len(s) == 10 {
		return KindDateLocal, string(s), true
	}
	if c := s[10]; c != 'T' && c != 't' && c != ' ' {
		return 0, "", false
	}
	tm, rest, ok := parseTimeOfDay(s[11:])
	if !ok {
		return 0, "", false
	}
	out := make([]byte, 0, len(s)+1)
	out = append(out, s[:10]...)
	out = append(out, 'T')
	out = append(out, tm...)
	if len(rest) == 0 {
		return KindDatetimeLocal, string(out), true
	}
	if len(rest) == 1 && (rest[0] == 'Z' || rest[0] == 'z') {
		return KindDatetime, string(append(out, 'Z')), true
	}
	if len(rest) == 6 && (rest[0] == '+' || rest[0] == '-') && rest[3] == ':' &&
		isDigit(rest[1]) && isDigit(rest[2]) && isDigit(rest[4]) && isDigit(rest[5]) &&
		atoi2(rest[1:3]) <= 23 && atoi2(rest[4:6]) <= 59 {
		if rest[1] == '0' && rest[2] == '0' && rest[4] == '0' && rest[5] == '0' {
			return KindDatetime, string(append(out, 'Z')), true
		}
		return KindDatetime, string(append(out, rest...)), true
	}
	return 0, "", false
}

// scanDigits scans digit ("_"? digit)* starting at s[j] and returns the end.
func scanDigits(s []byte, j int) (int, bool) {
	if j >= len(s) || !isDigit(s[j]) {
		return j, false
	}
	j++
	for j < len(s) {
		if isDigit(s[j]) {
			j++
		} else if s[j] == '_' && j+1 < len(s) && isDigit(s[j+1]) {
			j += 2
		} else {
			break
		}
	}
	return j, true
}

// parseNumber parses an integer or float token.
func parseNumber(tok []byte) (*Node, bool) {
	i, neg, signed := 0, false, false
	if tok[0] == '+' || tok[0] == '-' {
		i, neg, signed = 1, tok[0] == '-', true
	}
	rest := tok[i:]
	switch string(rest) {
	case "inf":
		if neg {
			return newScalar(KindFloat, "-inf"), true
		}
		return newScalar(KindFloat, "inf"), true
	case "nan":
		return newScalar(KindFloat, "nan"), true
	}
	if len(rest) == 0 {
		return nil, false
	}
	if len(rest) > 1 && rest[0] == '0' && (rest[1] == 'x' || rest[1] == 'o' || rest[1] == 'b') {
		if signed {
			return nil, false
		}
		return parseRadixInt(rest[2:], rest[1])
	}
	// Integer part: "0" or [1-9] ("_"? digit)*.
	if !isDigit(rest[0]) {
		return nil, false
	}
	j := 1
	if rest[0] != '0' {
		j, _ = scanDigits(rest, 0)
	}
	if j == len(rest) {
		return parseDecimalInt(rest, neg)
	}
	var ok bool
	if rest[j] == '.' {
		if j, ok = scanDigits(rest, j+1); !ok {
			return nil, false
		}
	}
	if j < len(rest) && (rest[j] == 'e' || rest[j] == 'E') {
		j++
		if j < len(rest) && (rest[j] == '+' || rest[j] == '-') {
			j++
		}
		if j, ok = scanDigits(rest, j); !ok {
			return nil, false
		}
	}
	if j != len(rest) {
		return nil, false
	}
	clean := make([]byte, 0, len(tok))
	for _, c := range tok {
		if c != '_' {
			clean = append(clean, c)
		}
	}
	f, err := strconv.ParseFloat(string(clean), 64)
	if err != nil && !errors.Is(err, strconv.ErrRange) {
		return nil, false
	}
	return newScalar(KindFloat, formatFloat(f)), true
}

// formatFloat renders f in the canonical form: nan, inf, -inf or %.16e.
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

func parseDecimalInt(digits []byte, neg bool) (*Node, bool) {
	var v uint64
	for _, c := range digits {
		if c == '_' {
			continue
		}
		var ok bool
		if v, ok = mulAdd(v, 10, uint64(c-'0')); !ok {
			return nil, false
		}
	}
	return intNode(v, neg)
}

func parseRadixInt(digits []byte, prefix byte) (*Node, bool) {
	base := uint64(2)
	switch prefix {
	case 'x':
		base = 16
	case 'o':
		base = 8
	}
	if len(digits) == 0 {
		return nil, false
	}
	var v uint64
	prevDigit := false
	for _, c := range digits {
		if c == '_' {
			if !prevDigit {
				return nil, false
			}
			prevDigit = false
			continue
		}
		var d uint64
		switch {
		case c >= '0' && c <= '9':
			d = uint64(c - '0')
		case c >= 'a' && c <= 'f':
			d = uint64(c-'a') + 10
		case c >= 'A' && c <= 'F':
			d = uint64(c-'A') + 10
		default:
			return nil, false
		}
		if d >= base {
			return nil, false
		}
		var ok bool
		if v, ok = mulAdd(v, base, d); !ok {
			return nil, false
		}
		prevDigit = true
	}
	if !prevDigit {
		return nil, false
	}
	return intNode(v, false)
}

// mulAdd returns v*m+d, reporting overflow of uint64.
func mulAdd(v, m, d uint64) (uint64, bool) {
	hi, lo := bits.Mul64(v, m)
	lo, carry := bits.Add64(lo, d, 0)
	return lo, hi == 0 && carry == 0
}

// intNode builds an integer node from a magnitude, enforcing the int64 range.
func intNode(mag uint64, neg bool) (*Node, bool) {
	if neg {
		if mag > 1<<63 {
			return nil, false
		}
		return newScalar(KindInteger, strconv.FormatInt(int64(-mag), 10)), true
	}
	if mag > math.MaxInt64 {
		return nil, false
	}
	return newScalar(KindInteger, strconv.FormatUint(mag, 10)), true
}
