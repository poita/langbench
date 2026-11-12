// Package date parses RFC 5322 style Date header values leniently and renders
// them as UTC timestamps, using closed-form civil-calendar arithmetic.
package date

import (
	"fmt"
	"strings"

	"example.com/mime/internal/lex"
)

// Date is a successfully parsed date.
type Date struct {
	// OffsetMinutes is the zone offset in minutes east of UTC.
	OffsetMinutes int
	// Epoch is the Unix time in seconds.
	Epoch int64
}

// DaysFromCivil returns the number of days from 1970-01-01 to the given
// proleptic Gregorian date (negative before it).
func DaysFromCivil(y, m, d int) int64 {
	yy := int64(y)
	if m <= 2 {
		yy--
	}
	var era int64
	if yy >= 0 {
		era = yy / 400
	} else {
		era = (yy - 399) / 400
	}
	yoe := yy - era*400
	mp := int64((m + 9) % 12)
	doy := (153*mp+2)/5 + int64(d) - 1
	doe := yoe*365 + yoe/4 - yoe/100 + doy
	return era*146097 + doe - 719468
}

// CivilFromDays is the inverse of DaysFromCivil.
func CivilFromDays(z int64) (y, m, d int) {
	z += 719468
	var era int64
	if z >= 0 {
		era = z / 146097
	} else {
		era = (z - 146096) / 146097
	}
	doe := z - era*146097
	yoe := (doe - doe/1460 + doe/36524 - doe/146096) / 365
	yy := yoe + era*400
	doy := doe - (365*yoe + yoe/4 - yoe/100)
	mp := (5*doy + 2) / 153
	d = int(doy - (153*mp+2)/5 + 1)
	if mp < 10 {
		m = int(mp + 3)
	} else {
		m = int(mp - 9)
	}
	if m <= 2 {
		yy++
	}
	return int(yy), m, d
}

func floorDiv(a, b int64) int64 {
	q := a / b
	if a%b != 0 && (a < 0) != (b < 0) {
		q--
	}
	return q
}

// UTC renders the date as YYYY-MM-DDTHH:MM:SSZ.
func (d Date) UTC() string {
	days := floorDiv(d.Epoch, 86400)
	secs := d.Epoch - days*86400
	y, m, dd := CivilFromDays(days)
	return fmt.Sprintf("%04d-%02d-%02dT%02d:%02d:%02dZ", y, m, dd, secs/3600, secs%3600/60, secs%60)
}

// Offset renders the zone offset as a sign followed by hours and minutes, each
// zero-padded to at least two digits.
func (d Date) Offset() string {
	o, sign := d.OffsetMinutes, '+'
	if o < 0 {
		o, sign = -o, '-'
	}
	return fmt.Sprintf("%c%02d%02d", sign, o/60, o%60)
}

var months = [...]string{"jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"}

var zones = map[string]int{
	"ut": 0, "gmt": 0, "z": 0,
	"est": -300, "edt": -240, "cst": -360, "cdt": -300,
	"mst": -420, "mdt": -360, "pst": -480, "pdt": -420,
}

func isDigits(s string, min, max int) bool {
	if len(s) < min || len(s) > max {
		return false
	}
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return false
		}
	}
	return true
}

func atoi(s string) int {
	n := 0
	for i := 0; i < len(s); i++ {
		n = n*10 + int(s[i]-'0')
	}
	return n
}

func daysIn(y, m int) int {
	switch m {
	case 2:
		if y%4 == 0 && (y%100 != 0 || y%400 == 0) {
			return 29
		}
		return 28
	case 4, 6, 9, 11:
		return 30
	}
	return 31
}

// stripComments removes parenthesised comments (nested, with backslash
// escapes) from v.
func stripComments(v string) string {
	if !strings.Contains(v, "(") {
		return v
	}
	var b strings.Builder
	for i := 0; i < len(v); {
		if v[i] == '(' {
			i = lex.SkipComment(v, i)
			continue
		}
		b.WriteByte(v[i])
		i++
	}
	return b.String()
}

// Parse parses a Date header value. The boolean is false for an invalid date.
func Parse(value string) (Date, bool) {
	v := stripComments(value)
	toks := strings.FieldsFunc(v, func(r rune) bool { return r == ' ' || r == '\t' || r == ',' })
	if len(toks) > 0 {
		switch strings.ToLower(toks[0]) {
		case "mon", "tue", "wed", "thu", "fri", "sat", "sun":
			toks = toks[1:]
		}
	}
	if len(toks) < 4 {
		return Date{}, false
	}
	if !isDigits(toks[0], 1, 2) {
		return Date{}, false
	}
	day := atoi(toks[0])
	if day < 1 || day > 31 {
		return Date{}, false
	}
	month := 0
	if len(toks[1]) == 3 {
		lm := strings.ToLower(toks[1])
		for i, name := range months {
			if lm == name {
				month = i + 1
			}
		}
	}
	if month == 0 {
		return Date{}, false
	}
	if !isDigits(toks[2], 2, 4) {
		return Date{}, false
	}
	year := atoi(toks[2])
	switch len(toks[2]) {
	case 2:
		if year >= 50 {
			year += 1900
		} else {
			year += 2000
		}
	case 3:
		year += 1900
	}
	if year < 1 || year > 9999 {
		return Date{}, false
	}
	parts := strings.Split(toks[3], ":")
	if len(parts) < 2 || len(parts) > 3 {
		return Date{}, false
	}
	for _, p := range parts {
		if !isDigits(p, 1, 2) {
			return Date{}, false
		}
	}
	hh, mm, ss := atoi(parts[0]), atoi(parts[1]), 0
	if len(parts) == 3 {
		ss = atoi(parts[2])
	}
	if hh > 23 || mm > 59 || ss > 60 {
		return Date{}, false
	}
	offset := 0
	if len(toks) > 4 {
		z := toks[4]
		if len(z) == 5 && (z[0] == '+' || z[0] == '-') && isDigits(z[1:], 4, 4) {
			offset = atoi(z[1:3])*60 + atoi(z[3:5])
			if z[0] == '-' {
				offset = -offset
			}
		} else if o, ok := zones[strings.ToLower(z)]; ok {
			offset = o
		}
	}
	if day > daysIn(year, month) {
		return Date{}, false
	}
	epoch := DaysFromCivil(year, month, day)*86400 + int64(hh*3600+mm*60+ss) - int64(offset)*60
	return Date{OffsetMinutes: offset, Epoch: epoch}, true
}
