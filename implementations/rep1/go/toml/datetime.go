package toml

import "strings"

func digits(s string, n int) (int, bool) {
	if len(s) < n {
		return 0, false
	}
	v := 0
	for i := 0; i < n; i++ {
		if !isDigit(s[i]) {
			return 0, false
		}
		v = v*10 + int(s[i]-'0')
	}
	return v, true
}

func daysInMonth(year, month int) int {
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

// parseDate validates the 10-byte prefix YYYY-MM-DD of s.
func parseDate(s string) (string, bool) {
	if len(s) < 10 || s[4] != '-' || s[7] != '-' {
		return "", false
	}
	y, ok1 := digits(s, 4)
	m, ok2 := digits(s[5:], 2)
	d, ok3 := digits(s[8:], 2)
	if !ok1 || !ok2 || !ok3 || y < 1 || m < 1 || m > 12 || d < 1 || d > daysInMonth(y, m) {
		return "", false
	}
	return s[:10], true
}

// parseTime validates a time HH:MM:SS[.frac] at the start of s and returns
// its canonical text plus whatever follows it.
func parseTime(s string) (text, rest string, ok bool) {
	if len(s) < 8 || s[2] != ':' || s[5] != ':' {
		return "", "", false
	}
	h, ok1 := digits(s, 2)
	m, ok2 := digits(s[3:], 2)
	sec, ok3 := digits(s[6:], 2)
	if !ok1 || !ok2 || !ok3 || h > 23 || m > 59 || sec > 59 {
		return "", "", false
	}
	text, rest = s[:8], s[8:]
	if strings.HasPrefix(rest, ".") {
		n := 1
		for n < len(rest) && isDigit(rest[n]) {
			n++
		}
		if n == 1 {
			return "", "", false
		}
		if frac := strings.TrimRight(rest[1:n], "0"); frac != "" {
			text += "." + frac
		}
		rest = rest[n:]
	}
	return text, rest, true
}

// parseOffset validates a UTC offset and returns its canonical text.
func parseOffset(s string) (string, bool) {
	if s == "Z" || s == "z" {
		return "Z", true
	}
	if len(s) != 6 || (s[0] != '+' && s[0] != '-') || s[3] != ':' {
		return "", false
	}
	h, ok1 := digits(s[1:], 2)
	m, ok2 := digits(s[4:], 2)
	if !ok1 || !ok2 || h > 23 || m > 59 {
		return "", false
	}
	if h == 0 && m == 0 {
		return "Z", true
	}
	return s, true
}

// dateToken parses a token that starts like a date. tok has already been
// scanned; a space separating the date from its time is handled here.
func (p *parser) dateToken(tok string) Node {
	date, ok := parseDate(tok)
	if !ok {
		p.fail("invalid date")
	}
	rest := tok[10:]
	if rest == "" {
		// A space separator only counts when a time follows it.
		if p.peek() != ' ' || p.pos+1 >= len(p.data) || !isDigit(p.data[p.pos+1]) {
			return &Value{TypeDateLocal, date}
		}
		p.pos++
		start := p.pos
		for p.pos < len(p.data) && isTokenChar(p.data[p.pos]) {
			p.pos++
		}
		rest = "T" + string(p.data[start:p.pos])
	}
	if rest[0] != 'T' && rest[0] != 't' {
		p.fail("invalid date-time")
	}
	timeText, tail, ok := parseTime(rest[1:])
	if !ok {
		p.fail("invalid time")
	}
	if tail == "" {
		return &Value{TypeDatetimeLocal, date + "T" + timeText}
	}
	off, ok := parseOffset(tail)
	if !ok {
		p.fail("invalid offset")
	}
	return &Value{TypeDatetime, date + "T" + timeText + off}
}
