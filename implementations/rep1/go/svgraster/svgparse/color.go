package svgparse

import (
	"math"
	"strings"
)

// Color is an 8-bit sRGB colour.
type Color struct{ R, G, B uint8 }

// Paint is the result of parsing a fill or stroke value.
type Paint struct {
	// None is set for "none": nothing is painted.
	None bool
	// Current is set for "currentColor": use the element's colour property.
	Current bool
	// Color is the colour when neither None nor Current is set.
	Color Color
}

// ParsePaint parses a fill/stroke value. ok is false if it is not in the
// supported grammar (none, currentColor, #rgb, #rrggbb, rgb(...) or a colour
// keyword).
func ParsePaint(s string) (p Paint, ok bool) {
	s = strings.TrimSpace(s)
	switch strings.ToLower(s) {
	case "none":
		return Paint{None: true}, true
	case "currentcolor":
		return Paint{Current: true}, true
	}
	c, ok := ParseColor(s)
	return Paint{Color: c}, ok
}

// ParseColor parses a colour value (no "none" or "currentColor").
func ParseColor(s string) (Color, bool) {
	s = strings.TrimSpace(s)
	if s == "" {
		return Color{}, false
	}
	if s[0] == '#' {
		return parseHex(s[1:])
	}
	lower := strings.ToLower(s)
	if strings.HasPrefix(lower, "rgb(") && strings.HasSuffix(lower, ")") {
		return parseRGBFunc(lower[4 : len(lower)-1])
	}
	if c, ok := namedColors[lower]; ok {
		return Color{uint8(c >> 16), uint8(c >> 8), uint8(c)}, true
	}
	return Color{}, false
}

func hexVal(c byte) (int, bool) {
	switch {
	case c >= '0' && c <= '9':
		return int(c - '0'), true
	case c >= 'a' && c <= 'f':
		return int(c-'a') + 10, true
	case c >= 'A' && c <= 'F':
		return int(c-'A') + 10, true
	}
	return 0, false
}

func parseHex(h string) (Color, bool) {
	if len(h) != 3 && len(h) != 6 {
		return Color{}, false
	}
	var v [6]int
	for i := 0; i < len(h); i++ {
		d, ok := hexVal(h[i])
		if !ok {
			return Color{}, false
		}
		v[i] = d
	}
	if len(h) == 3 {
		return Color{uint8(v[0] * 17), uint8(v[1] * 17), uint8(v[2] * 17)}, true
	}
	return Color{uint8(v[0]<<4 | v[1]), uint8(v[2]<<4 | v[3]), uint8(v[4]<<4 | v[5])}, true
}

func parseRGBFunc(args string) (Color, bool) {
	var comp [3]uint8
	i := 0
	for k := 0; k < 3; k++ {
		for i < len(args) && (isSpace(args[i]) || args[i] == ',') {
			i++
		}
		v, n := ScanNumber(args[i:])
		if n == 0 {
			return Color{}, false
		}
		i += n
		if i < len(args) && args[i] == '%' {
			i++
			v = math.Min(100, math.Max(0, v)) * 255 / 100
		} else {
			v = math.Min(255, math.Max(0, v))
		}
		comp[k] = uint8(math.Round(v)) // halves away from zero
	}
	return Color{comp[0], comp[1], comp[2]}, true
}
