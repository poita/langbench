// Package svgparse parses the small value grammars SVG attributes use:
// numbers, lengths, opacities, colours, transform lists and style
// declarations.
package svgparse

import (
	"math"
	"strconv"
	"strings"
)

// IsSpace reports whether c is an XML/SVG whitespace byte.
func IsSpace(c byte) bool { return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' }

// SkipSep returns the index of the first byte at or after i that is neither
// whitespace nor a comma.
func SkipSep(s string, i int) int {
	for i < len(s) && (IsSpace(s[i]) || s[i] == ',') {
		i++
	}
	return i
}

func isDigit(c byte) bool { return c >= '0' && c <= '9' }

// ScanNumber parses a number starting exactly at s[i] (no leading space
// skipping). It returns the value and the index just past the number. An
// exponent that is not followed by a digit is not part of the number.
func ScanNumber(s string, i int) (v float64, next int, ok bool) {
	start := i
	if i < len(s) && (s[i] == '+' || s[i] == '-') {
		i++
	}
	digits := 0
	for i < len(s) && isDigit(s[i]) {
		i++
		digits++
	}
	if i < len(s) && s[i] == '.' {
		i++
		for i < len(s) && isDigit(s[i]) {
			i++
			digits++
		}
	}
	if digits == 0 {
		return 0, start, false
	}
	if i < len(s) && (s[i] == 'e' || s[i] == 'E') {
		j := i + 1
		if j < len(s) && (s[j] == '+' || s[j] == '-') {
			j++
		}
		if j < len(s) && isDigit(s[j]) {
			for j < len(s) && isDigit(s[j]) {
				j++
			}
			i = j
		}
	}
	// ParseFloat returns ±Inf with an error on overflow, which is the
	// value we want; syntax errors cannot occur here.
	v, _ = strconv.ParseFloat(s[start:i], 64)
	return v, i, true
}

// NumberList parses numbers separated by whitespace and/or commas, stopping
// at the first token that is not a number.
func NumberList(s string) []float64 {
	var out []float64
	i := 0
	for {
		i = SkipSep(s, i)
		v, n, ok := ScanNumber(s, i)
		if !ok {
			return out
		}
		out = append(out, v)
		i = n
	}
}

// Length parses a number optionally followed by "px", with surrounding
// whitespace allowed. ok is false when s does not start with a number.
func Length(s string) (v float64, ok bool) {
	i := 0
	for i < len(s) && IsSpace(s[i]) {
		i++
	}
	v, _, ok = ScanNumber(s, i)
	return v, ok
}

// Opacity parses a number or a percentage and clamps it to [0, 1]. ok is
// false for anything else.
func Opacity(s string) (v float64, ok bool) {
	s = strings.TrimSpace(s)
	v, n, ok := ScanNumber(s, 0)
	if !ok {
		return 0, false
	}
	switch s[n:] {
	case "":
	case "%":
		v /= 100
	default:
		return 0, false
	}
	if v != v {
		return 0, false
	}
	return math.Min(1, math.Max(0, v)), true
}

// Style splits a style attribute into declarations and calls fn for each
// valid one, in order. Names are lower-cased and both parts are trimmed;
// declarations without a colon or with an empty value are skipped.
func Style(s string, fn func(name, value string)) {
	for len(s) > 0 {
		var decl string
		if i := strings.IndexByte(s, ';'); i >= 0 {
			decl, s = s[:i], s[i+1:]
		} else {
			decl, s = s, ""
		}
		c := strings.IndexByte(decl, ':')
		if c < 0 {
			continue
		}
		name := strings.ToLower(strings.TrimSpace(decl[:c]))
		value := strings.TrimSpace(decl[c+1:])
		if name == "" || value == "" {
			continue
		}
		fn(name, value)
	}
}
