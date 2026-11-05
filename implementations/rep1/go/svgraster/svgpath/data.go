package svgpath

import (
	"svgraster/geom"
	"svgraster/svgparse"
)

// paramCount is the number of numeric parameters of each (upper-cased)
// command.
var paramCount = map[byte]int{
	'M': 2, 'L': 2, 'H': 1, 'V': 1, 'C': 6, 'S': 4, 'Q': 4, 'T': 2, 'A': 7,
}

// ParseData parses SVG path data. Parsing stops at the first token that is
// not the expected kind; everything parsed before that point is kept.
func ParseData(d string) *Path {
	p := &Path{}
	var (
		i       int
		cmd     byte // current command letter, as written
		prev    byte // previous command, upper case ('Z' for close)
		lastC   geom.Point
		lastQ   geom.Point
		started bool
	)
	for {
		i = svgparse.SkipSep(d, i)
		if i >= len(d) {
			break
		}
		c := d[i]
		if isLetter(c) {
			up := c &^ 0x20
			if up != 'Z' && paramCount[up] == 0 {
				break
			}
			if !started && up != 'M' {
				break
			}
			started = true
			i++
			cmd = c
			if up == 'Z' {
				p.Close()
				prev = 'Z'
				continue
			}
		} else if cmd == 0 || cmd == 'z' || cmd == 'Z' {
			break
		}
		// Parse one parameter group for cmd.
		up := cmd &^ 0x20
		rel := cmd >= 'a'
		var a [7]float64
		var flags [2]bool
		n := paramCount[up]
		ok := true
		for k := 0; k < n && ok; k++ {
			i = svgparse.SkipSep(d, i)
			if up == 'A' && (k == 3 || k == 4) {
				if i < len(d) && (d[i] == '0' || d[i] == '1') {
					flags[k-3] = d[i] == '1'
					i++
				} else {
					ok = false
				}
				continue
			}
			v, nx, good := svgparse.ScanNumber(d, i)
			if !good {
				ok = false
				break
			}
			a[k], i = v, nx
		}
		if !ok {
			break
		}
		cur := p.Current()
		off := geom.Point{}
		if rel {
			off = cur
		}
		pt := func(k int) geom.Point { return geom.Point{X: a[k] + off.X, Y: a[k+1] + off.Y} }
		switch up {
		case 'M':
			p.MoveTo(pt(0))
			// Further groups are implicit line-tos.
			if rel {
				cmd = 'l'
			} else {
				cmd = 'L'
			}
		case 'L':
			p.LineTo(pt(0))
		case 'H':
			p.LineTo(geom.Point{X: a[0] + off.X, Y: cur.Y})
		case 'V':
			p.LineTo(geom.Point{X: cur.X, Y: a[0] + off.Y})
		case 'C':
			p.CubicTo(pt(0), pt(2), pt(4))
			lastC = pt(2)
		case 'S':
			c1 := cur
			if prev == 'C' || prev == 'S' {
				c1 = cur.Scale(2).Sub(lastC)
			}
			p.CubicTo(c1, pt(0), pt(2))
			lastC = pt(0)
		case 'Q':
			p.QuadTo(pt(0), pt(2))
			lastQ = pt(0)
		case 'T':
			q := cur
			if prev == 'Q' || prev == 'T' {
				q = cur.Scale(2).Sub(lastQ)
			}
			p.QuadTo(q, pt(0))
			lastQ = q
		case 'A':
			p.ArcTo(a[0], a[1], a[2], flags[0], flags[1], a[5]+off.X, a[6]+off.Y)
		}
		prev = up
	}
	return p
}

func isLetter(c byte) bool { return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' }
