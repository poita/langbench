// Package linebreak implements total-fit (Knuth–Plass) line breaking over an
// hlist.List, with exact integer arithmetic.
package linebreak

import (
	"math/big"
	"math/bits"

	"typeset/hlist"
)

// Params are the line-breaking settings.
type Params struct {
	Tolerance            int64
	LinePenalty          int64
	AdjDemerits          int64
	DoubleHyphenDemerits int64
	FinalHyphenDemerits  int64
}

// Result is a chosen breaking.
type Result struct {
	Breaks    []int // breakpoint item indices, the final breakpoint last
	Total     int64 // total demerits of the chosen breaking
	Emergency bool  // pass 1 failed and pass 2 was needed
}

// Fitness classes.
const (
	tight = iota
	decent
	loose
	veryLoose
)

type lineKind uint8

const (
	kindOK lineKind = iota
	kindUnstretchable
	kindOverfull
)

type node struct {
	brk   int
	class int8
	total int64
	prev  int32
}

// badnessRatio computes min(10000, (100 * d^3) div y^3) exactly, d, y > 0.
func badnessRatio(d, y int64) int64 {
	if d > 5*y {
		return 10000
	}
	if d < 1<<21 && y < 1<<21 {
		d3 := uint64(d) * uint64(d) * uint64(d)
		y3 := uint64(y) * uint64(y) * uint64(y)
		hi, lo := bits.Mul64(d3, 100)
		if hi >= y3 {
			return 10000
		}
		q, _ := bits.Div64(hi, lo, y3)
		if q > 10000 {
			return 10000
		}
		return int64(q)
	}
	n := new(big.Int).Exp(big.NewInt(d), big.NewInt(3), nil)
	n.Mul(n, big.NewInt(100))
	m := new(big.Int).Exp(big.NewInt(y), big.NewInt(3), nil)
	n.Div(n, m)
	if !n.IsInt64() || n.Int64() > 10000 {
		return 10000
	}
	return n.Int64()
}

// classify returns a line's badness, fitness class and kind.
func classify(m hlist.LineMeasure, L int64) (int64, int, lineKind) {
	d := L - m.W
	if d >= 0 && m.Inf {
		return 0, decent, kindOK
	}
	switch {
	case d == 0:
		return 0, decent, kindOK
	case d > 0:
		if m.Y == 0 {
			return 10000, veryLoose, kindUnstretchable
		}
		b := badnessRatio(d, m.Y)
		switch {
		case d > m.Y:
			return b, veryLoose, kindOK
		case 2*d > m.Y:
			return b, loose, kindOK
		}
		return b, decent, kindOK
	}
	e := -d
	if m.Z == 0 || e > m.Z {
		return 10000, tight, kindOverfull
	}
	b := badnessRatio(e, m.Z)
	if 2*e > m.Z {
		return b, tight, kindOK
	}
	return b, decent, kindOK
}

// Break breaks the list into lines of the given measure; the first line is
// shortened by firstIndent.
func Break(l *hlist.List, measure, firstIndent int64, p Params) Result {
	bps := l.Breakpoints()
	if r, ok := run(l, bps, measure, firstIndent, p, false); ok {
		return r
	}
	r, _ := run(l, bps, measure, firstIndent, p, true)
	r.Emergency = true
	return r
}

func run(l *hlist.List, bps []int, measure, firstIndent int64, p Params, pass2 bool) (Result, bool) {
	final := l.Final()
	nodes := []node{{brk: 0, class: decent, total: 0, prev: -1}}
	var active []int32
	if !pass2 {
		active = append(active, 0)
	}
	type cand struct {
		total int64
		prev  int32
		ok    bool
	}
	flagged := func(b int) bool { _, f := l.Penalty(b); return f }
	for _, b := range bps[1:] {
		pen, flag := l.Penalty(b)
		isFinal := b == final
		var best [4]cand
		consider := func(ni int32) bool {
			n := &nodes[ni]
			L := measure
			if n.brk == 0 {
				L -= firstIndent
			}
			m := l.Line(n.brk, b)
			if !pass2 && m.W0-m.Z > L {
				return false // overfull for good
			}
			bad, fit, kind := classify(m, L)
			if !pass2 && (kind != kindOK || bad > p.Tolerance) {
				return true
			}
			dem := (p.LinePenalty + bad) * (p.LinePenalty + bad)
			if pen >= 0 && pen < 10000 {
				dem += pen * pen
			} else if pen > -10000 && pen < 0 {
				dem -= pen * pen
			}
			flag0 := n.brk != 0 && flagged(n.brk)
			if flag && flag0 {
				dem += p.DoubleHyphenDemerits
			}
			if d := fit - int(n.class); d > 1 || d < -1 {
				dem += p.AdjDemerits
			}
			if isFinal && flag0 {
				dem += p.FinalHyphenDemerits
			}
			total := n.total + dem
			c := &best[fit]
			if !c.ok || total < c.total {
				*c = cand{total, ni, true}
			}
			return true
		}
		if pass2 {
			for ni := range nodes {
				consider(int32(ni))
			}
		} else {
			keep := active[:0]
			for _, ni := range active {
				if consider(ni) {
					keep = append(keep, ni)
				}
			}
			active = keep
		}
		first := len(nodes)
		for c := 0; c < 4; c++ {
			if best[c].ok {
				nodes = append(nodes, node{brk: b, class: int8(c), total: best[c].total, prev: best[c].prev})
				if !pass2 {
					active = append(active, int32(len(nodes)-1))
				}
			}
		}
		if isFinal {
			if len(nodes) == first {
				return Result{}, false
			}
			ch := first
			for i := first + 1; i < len(nodes); i++ {
				if nodes[i].total < nodes[ch].total {
					ch = i
				}
			}
			var rev []int
			for i := int32(ch); i > 0; i = nodes[i].prev {
				rev = append(rev, nodes[i].brk)
			}
			for i, j := 0, len(rev)-1; i < j; i, j = i+1, j-1 {
				rev[i], rev[j] = rev[j], rev[i]
			}
			return Result{Breaks: rev, Total: nodes[ch].total}, true
		}
		if !pass2 && len(active) == 0 {
			return Result{}, false
		}
	}
	return Result{}, false
}
