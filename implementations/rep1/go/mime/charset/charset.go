// Package charset converts bytes to UTF-8 text for the small set of character
// sets the dump format knows about: ASCII, UTF-8, Latin-1 and windows-1252.
// Any other name is treated as windows-1252.
package charset

import "mimedump/internal/scan"

// Table identifies one of the supported decoding tables.
type Table int

// The supported tables.
const (
	CP1252 Table = iota // the fallback for unknown and empty names
	ASCII
	UTF8
	Latin1
)

// Normalize strips leading and trailing spaces and tabs from name and
// lower-cases its ASCII letters.
func Normalize(name string) string {
	return scan.LowerASCII(scan.Trim(name))
}

// Lookup returns the table for a charset name (normalising it first).
func Lookup(name string) Table {
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

// Decode converts b to a UTF-8 string using the charset called name.
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

const replacement = "\xef\xbf\xbd"

func decodeASCII(b []byte) string {
	out := make([]byte, 0, len(b)+8)
	start := 0
	for i, c := range b {
		if c >= 0x80 {
			out = append(out, b[start:i]...)
			out = append(out, replacement...)
			start = i + 1
		}
	}
	return string(append(out, b[start:]...))
}

func decodeLatin1(b []byte) string {
	out := make([]byte, 0, len(b)*2)
	start := 0
	for i, c := range b {
		if c >= 0x80 {
			out = append(out, b[start:i]...)
			out = append(out, 0xC0|c>>6, 0x80|c&0x3F)
			start = i + 1
		}
	}
	return string(append(out, b[start:]...))
}

// cp1252High maps the bytes 0x80-0x9F to code points.
var cp1252High = [32]rune{
	0x20AC, 0x0081, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
	0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x008D, 0x017D, 0x008F,
	0x0090, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
	0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x009D, 0x017E, 0x0178,
}

func decodeCP1252(b []byte) string {
	out := make([]byte, 0, len(b)*3)
	start := 0
	for i, c := range b {
		if c < 0x80 {
			continue
		}
		out = append(out, b[start:i]...)
		start = i + 1
		r := rune(c)
		if c < 0xA0 {
			r = cp1252High[c-0x80]
		}
		out = appendRune(out, r)
	}
	return string(append(out, b[start:]...))
}

// appendRune appends the UTF-8 encoding of r (never a surrogate here).
func appendRune(out []byte, r rune) []byte {
	switch {
	case r < 0x80:
		return append(out, byte(r))
	case r < 0x800:
		return append(out, 0xC0|byte(r>>6), 0x80|byte(r)&0x3F)
	case r < 0x10000:
		return append(out, 0xE0|byte(r>>12), 0x80|byte(r>>6)&0x3F, 0x80|byte(r)&0x3F)
	}
	return append(out, 0xF0|byte(r>>18), 0x80|byte(r>>12)&0x3F, 0x80|byte(r>>6)&0x3F, 0x80|byte(r)&0x3F)
}

// DecodeUTF8 decodes b as UTF-8, replacing each maximal invalid subpart with
// U+FFFD (see utf8Seq).
func DecodeUTF8(b []byte) string {
	var out []byte // allocated lazily; nil while b is entirely valid
	start := 0
	for i := 0; i < len(b); {
		if b[i] < 0x80 {
			i++
			continue
		}
		n, ok := utf8Seq(b, i)
		if !ok {
			if out == nil {
				out = make([]byte, 0, len(b)+16)
			}
			out = append(out, b[start:i]...)
			out = append(out, replacement...)
			start = i + n
		}
		i += n
	}
	if out == nil {
		return string(b)
	}
	return string(append(out, b[start:]...))
}

// utf8Seq examines the non-ASCII lead byte at b[i]. It returns the number of
// bytes of the sequence and true if it is a complete valid sequence, or the
// number of bytes forming the maximal invalid subpart and false.
func utf8Seq(b []byte, i int) (int, bool) {
	b0 := b[i]
	n := 0
	lo, hi := byte(0x80), byte(0xBF)
	switch {
	case b0 >= 0xC2 && b0 <= 0xDF:
		n = 2
	case b0 == 0xE0:
		n, lo = 3, 0xA0
	case b0 == 0xED:
		n, hi = 3, 0x9F
	case b0 >= 0xE1 && b0 <= 0xEF:
		n = 3
	case b0 == 0xF0:
		n, lo = 4, 0x90
	case b0 >= 0xF1 && b0 <= 0xF3:
		n = 4
	case b0 == 0xF4:
		n, hi = 4, 0x8F
	default:
		return 1, false
	}
	for k := 1; k < n; k++ {
		if i+k >= len(b) {
			return k, false
		}
		c := b[i+k]
		if k == 1 {
			if c < lo || c > hi {
				return k, false
			}
		} else if c < 0x80 || c > 0xBF {
			return k, false
		}
	}
	return n, true
}

// RuneCount returns the number of code points in the valid UTF-8 string s.
func RuneCount(s string) int {
	n := 0
	for i := 0; i < len(s); i++ {
		if s[i]&0xC0 != 0x80 {
			n++
		}
	}
	return n
}
