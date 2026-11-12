package engine

import (
	"sort"

	"github.com/spiremark/cardgame/cards"
)

// unitTargetable applies the filters and the spectral rule to a unit.
func (g *Game) unitTargetable(o *Obj, fs []cards.Filter, c *ctx) bool {
	if o.zone != ZField || o.Card.Type != cards.Unit {
		return false
	}
	if !g.matchFilters(o, fs, c) {
		return false
	}
	return !(g.hasKW(o, cards.Spectral) && g.ctrlOf(o) != c.ctrl)
}

// targetLegal checks one target against its specification (SPEC 12). exclude
// is the Chain entry being announced or resolved.
func (g *Game) targetLegal(spec *cards.TargetSpec, t target, c *ctx, exclude *entry) bool {
	switch spec.Kind {
	case cards.TSUnit:
		return t.kind == tObj && g.unitTargetable(t.o, spec.Filters, c)
	case cards.TSRelic:
		return t.kind == tObj && t.o.zone == ZField && t.o.Card.Type == cards.Relic &&
			g.matchFilters(t.o, spec.Filters, c)
	case cards.TSAny:
		return t.kind == tPlayer || (t.kind == tObj && g.unitTargetable(t.o, spec.Filters, c))
	case cards.TSPlayer:
		return t.kind == tPlayer
	case cards.TSChained:
		return t.kind == tEntry && t.e.onChain && t.e != exclude
	case cards.TSAshcard:
		return t.kind == tObj && t.o.zone == ZAsh && g.matchFilters(t.o, spec.Filters, c)
	}
	return false
}

// candidates lists every legal target for spec in ascending key order.
func (g *Game) candidates(spec *cards.TargetSpec, c *ctx, exclude *entry) []target {
	var out []target
	addObjs := func(list []*Obj) {
		for _, o := range list {
			t := objTarget(o)
			if g.targetLegal(spec, t, c, exclude) {
				out = append(out, t)
			}
		}
	}
	g.ensure()
	switch spec.Kind {
	case cards.TSUnit, cards.TSRelic:
		addObjs(g.field)
	case cards.TSAny:
		out = append(out, playerTarget(A), playerTarget(B))
		addObjs(g.field)
	case cards.TSPlayer:
		out = append(out, playerTarget(A), playerTarget(B))
	case cards.TSChained:
		for _, e := range g.chain {
			t := target{kind: tEntry, e: e}
			if g.targetLegal(spec, t, c, exclude) {
				out = append(out, t)
			}
		}
		sort.SliceStable(out, func(i, j int) bool { return keyLess(out[i].key(), out[j].key()) })
	case cards.TSAshcard:
		var list []*Obj
		list = append(list, g.pl[A].ash...)
		list = append(list, g.pl[B].ash...)
		sortObjs(list)
		addObjs(list)
	}
	return out
}

// autoTargets chooses targets by rule (13.4): the smallest-key legal
// candidate distinct from those already chosen, for each spec in order.
func (g *Game) autoTargets(specs []cards.TargetSpec, c *ctx, exclude *entry) ([]target, bool) {
	var chosen []target
	for i := range specs {
		found := false
		for _, cand := range g.candidates(&specs[i], c, exclude) {
			dup := false
			for _, ch := range chosen {
				if ch.same(cand) {
					dup = true
					break
				}
			}
			if !dup {
				chosen = append(chosen, cand)
				found = true
				break
			}
		}
		if !found {
			return nil, false
		}
	}
	return chosen, true
}

// targetTuples enumerates every legal tuple of distinct targets for specs, in
// ascending lexicographic key order.
func (g *Game) targetTuples(specs []cards.TargetSpec, c *ctx, exclude *entry) [][]target {
	if len(specs) == 0 {
		return [][]target{nil}
	}
	cands := make([][]target, len(specs))
	for i := range specs {
		cands[i] = g.candidates(&specs[i], c, exclude)
		if len(cands[i]) == 0 {
			return nil
		}
	}
	var out [][]target
	cur := make([]target, len(specs))
	var rec func(i int)
	rec = func(i int) {
		if i == len(specs) {
			out = append(out, append([]target(nil), cur...))
			return
		}
		for _, t := range cands[i] {
			dup := false
			for j := 0; j < i; j++ {
				if cur[j].same(t) {
					dup = true
					break
				}
			}
			if dup {
				continue
			}
			cur[i] = t
			rec(i + 1)
		}
	}
	rec(0)
	return out
}
