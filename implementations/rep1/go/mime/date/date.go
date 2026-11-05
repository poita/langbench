// Package date parses the Date header into an instant, using a forgiving
// grammar and hand-written calendar arithmetic.
package date

import (
	"strings"

	"mimedump/internal/scan"
)

// Date is a successfully parsed Date header.
type Date struct {
	Epoch         int64 // seconds since 1970-01-01T00:00:00Z
	OffsetMinutes int   // the zone offset as written
}

var months = []string{"jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"}

var weekdays = []string{"mon", "tue", "wed", "thu", "fri", "sat", "sun"}

var zones = map[string]int{
	"ut": 0, "gmt": 0, "z": 0,
	"est": -300, "edt": -240, "cst": -360, "cdt": -300,
	"mst": -420, "mdt": -360, "pst": -480, "pdt": -420,
}

// Parse parses the unfolded raw value of a Date header. ok is false if the
// value is not a valid date.
func Parse(raw string) (d Date, ok bool) {
	toks := tokens(stripComments(raw))
	if len(toks) > 0 && indexOf(weekdays, strings.ToLower(toks[0])) >= 0 {
		toks = toks[1:]
	}
	if len(toks) < 4 {
		return Date{}, false
	}
	day, ok1 := number(toks[0], 2)
	month := indexOf(months, strings.ToLower(toks[1])) + 1
	year, ok2 := number(toks[2], 4)
	if !ok1 || !ok2 || month == 0 || day < 1 || day > 31 || len(toks[2]) < 2 {
		return Date{}, false
	}
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
	if year < 1 || year > 9999 || day > daysIn(year, month) {
		return Date{}, false
	}
	hh, mm, ss, ok := clock(toks[3])
	if !ok {
		return Date{}, false
	}
	off := 0
	if len(toks) > 4 {
		off = zoneOffset(toks[4])
	}
	days := DaysFromCivil(int64(year), month, day)
	epoch := days*86400 + int64(hh*3600+mm*60+ss) - int64(off)*60
	return Date{Epoch: epoch, OffsetMinutes: off}, true
}

func stripComments(s string) string {
	if !strings.Contains(s, "(") {
		return s
	}
	var sb strings.Builder
	for i := 0; i < len(s); {
		if s[i] == '(' {
			i = scan.Comment(s, i)
		} else {
			sb.WriteByte(s[i])
			i++
		}
	}
	return sb.String()
}

// tokens splits on runs of SPACE, TAB and comma.
func tokens(s string) []string {
	return strings.FieldsFunc(s, func(r rune) bool { return r == ' ' || r == '\t' || r == ',' })
}

func indexOf(list []string, s string) int {
	for i, x := range list {
		if x == s {
			return i
		}
	}
	return -1
}

// number parses 1..max ASCII decimal digits (max applies to the length).
func number(s string, max int) (int, bool) {
	if len(s) == 0 || len(s) > max {
		return 0, false
	}
	n := 0
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return 0, false
		}
		n = n*10 + int(s[i]-'0')
	}
	return n, true
}

func clock(s string) (hh, mm, ss int, ok bool) {
	parts := strings.Split(s, ":")
	if len(parts) != 2 && len(parts) != 3 {
		return
	}
	var okh, okm bool
	hh, okh = number(parts[0], 2)
	mm, okm = number(parts[1], 2)
	if !okh || !okm || hh > 23 || mm > 59 {
		return 0, 0, 0, false
	}
	if len(parts) == 3 {
		var oks bool
		ss, oks = number(parts[2], 2)
		if !oks || ss > 60 {
			return 0, 0, 0, false
		}
	}
	return hh, mm, ss, true
}

func zoneOffset(z string) int {
	if len(z) == 5 && (z[0] == '+' || z[0] == '-') {
		if n, ok := number(z[1:], 4); ok && len(z) == 5 {
			off := n/100*60 + n%100
			if z[0] == '-' {
				off = -off
			}
			return off
		}
	}
	return zones[strings.ToLower(z)]
}

func isLeap(y int) bool { return y%4 == 0 && (y%100 != 0 || y%400 == 0) }

func daysIn(y, m int) int {
	switch m {
	case 2:
		if isLeap(y) {
			return 29
		}
		return 28
	case 4, 6, 9, 11:
		return 30
	}
	return 31
}

func floorDiv(a, b int64) int64 {
	q := a / b
	if a%b != 0 && (a < 0) != (b < 0) {
		q--
	}
	return q
}

// DaysFromCivil returns the number of days from 1970-01-01 to the given
// proleptic Gregorian date (negative before it).
func DaysFromCivil(y int64, m, d int) int64 {
	if m <= 2 {
		y--
	}
	era := floorDiv(y, 400)
	yoe := y - era*400
	mp := int64(m + 9)
	if m > 2 {
		mp = int64(m - 3)
	}
	doy := (153*mp+2)/5 + int64(d) - 1
	doe := yoe*365 + yoe/4 - yoe/100 + doy
	return era*146097 + doe - 719468
}

// CivilFromDays is the inverse of DaysFromCivil.
func CivilFromDays(z int64) (y int64, m, d int) {
	z += 719468
	era := floorDiv(z, 146097)
	doe := z - era*146097
	yoe := (doe - doe/1460 + doe/36524 - doe/146096) / 365
	y = yoe + era*400
	doy := doe - (365*yoe + yoe/4 - yoe/100)
	mp := (5*doy + 2) / 153
	d = int(doy - (153*mp+2)/5 + 1)
	if mp < 10 {
		m = int(mp + 3)
	} else {
		m = int(mp - 9)
	}
	if m <= 2 {
		y++
	}
	return y, m, d
}

// UTC renders the instant as YYYY-MM-DDTHH:MM:SSZ.
func (d Date) UTC() string {
	days := floorDiv(d.Epoch, 86400)
	sec := d.Epoch - days*86400
	y, m, dd := CivilFromDays(days)
	buf := make([]byte, 0, 20)
	buf = pad(buf, y, 4)
	buf = append(buf, '-')
	buf = pad(buf, int64(m), 2)
	buf = append(buf, '-')
	buf = pad(buf, int64(dd), 2)
	buf = append(buf, 'T')
	buf = pad(buf, sec/3600, 2)
	buf = append(buf, ':')
	buf = pad(buf, sec%3600/60, 2)
	buf = append(buf, ':')
	buf = pad(buf, sec%60, 2)
	return string(append(buf, 'Z'))
}

// Offset renders the zone offset as ±HHMM (more digits if the hours exceed 99).
func (d Date) Offset() string {
	o := d.OffsetMinutes
	sign := byte('+')
	if o < 0 {
		sign, o = '-', -o
	}
	buf := []byte{sign}
	buf = pad(buf, int64(o/60), 2)
	return string(pad(buf, int64(o%60), 2))
}

// pad appends n in decimal, zero-padded to at least width digits.
func pad(buf []byte, n int64, width int) []byte {
	var digits [20]byte
	i := len(digits)
	for n > 0 || i == len(digits) {
		i--
		digits[i] = byte('0' + n%10)
		n /= 10
	}
	for k := len(digits) - i; k < width; k++ {
		buf = append(buf, '0')
	}
	return append(buf, digits[i:]...)
}
