package raster

import (
	"math"
	"slices"

	"svgraster/geom"
)

// Rule is a fill rule.
type Rule uint8

const (
	// NonZero fills where the winding number is not zero.
	NonZero Rule = iota
	// EvenOdd fills where the winding number is odd.
	EvenOdd
)

// SubScanlines is the vertical sampling density: each pixel row is cut into
// this many horizontal sub-scanlines, intersected exactly.
const SubScanlines = 64

type edge struct {
	x0, y0, dxdy float64 // x at the top end, the top y, and dx/dy
	x            float64 // x at the current sub-scanline
	k0, k1       int32   // inclusive sub-scanline range crossed
	dir          int32   // +1 for edges running downwards, -1 upwards
}

// Rasterizer fills polygons onto canvases. It owns reusable scratch buffers;
// create one per goroutine and reuse it across fills.
type Rasterizer struct {
	edges  []edge
	active []edge
	cover  []float64 // fractional span length per pixel
	delta  []float64 // +1/-1 markers for runs of fully covered pixels
	xlo    int
	xhi    int
}

// NewRasterizer returns a Rasterizer for canvases up to width w.
func NewRasterizer(w int) *Rasterizer {
	r := &Rasterizer{}
	r.size(w)
	return r
}

func (r *Rasterizer) size(w int) {
	if len(r.cover) < w+2 {
		r.cover = make([]float64, w+2)
		r.delta = make([]float64, w+2)
	}
}

// Fill paints the region described by polys (each polygon implicitly closed,
// in canvas pixel coordinates) onto c using the given rule. The paint colour
// is (cr, cg, cb) with channels in [0,1] and opacity pa; the effective alpha
// of a pixel is pa times its exact-to-1/64 area coverage, composited
// source-over.
func (r *Rasterizer) Fill(c *Canvas, polys *geom.Polygons, rule Rule, cr, cg, cb, pa float64) {
	r.size(c.W)
	r.buildEdges(c, polys)
	if len(r.edges) == 0 {
		return
	}
	edges := r.edges
	act := r.active[:0]
	next := 0
	k := int(edges[0].k0)
	row := -1
	for next < len(edges) || len(act) > 0 {
		if len(act) == 0 && int(edges[next].k0) > k {
			k = int(edges[next].k0)
		}
		if kr := k / SubScanlines; kr != row {
			if row >= 0 {
				r.flush(c, row, cr, cg, cb, pa)
			}
			row = kr
			r.xlo, r.xhi = c.W+2, -1
		}
		for next < len(edges) && int(edges[next].k0) <= k {
			act = append(act, edges[next])
			next++
		}
		y := (float64(k) + 0.5) / SubScanlines
		for i := range act {
			act[i].x = act[i].x0 + (y-act[i].y0)*act[i].dxdy
		}
		// Insertion sort: order rarely changes between sub-scanlines.
		for i := 1; i < len(act); i++ {
			e := act[i]
			j := i
			for ; j > 0 && act[j-1].x > e.x; j-- {
				act[j] = act[j-1]
			}
			act[j] = e
		}
		wind := int32(0)
		start := 0.0
		inside := false
		for i := range act {
			wind += act[i].dir
			now := wind != 0
			if rule == EvenOdd {
				now = wind&1 != 0
			}
			if now && !inside {
				start = act[i].x
			} else if !now && inside {
				r.span(c.W, start, act[i].x)
			}
			inside = now
		}
		k++
		n := 0
		for i := range act {
			if int(act[i].k1) >= k {
				act[n] = act[i]
				n++
			}
		}
		act = act[:n]
	}
	r.flush(c, row, cr, cg, cb, pa)
	r.active = act[:0]
}

// buildEdges converts the polygons to edges sorted by first sub-scanline.
func (r *Rasterizer) buildEdges(c *Canvas, polys *geom.Polygons) {
	r.edges = r.edges[:0]
	maxK := float64(c.H*SubScanlines - 1)
	for pi := 0; pi < polys.Len(); pi++ {
		pts := polys.Poly(pi)
		for i := range pts {
			a := pts[i]
			b := pts[0]
			if i+1 < len(pts) {
				b = pts[i+1]
			}
			if a.Y == b.Y || !finite(a.X) || !finite(a.Y) || !finite(b.X) || !finite(b.Y) {
				continue
			}
			dir := int32(1)
			if a.Y > b.Y {
				a, b = b, a
				dir = -1
			}
			fk0 := math.Ceil(SubScanlines*a.Y - 0.5)
			fk1 := math.Ceil(SubScanlines*b.Y-0.5) - 1
			if fk0 < 0 {
				fk0 = 0
			}
			if fk1 > maxK {
				fk1 = maxK
			}
			if fk0 > fk1 {
				continue
			}
			r.edges = append(r.edges, edge{
				x0: a.X, y0: a.Y, dxdy: (b.X - a.X) / (b.Y - a.Y),
				k0: int32(fk0), k1: int32(fk1), dir: dir,
			})
		}
	}
	slices.SortFunc(r.edges, func(p, q edge) int { return int(p.k0) - int(q.k0) })
}

func finite(v float64) bool { return !math.IsNaN(v) && !math.IsInf(v, 0) }

// span adds the horizontal interval [x1, x2] (one sub-scanline) to the row
// accumulators, clipped to [0, w].
func (r *Rasterizer) span(w int, x1, x2 float64) {
	if x1 < 0 {
		x1 = 0
	}
	if x2 > float64(w) {
		x2 = float64(w)
	}
	if x2 <= x1 {
		return
	}
	ia, ib := int(x1), int(x2)
	if ia < r.xlo {
		r.xlo = ia
	}
	if ib > r.xhi {
		r.xhi = ib
	}
	if ia == ib {
		r.cover[ia] += x2 - x1
		return
	}
	r.cover[ia] += float64(ia+1) - x1
	r.cover[ib] += x2 - float64(ib)
	r.delta[ia+1]++
	r.delta[ib]--
}

// flush blends the accumulated row into the canvas and clears the touched
// part of the accumulators.
func (r *Rasterizer) flush(c *Canvas, row int, cr, cg, cb, pa float64) {
	if r.xhi < 0 {
		return
	}
	c.touch(row)
	base := 4 * c.W * row
	run := 0.0
	hi := r.xhi
	for x := r.xlo; x <= hi; x++ {
		run += r.delta[x]
		cov := (r.cover[x] + run) / SubScanlines
		if cov > 1 {
			cov = 1
		}
		if cov <= 0 || x >= c.W {
			continue
		}
		a := pa * cov
		k := 1 - a
		p := c.Pix[base+4*x : base+4*x+4 : base+4*x+4]
		p[0] = cr*a + p[0]*k
		p[1] = cg*a + p[1]*k
		p[2] = cb*a + p[2]*k
		p[3] = a + p[3]*k
	}
	clear(r.cover[r.xlo : hi+2])
	clear(r.delta[r.xlo : hi+2])
}
