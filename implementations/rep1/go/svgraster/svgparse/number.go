// Package svgparse parses the small value grammars SVG attributes use:
// numbers, lengths, opacities, colours, transform lists and style
// declarations.
package svgparse

import (
	"strconv"
	"strings"

	"svgraster/geom"
)

func isSpace(c byte) bool {
	return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f'
}

func isDigit(c byte) bool { return c >= '0' && c <= '9' }

// ScanNumber scans a number at the start of s and returns its value and the
// number of bytes consumed. n == 0 means s does not start with a number.
//
// The grammar is an optional sign, digits with an optional fraction (at least
// one digit overall) and an optional exponent, which is only part of the
// number when it contains at least one digit.
func ScanNumber(s string) (v float64, n int) {
	i := 0
	if i < len(s) && (s[i] == '+' || s[i] == '-') {
		i++
	}
	digits := 0
	for i < len(s) && isDigit(s[i]) {
		i++
		digits++
	}
	if i < len(s) && s[i] == '.' {
		j := i + 1
		frac := 0
		for j < len(s) && isDigit(s[j]) {
			j++
			frac++
		}
		if digits+frac > 0 {
			i = j
			digits += frac
		}
	}
	if digits == 0 {
		return 0, 0
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
	f, err := strconv.ParseFloat(s[:i], 64)
	if err != nil {
		// Out-of-range values come back as ±Inf with err set; keep them
		// only if they are finite, otherwise clamp to a huge finite value.
		if f > 1e300 {
			f = 1e300
		} else if f < -1e300 {
			f = -1e300
		}
	}
	return f, i
}

// ParseLength parses a length: a number optionally followed by "px", with
// optional surrounding whitespace. Only the leading number matters; ok is
// false when the value does not start with a number.
func ParseLength(s string) (v float64, ok bool) {
	s = strings.TrimLeft(s, " \t\r\n\f")
	v, n := ScanNumber(s)
	if n == 0 {
		return 0, false
	}
	return v, true
}

// ParseOpacity parses an opacity: a number or a percentage, clamped to
// [0, 1]. ok is false if the value is not of that form.
func ParseOpacity(s string) (v float64, ok bool) {
	s = strings.TrimSpace(s)
	v, n := ScanNumber(s)
	if n == 0 {
		return 0, false
	}
	rest := s[n:]
	switch rest {
	case "":
	case "%":
		v /= 100
	default:
		return 0, false
	}
	if v < 0 {
		v = 0
	} else if v > 1 {
		v = 1
	}
	return v, true
}

// ParseNumberList parses numbers separated by whitespace and/or commas. It
// stops at the first thing that is not a number.
func ParseNumberList(s string) []float64 {
	var out []float64
	i := 0
	for i < len(s) {
		for i < len(s) && (isSpace(s[i]) || s[i] == ',') {
			i++
		}
		if i >= len(s) {
			break
		}
		v, n := ScanNumber(s[i:])
		if n == 0 {
			break
		}
		out = append(out, v)
		i += n
	}
	return out
}

// ViewBox returns the user-space rectangle (x, y, w, h) described by a
// viewBox attribute value, and ok=false unless it holds at least four numbers
// with positive width and height.
func ViewBox(s string) (x, y, w, h float64, ok bool) {
	nums := ParseNumberList(s)
	if len(nums) < 4 || !(nums[2] > 0) || !(nums[3] > 0) {
		return 0, 0, 0, 0, false
	}
	return nums[0], nums[1], nums[2], nums[3], true
}

// ParseTransform parses a transform list into a single matrix. Unknown
// functions and functions with too few arguments are skipped; parsing stops
// at malformed syntax.
func ParseTransform(s string) geom.Matrix {
	m := geom.Identity
	i := 0
	for i < len(s) {
		for i < len(s) && (isSpace(s[i]) || s[i] == ',') {
			i++
		}
		start := i
		for i < len(s) && s[i] != '(' && !isSpace(s[i]) && s[i] != ',' && s[i] != ')' {
			i++
		}
		name := s[start:i]
		for i < len(s) && isSpace(s[i]) {
			i++
		}
		if i >= len(s) || s[i] != '(' || name == "" {
			break
		}
		close := strings.IndexByte(s[i:], ')')
		var args []float64
		if close < 0 {
			args = ParseNumberList(s[i+1:])
			i = len(s)
		} else {
			args = ParseNumberList(s[i+1 : i+close])
			i += close + 1
		}
		if f, ok := transformFunc(name, args); ok {
			m = m.Mul(f)
		}
	}
	return m
}

func transformFunc(name string, a []float64) (geom.Matrix, bool) {
	switch name {
	case "matrix":
		if len(a) >= 6 {
			return geom.Matrix{A: a[0], B: a[1], C: a[2], D: a[3], E: a[4], F: a[5]}, true
		}
	case "translate":
		if len(a) >= 2 {
			return geom.Translate(a[0], a[1]), true
		} else if len(a) == 1 {
			return geom.Translate(a[0], 0), true
		}
	case "scale":
		if len(a) >= 2 {
			return geom.ScaleM(a[0], a[1]), true
		} else if len(a) == 1 {
			return geom.ScaleM(a[0], a[0]), true
		}
	case "rotate":
		if len(a) >= 3 {
			return geom.Translate(a[1], a[2]).Mul(geom.Rotate(a[0])).Mul(geom.Translate(-a[1], -a[2])), true
		} else if len(a) >= 1 {
			return geom.Rotate(a[0]), true
		}
	case "skewX":
		if len(a) >= 1 {
			return geom.SkewX(a[0]), true
		}
	case "skewY":
		if len(a) >= 1 {
			return geom.SkewY(a[0]), true
		}
	}
	return geom.Identity, false
}
