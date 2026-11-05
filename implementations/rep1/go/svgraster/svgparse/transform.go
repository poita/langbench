package svgparse

import (
	"math"

	"svgraster/geom"
)

// Transform parses a transform list into one matrix. Unknown functions and
// functions with too few arguments are skipped; parsing stops at the first
// malformed token. Functions compose left to right.
func Transform(s string) geom.Matrix {
	m := geom.Identity
	i := 0
	for {
		i = SkipSep(s, i)
		start := i
		for i < len(s) && (s[i] >= 'a' && s[i] <= 'z' || s[i] >= 'A' && s[i] <= 'Z') {
			i++
		}
		name := s[start:i]
		for i < len(s) && IsSpace(s[i]) {
			i++
		}
		if name == "" || i >= len(s) || s[i] != '(' {
			return m
		}
		end := i + 1
		for end < len(s) && s[end] != ')' {
			end++
		}
		args := NumberList(s[i+1 : end])
		if end < len(s) {
			end++
		}
		i = end
		if f, ok := function(name, args); ok {
			m = m.Mul(f)
		}
	}
}

func function(name string, a []float64) (geom.Matrix, bool) {
	switch name {
	case "matrix":
		if len(a) >= 6 {
			return geom.Matrix{A: a[0], B: a[1], C: a[2], D: a[3], E: a[4], F: a[5]}, true
		}
	case "translate":
		if len(a) >= 2 {
			return geom.Translate(a[0], a[1]), true
		}
		if len(a) == 1 {
			return geom.Translate(a[0], 0), true
		}
	case "scale":
		if len(a) >= 2 {
			return geom.Scale(a[0], a[1]), true
		}
		if len(a) == 1 {
			return geom.Scale(a[0], a[0]), true
		}
	case "rotate":
		if len(a) >= 3 {
			return geom.Translate(a[1], a[2]).Mul(geom.Rotate(a[0])).Mul(geom.Translate(-a[1], -a[2])), true
		}
		if len(a) >= 1 {
			return geom.Rotate(a[0]), true
		}
	case "skewX":
		if len(a) >= 1 {
			return geom.Matrix{A: 1, D: 1, C: math.Tan(a[0] * math.Pi / 180)}, true
		}
	case "skewY":
		if len(a) >= 1 {
			return geom.Matrix{A: 1, D: 1, B: math.Tan(a[0] * math.Pi / 180)}, true
		}
	}
	return geom.Matrix{}, false
}
