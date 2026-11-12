package path

import (
	"svgraster/geom"
	"svgraster/svgparse"
)

// scanner tokenises path data.
type scanner struct {
	s string
	i int
}

func (sc *scanner) skipSep() {
	for sc.i < len(sc.s) {
		c := sc.s[sc.i]
		if c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' || c == ',' {
			sc.i++
		} else {
			break
		}
	}
}

func (sc *scanner) atEnd() bool {
	sc.skipSep()
	return sc.i >= len(sc.s)
}

// number reads a number token.
func (sc *scanner) number() (float64, bool) {
	sc.skipSep()
	v, n := svgparse.ScanNumber(sc.s[sc.i:])
	if n == 0 {
		return 0, false
	}
	sc.i += n
	return v, true
}

// flag reads a single-character arc flag, '0' or '1'.
func (sc *scanner) flag() (bool, bool) {
	sc.skipSep()
	if sc.i < len(sc.s) && (sc.s[sc.i] == '0' || sc.s[sc.i] == '1') {
		v := sc.s[sc.i] == '1'
		sc.i++
		return v, true
	}
	return false, false
}

// numbers reads exactly n numbers.
func (sc *scanner) numbers(buf []float64) bool {
	for k := range buf {
		v, ok := sc.number()
		if !ok {
			return false
		}
		buf[k] = v
	}
	return true
}

// Parse parses SVG path data. Parsing stops at the first token that is not
// what the grammar expects; the commands read up to that point are returned.
func Parse(d string) *Path {
	p := &Path{}
	sc := &scanner{s: d}

	var cur, start geom.Point
	var lastCubicCtl, lastQuadCtl geom.Point
	var prevCubic, prevQuad bool
	haveStart := false

	for !sc.atEnd() {
		cmd := sc.s[sc.i]
		if !isCommand(cmd) {
			return p
		}
		sc.i++
		rel := cmd >= 'a'
		up := cmd &^ 0x20
		if up == 'Z' {
			if haveStart {
				p.Close()
				cur = start
			}
			prevCubic, prevQuad = false, false
			continue
		}
		first := true
		for {
			if !first && sc.atEnd() {
				break
			}
			// A repeat requires another parameter group; a non-number ends
			// the command (and, if it is not a command letter, the parse).
			if !first {
				sc.skipSep()
				if sc.i >= len(sc.s) || isCommand(sc.s[sc.i]) {
					break
				}
			}
			if !haveStart && up != 'M' {
				return p // drawing before any moveto
			}
			var a [7]float64
			off := geom.Point{}
			if rel {
				off = cur
			}
			ok := true
			switch up {
			case 'M', 'L', 'T':
				ok = sc.numbers(a[:2])
			case 'H', 'V':
				ok = sc.numbers(a[:1])
			case 'C':
				ok = sc.numbers(a[:6])
			case 'S', 'Q':
				ok = sc.numbers(a[:4])
			case 'A':
				ok = sc.numbers(a[:3])
				if ok {
					var l, s bool
					if l, ok = sc.flag(); ok {
						if s, ok = sc.flag(); ok {
							if ok = sc.numbers(a[5:7]); ok {
								a[3], a[4] = b2f(l), b2f(s)
							}
						}
					}
				}
			}
			if !ok {
				return p
			}
			first = false
			pt := func(i int) geom.Point { return geom.Point{X: a[i] + off.X, Y: a[i+1] + off.Y} }
			switch up {
			case 'M':
				cur = pt(0)
				start = cur
				haveStart = true
				p.MoveTo(cur)
				prevCubic, prevQuad = false, false
				// Subsequent pairs are implicit lineto commands.
				up = 'L'
			case 'L':
				cur = pt(0)
				p.LineTo(cur)
				prevCubic, prevQuad = false, false
			case 'H':
				cur = geom.Point{X: a[0] + off.X, Y: cur.Y}
				p.LineTo(cur)
				prevCubic, prevQuad = false, false
			case 'V':
				cur = geom.Point{X: cur.X, Y: a[0] + off.Y}
				p.LineTo(cur)
				prevCubic, prevQuad = false, false
			case 'C':
				c1, c2, e := pt(0), pt(2), pt(4)
				p.CubicTo(c1, c2, e)
				lastCubicCtl, cur = c2, e
				prevCubic, prevQuad = true, false
			case 'S':
				c1 := cur
				if prevCubic {
					c1 = cur.Scale(2).Sub(lastCubicCtl)
				}
				c2, e := pt(0), pt(2)
				p.CubicTo(c1, c2, e)
				lastCubicCtl, cur = c2, e
				prevCubic, prevQuad = true, false
			case 'Q':
				q, e := pt(0), pt(2)
				p.quad(cur, q, e)
				lastQuadCtl, cur = q, e
				prevCubic, prevQuad = false, true
			case 'T':
				q := cur
				if prevQuad {
					q = cur.Scale(2).Sub(lastQuadCtl)
				}
				e := pt(0)
				p.quad(cur, q, e)
				lastQuadCtl, cur = q, e
				prevCubic, prevQuad = false, true
			case 'A':
				e := pt(5)
				p.ArcTo(cur, a[0], a[1], a[2], a[3] != 0, a[4] != 0, e)
				cur = e
				prevCubic, prevQuad = false, false
			}
		}
	}
	return p
}

func b2f(b bool) float64 {
	if b {
		return 1
	}
	return 0
}

func isCommand(c byte) bool {
	switch c | 0x20 {
	case 'm', 'l', 'h', 'v', 'c', 's', 'q', 't', 'a', 'z':
		return true
	}
	return false
}

// quad appends a quadratic Bézier as the equivalent cubic.
func (p *Path) quad(c, q, e geom.Point) {
	p.CubicTo(c.Add(q.Sub(c).Scale(2.0/3.0)), e.Add(q.Sub(e).Scale(2.0/3.0)), e)
}
