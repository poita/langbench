// Package charset converts bytes in a named character set to a Go string.
//
// Only the character sets the mime tool knows about are supported: US-ASCII,
// UTF-8, ISO-8859-1 and windows-1252. Every other name falls back to
// windows-1252. The UTF-8 decoder is hand written and replaces invalid input
// using the "maximal subpart" rule.
package charset

import "strings"

// Normalize strips leading and trailing SPACE and TAB from name and lower-cases
// its ASCII letters.
func Normalize(name string) string {
	name = strings.Trim(name, " \t")
	for i := 0; i < len(name); i++ {
		if c := name[i]; c >= 'A' && c <= 'Z' {
			b := []byte(name)
			for j := i; j < len(b); j++ {
				if b[j] >= 'A' && b[j] <= 'Z' {
					b[j] += 'a' - 'A'
				}
			}
			return string(b)
		}
	}
	return name
}

// Kind identifies one of the decoding tables.
type Kind int

// The supported tables.
const (
	ASCII Kind = iota
	UTF8
	Latin1
	CP1252
)

// Lookup maps a charset name (in any case, with optional surrounding blanks)
// to a decoding table. Unknown and empty names map to CP1252.
func Lookup(name string) Kind {
	switch Normalize(name) {
	case "us-ascii", "ascii", "iso-ir-6", "ansi_x3.4-1968", "iso646-us":
		return ASCII
	case "utf-8", "utf8", "unicode-1-1-utf-8":
		return UTF8
	case "iso-8859-1", "iso8859-1", "latin-1", "latin1", "l1", "8859-1", "iso_8859-1":
		return Latin1
	}
	return CP1252
}

// Decode converts b to a string using the character set called name.
func Decode(b []byte, name string) string {
	switch Lookup(name) {
	case ASCII:
		return decodeASCII(b)
	case UTF8:
		return DecodeUTF8(b)
	case Latin1:
		return decodeLatin1(b)
	}
	return decodeCP1252(b)
}

const replacement = '�'

func decodeASCII(b []byte) string {
	clean := true
	for _, c := range b {
		if c >= 0x80 {
			clean = false
			break
		}
	}
	if clean {
		return string(b)
	}
	var sb strings.Builder
	sb.Grow(len(b))
	for _, c := range b {
		if c < 0x80 {
			sb.WriteByte(c)
		} else {
			sb.WriteRune(replacement)
		}
	}
	return sb.String()
}

func decodeLatin1(b []byte) string {
	var sb strings.Builder
	sb.Grow(len(b))
	for _, c := range b {
		sb.WriteRune(rune(c))
	}
	return sb.String()
}

// cp1252High maps bytes 0x80-0x9F to code points.
var cp1252High = [32]rune{
	0x20AC, 0x0081, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
	0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x008D, 0x017D, 0x008F,
	0x0090, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
	0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x009D, 0x017E, 0x0178,
}

func decodeCP1252(b []byte) string {
	var sb strings.Builder
	sb.Grow(len(b))
	for _, c := range b {
		if c >= 0x80 && c <= 0x9F {
			sb.WriteRune(cp1252High[c-0x80])
		} else {
			sb.WriteRune(rune(c))
		}
	}
	return sb.String()
}

// DecodeUTF8 decodes b as UTF-8. Invalid input is replaced by U+FFFD using the
// maximal-subpart rule: an ill-formed sequence yields one U+FFFD for the lead
// byte and the valid continuation bytes that followed it; the byte that broke
// the sequence is decoded afresh.
func DecodeUTF8(b []byte) string {
	n := len(b)
	i := 0
	for i < n && b[i] < 0x80 {
		i++
	}
	if i == n {
		return string(b)
	}
	var sb strings.Builder
	sb.Grow(n + 8)
	sb.Write(b[:i])
	for i < n {
		b0 := b[i]
		if b0 < 0x80 {
			sb.WriteByte(b0)
			i++
			continue
		}
		var need int
		var cp rune
		lo, hi := byte(0x80), byte(0xBF)
		switch {
		case b0 >= 0xC2 && b0 <= 0xDF:
			need, cp = 1, rune(b0&0x1F)
		case b0 == 0xE0:
			need, cp, lo = 2, rune(b0&0x0F), 0xA0
		case b0 >= 0xE1 && b0 <= 0xEC, b0 == 0xEE, b0 == 0xEF:
			need, cp = 2, rune(b0&0x0F)
		case b0 == 0xED:
			need, cp, hi = 2, rune(b0&0x0F), 0x9F
		case b0 == 0xF0:
			need, cp, lo = 3, rune(b0&0x07), 0x90
		case b0 >= 0xF1 && b0 <= 0xF3:
			need, cp = 3, rune(b0&0x07)
		case b0 == 0xF4:
			need, cp, hi = 3, rune(b0&0x07), 0x8F
		default:
			sb.WriteRune(replacement)
			i++
			continue
		}
		j := i + 1
		ok := true
		for k := 0; k < need; k++ {
			if j >= n {
				ok = false
				break
			}
			c := b[j]
			l, h := byte(0x80), byte(0xBF)
			if k == 0 {
				l, h = lo, hi
			}
			if c < l || c > h {
				ok = false
				break
			}
			cp = cp<<6 | rune(c&0x3F)
			j++
		}
		if ok {
			sb.WriteRune(cp)
		} else {
			sb.WriteRune(replacement)
		}
		i = j
	}
	return sb.String()
}
