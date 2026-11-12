// Package raster scan-converts polygons with anti-aliasing and composites
// the result into an RGBA canvas.
package raster

import (
	"math"
	"sort"

	"svgraster/geom"
)

// FillRule selects how polygon winding determines the inside.
type FillRule uint8

// Fill rules.
const (
	NonZero FillRule = iota
	EvenOdd
)

// SubScanlines is the number of equally spaced horizontal sub-scanlines
// sampled per pixel row. Coverage of a pixel is the mean, over the
// sub-scanlines, of the exact length of the region's span inside the pixel.
const SubScanlines = 64

// RowFunc receives the coverage (0..1) of pixels x0, x0+1, ... of row y.
// The slice is reused after the call returns.
type RowFunc func(y, x0 int, cov []float64)

type edge struct {
	x0, y0 float64 // upper end point
	dxdy   float64
	first  int // first sub-scanline sampled
	last   int // last sub-scanline sampled
	dir    int // +1 if the original edge pointed downwards
	x      float64
}

// Rasterizer converts polygons to per-pixel coverage. It owns scratch
// buffers, so one value should be reused for many fills of the same size; it
// is not safe for concurrent use.
type Rasterizer struct {
	w, h   int
	cov    []float64 // per-pixel partial coverage for the current row
	delta  []float64 // run-length deltas for fully covered stretches
	out    []float64
	minX   int
	maxX   int
	row    int
	edges  []edge
	active []*edge
}

// NewRasterizer returns a rasterizer for a w x h pixel grid.
func NewRasterizer(w, h int) *Rasterizer {
	return &Rasterizer{
		w: w, h: h,
		cov:   make([]float64, w+2),
		delta: make([]float64, w+2),
		out:   make([]float64, w+2),
		row:   -1,
	}
}

// Fill rasterises the polygons (each implicitly closed) under the given rule
// and calls fn once per pixel row that has non-zero coverage, from top to
// bottom. Cost is O(E log E) for the edges plus the work on the active
// edges of each sampled sub-scanline plus the width of the touched rows.
func (r *Rasterizer) Fill(polys [][]geom.Point, rule FillRule, fn RowFunc) {
	r.buildEdges(polys)
	if len(r.edges) == 0 {
		return
	}
	es := r.edges
	sort.Slice(es, func(i, j int) bool { return es[i].first < es[j].first })

	r.active = r.active[:0]
	r.row = -1
	next := 0
	s := es[0].first
	for next < len(es) || len(r.active) > 0 {
		if len(r.active) == 0 && es[next].first > s {
			s = es[next].first
		}
		row := s / SubScanlines
		if row != r.row {
			r.flush(fn)
			r.row = row
			r.minX, r.maxX = r.w+1, -1
		}
		for next < len(es) && es[next].first <= s {
			e := &es[next]
			next++
			r.active = append(r.active, e)
		}
		y := (float64(s) + 0.5) / SubScanlines
		act := r.active
		for _, e := range act {
			e.x = e.x0 + (y-e.y0)*e.dxdy
		}
		// Insertion sort: the order changes little between sub-scanlines.
		for i := 1; i < len(act); i++ {
			e := act[i]
			j := i - 1
			for j >= 0 && act[j].x > e.x {
				act[j+1] = act[j]
				j--
			}
			act[j+1] = e
		}
		r.spans(act, rule)
		// Drop edges that end at this sub-scanline.
		k := 0
		for _, e := range act {
			if e.last > s {
				act[k] = e
				k++
			}
		}
		r.active = act[:k]
		s++
	}
	r.flush(fn)
}

func (r *Rasterizer) buildEdges(polys [][]geom.Point) {
	r.edges = r.edges[:0]
	limit := float64(r.h * SubScanlines)
	for _, poly := range polys {
		n := len(poly)
		if n < 3 {
			continue
		}
		for i := 0; i < n; i++ {
			a, b := poly[i], poly[(i+1)%n]
			if !a.Finite() || !b.Finite() || a.Y == b.Y {
				continue
			}
			dir := 1
			if a.Y > b.Y {
				a, b = b, a
				dir = -1
			}
			f := math.Ceil(a.Y*SubScanlines - 0.5)
			l := math.Ceil(b.Y*SubScanlines-0.5) - 1
			if l < 0 || f >= limit || f > l {
				continue
			}
			if f < 0 {
				f = 0
			}
			if l >= limit {
				l = limit - 1
			}
			r.edges = append(r.edges, edge{
				x0: a.X, y0: a.Y, dxdy: (b.X - a.X) / (b.Y - a.Y),
				first: int(f), last: int(l), dir: dir,
			})
		}
	}
}

// spans converts the x-sorted active edges into spans and accumulates them.
func (r *Rasterizer) spans(act []*edge, rule FillRule) {
	wind := 0
	var startX float64
	for _, e := range act {
		was := wind != 0
		if rule == EvenOdd {
			wind ^= 1
		} else {
			wind += e.dir
		}
		now := wind != 0
		if !was && now {
			startX = e.x
		} else if was && !now {
			r.addSpan(startX, e.x)
		}
	}
}

func (r *Rasterizer) addSpan(x0, x1 float64) {
	w := float64(r.w)
	if x0 < 0 {
		x0 = 0
	}
	if x1 > w {
		x1 = w
	}
	if !(x1 > x0) {
		return
	}
	i0, i1 := int(x0), int(x1)
	if i0 == i1 {
		r.cov[i0] += x1 - x0
	} else {
		r.cov[i0] += float64(i0+1) - x0
		r.delta[i0+1]++
		r.cov[i1] += x1 - float64(i1)
		r.delta[i1]--
	}
	if i0 < r.minX {
		r.minX = i0
	}
	if i1 > r.maxX {
		r.maxX = i1
	}
}

// flush emits the finished row and clears the accumulators it touched.
func (r *Rasterizer) flush(fn RowFunc) {
	if r.row < 0 || r.maxX < 0 {
		return
	}
	hi := r.maxX
	if hi >= r.w {
		hi = r.w - 1
	}
	run := 0.0
	any := false
	for x := r.minX; x <= hi; x++ {
		run += r.delta[x]
		c := (r.cov[x] + run) / SubScanlines
		if c > 1 {
			c = 1
		} else if c < 0 {
			c = 0
		}
		r.out[x-r.minX] = c
		if c > 0 {
			any = true
		}
	}
	if any && hi >= r.minX {
		fn(r.row, r.minX, r.out[:hi-r.minX+1])
	}
	for x := r.minX; x <= r.maxX; x++ {
		r.cov[x] = 0
		r.delta[x] = 0
	}
	r.maxX = -1
}

// SignedArea returns the shoelace area of a polygon: positive when the
// vertices run clockwise on a y-down screen.
func SignedArea(poly []geom.Point) float64 {
	a := 0.0
	for i, p := range poly {
		q := poly[(i+1)%len(poly)]
		a += p.X*q.Y - q.X*p.Y
	}
	return a / 2
}

// Orient reverses, in place, every polygon whose signed area is negative, and
// drops polygons with no area, so that filling the result with NonZero yields
// the union of the polygons.
func Orient(polys [][]geom.Point) [][]geom.Point {
	out := polys[:0]
	for _, p := range polys {
		a := SignedArea(p)
		if a == 0 || math.IsNaN(a) {
			continue
		}
		if a < 0 {
			for i, j := 0, len(p)-1; i < j; i, j = i+1, j-1 {
				p[i], p[j] = p[j], p[i]
			}
		}
		out = append(out, p)
	}
	return out
}
