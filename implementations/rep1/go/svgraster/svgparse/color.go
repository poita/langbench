package svgparse

import (
	"math"
	"strings"
)

// PaintKind distinguishes the three kinds of paint value.
type PaintKind uint8

const (
	// PaintNone means "paint nothing".
	PaintNone PaintKind = iota
	// PaintCurrent is the currentColor marker, resolved when painting.
	PaintCurrent
	// PaintRGB is a concrete colour.
	PaintRGB
)

// RGB is an 8-bit sRGB colour.
type RGB struct{ R, G, B uint8 }

// Paint is a parsed fill or stroke value.
type Paint struct {
	Kind PaintKind
	RGB  RGB // valid when Kind == PaintRGB
}

// ParseColor parses a paint value: none, currentColor, #rgb, #rrggbb,
// rgb(...) or a colour keyword. ok is false for anything else.
func ParseColor(s string) (p Paint, ok bool) {
	s = strings.TrimSpace(s)
	if s == "" {
		return Paint{}, false
	}
	if s[0] == '#' {
		c, ok := parseHex(s[1:])
		return Paint{PaintRGB, c}, ok
	}
	l := strings.ToLower(s)
	switch {
	case l == "none":
		return Paint{Kind: PaintNone}, true
	case l == "currentcolor":
		return Paint{Kind: PaintCurrent}, true
	case strings.HasPrefix(l, "rgb("):
		c, ok := parseRGBFunc(l[4:])
		return Paint{PaintRGB, c}, ok
	}
	if c, ok := namedColors[l]; ok {
		return Paint{PaintRGB, c}, true
	}
	return Paint{}, false
}

func hexVal(c byte) (uint8, bool) {
	switch {
	case c >= '0' && c <= '9':
		return c - '0', true
	case c >= 'a' && c <= 'f':
		return c - 'a' + 10, true
	case c >= 'A' && c <= 'F':
		return c - 'A' + 10, true
	}
	return 0, false
}

func parseHex(s string) (RGB, bool) {
	var d [6]uint8
	switch len(s) {
	case 3:
		for i := 0; i < 3; i++ {
			v, ok := hexVal(s[i])
			if !ok {
				return RGB{}, false
			}
			d[2*i], d[2*i+1] = v, v
		}
	case 6:
		for i := 0; i < 6; i++ {
			v, ok := hexVal(s[i])
			if !ok {
				return RGB{}, false
			}
			d[i] = v
		}
	default:
		return RGB{}, false
	}
	return RGB{d[0]<<4 | d[1], d[2]<<4 | d[3], d[4]<<4 | d[5]}, true
}

// parseRGBFunc parses the part of an rgb() value after "rgb(".
func parseRGBFunc(s string) (RGB, bool) {
	end := strings.IndexByte(s, ')')
	if end < 0 {
		return RGB{}, false
	}
	s = s[:end]
	var out [3]uint8
	i := 0
	for k := 0; k < 3; k++ {
		i = SkipSep(s, i)
		v, n, ok := ScanNumber(s, i)
		if !ok {
			return RGB{}, false
		}
		i = n
		if i < len(s) && s[i] == '%' {
			i++
			v = math.Min(100, math.Max(0, v)) * 255 / 100
		} else {
			v = math.Min(255, math.Max(0, v))
		}
		out[k] = uint8(math.Round(v))
	}
	return RGB{out[0], out[1], out[2]}, true
}
