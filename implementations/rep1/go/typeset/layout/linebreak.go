package layout

import (
	"math"
	"math/big"
	"math/bits"
)

// Fitness classes.
const (
	fitTight = iota
	fitDecent
	fitLoose
	fitVeryLoose
)

// badness returns min(10000, (100*num^3) div den^3) for num, den > 0, with
// exact arithmetic.
func badness(num, den int64) int64 {
	if num >= 5*den {
		return 10000
	}
	if den < 1<<21 {
		hi, lo := bits.Mul64(uint64(num)*uint64(num), uint64(num))
		h2, l2 := bits.Mul64(lo, 100)
		h := hi*100 + h2
		d3 := uint64(den) * uint64(den) * uint64(den)
		q, _ := bits.Div64(h, l2, d3)
		if q > 10000 {
			return 10000
		}
		return int64(q)
	}
	n := big.NewInt(num)
	n.Mul(n, n).Mul(n, big.NewInt(num)).Mul(n, big.NewInt(100))
	d := big.NewInt(den)
	d.Mul(d, big.NewInt(den)).Mul(d, big.NewInt(den))
	n.Quo(n, d)
	if !n.IsInt64() || n.Int64() > 10000 {
		return 10000
	}
	return n.Int64()
}

// classify computes the badness and fitness class of a line of natural width
// w, stretch y, shrink z and the given measure. ok is false for unstretchable
// and overfull lines (which are given badness 10000 and the class the
// specification assigns them).
func classify(measure, w, y, z int64, inf bool) (bad int64, fit int, ok bool) {
	d := measure - w
	if d == 0 || d > 0 && inf {
		return 0, fitDecent, true
	}
	if d > 0 {
		if y == 0 {
			return 10000, fitVeryLoose, false
		}
		bad = badness(d, y)
		switch {
		case d > y:
			fit = fitVeryLoose
		case 2*d > y:
			fit = fitLoose
		default:
			fit = fitDecent
		}
		return bad, fit, true
	}
	e := -d
	if z == 0 || e > z {
		return 10000, fitTight, false
	}
	bad = badness(e, z)
	if 2*e > z {
		fit = fitTight
	} else {
		fit = fitDecent
	}
	return bad, fit, true
}

type node struct {
	bp    int32
	cls   int8
	flag  bool
	first bool
	prev  int32
	s     int32
	total int64
	sW    int64
	sY    int64
	sZ    int64
	sInf  int32
}

// Breaking is the result of breaking one horizontal list.
type Breaking struct {
	Breaks    []int32 // item index of the end of each line, in order
	Total     int64
	Emergency bool
}

// BreakList breaks a horizontal list into lines by total-fit.
func (e *Env) BreakList(hl *HList) Breaking {
	nodes, best := e.runPass(hl, false)
	emergency := false
	if best < 0 {
		nodes, best = e.runPass(hl, true)
		emergency = true
	}
	var rev []int32
	for n := best; n > 0; n = int(nodes[n].prev) {
		rev = append(rev, nodes[n].bp)
	}
	for i, j := 0, len(rev)-1; i < j; i, j = i+1, j-1 {
		rev[i], rev[j] = rev[j], rev[i]
	}
	return Breaking{Breaks: rev, Total: nodes[best].total, Emergency: emergency}
}

func (e *Env) runPass(hl *HList, pass2 bool) ([]node, int) {
	S := e.S
	first := node{bp: -1, cls: fitDecent, first: true, prev: -1}
	first.s = hl.start(-1)
	nodes := make([]node, 1, 4*len(hl.BPs)+4)
	nodes[0] = first
	active := make([]int32, 1, 64)
	active[0] = 0
	nbp := len(hl.BPs)
	measure := hl.Ctx.Measure
	indent := hl.Ctx.FirstIndent
	finalStart := 0
	for bi, b := range hl.BPs {
		final := bi == nbp-1
		it := &hl.Items[b]
		var p int64
		flagged := false
		var pre int64
		if it.Kind == IPenalty {
			p, flagged, pre = it.P, it.Flag, it.W
		}
		cw, cy, cz, ci := hl.cumW[b], hl.cumY[b], hl.cumZ[b], hl.cumInf[b]
		var bestTot [4]int64
		var bestPred [4]int32
		for c := range bestPred {
			bestPred[c] = -1
			bestTot[c] = math.MaxInt64
		}
		k := 0
		for _, ni := range active {
			n := &nodes[ni]
			var w, y, z int64
			inf := false
			if n.s < int32(b) {
				w, y, z = cw-n.sW, cy-n.sY, cz-n.sZ
				inf = ci-n.sInf > 0
			}
			L := measure
			if n.first {
				L -= indent
			}
			keep := true
			if !pass2 && w-z > L {
				keep = false
			}
			wp := w + pre
			bad, fit, ok := classify(L, wp, y, z, inf)
			if keep {
				active[k] = ni
				k++
			}
			if !pass2 && (!ok || bad > S.Tolerance) {
				continue
			}
			dem := (S.LinePenalty + bad) * (S.LinePenalty + bad)
			if p >= 0 && p < 10000 {
				dem += p * p
			} else if p > -10000 && p < 0 {
				dem -= p * p
			}
			if flagged && n.flag {
				dem += S.DoubleHyphenDemerits
			}
			if d := fit - int(n.cls); d > 1 || d < -1 {
				dem += S.AdjDemerits
			}
			if final && n.flag {
				dem += S.FinalHyphenDemerits
			}
			if t := n.total + dem; t < bestTot[fit] {
				bestTot[fit] = t
				bestPred[fit] = ni
			}
		}
		active = active[:k]
		if final {
			finalStart = len(nodes)
		}
		for c := 0; c < 4; c++ {
			if bestPred[c] < 0 {
				continue
			}
			nd := node{bp: b, cls: int8(c), flag: flagged, prev: bestPred[c], total: bestTot[c]}
			nd.s = hl.start(b)
			nd.sW, nd.sY, nd.sZ, nd.sInf = hl.cumW[nd.s], hl.cumY[nd.s], hl.cumZ[nd.s], hl.cumInf[nd.s]
			nodes = append(nodes, nd)
			active = append(active, int32(len(nodes)-1))
		}
		if !pass2 && len(active) == 0 && !final {
			return nodes, -1
		}
	}
	best := -1
	for i := finalStart; i < len(nodes) && finalStart > 0; i++ {
		if best < 0 || nodes[i].total < nodes[best].total {
			best = i
		}
	}
	return nodes, best
}
