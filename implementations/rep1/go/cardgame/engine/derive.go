package engine

import "cardgame/cards"

// derive recomputes the current characteristics of every Field object in one
// whole-board pass following SPEC 14.3. It does nothing unless the cached
// results are stale.
func (g *Game) derive() {
	if !g.stale {
		return
	}
	g.stale = false

	for _, id := range g.field {
		o := g.objs[id]
		o.CurCtrl = o.Ctrl
		o.Stripped = false
		o.Edge, o.Core = int(o.Card.Edge), int(o.Card.Core)
		o.KwMask = o.Card.KwMask
		o.Plating = 0
		for _, k := range o.Card.Keywords {
			if k.K == cards.Plating {
				o.Plating += k.N
			}
		}
	}

	// Layer 1: controllers.
	for _, r := range g.records {
		if r.Aura {
			continue
		}
		e := &r.Effs[0]
		if e.Kind == RControl {
			for _, id := range e.Affected {
				if g.objs[id].Zone == ZField {
					g.objs[id].CurCtrl = r.Ctrl
				}
			}
		}
	}
	// Stripped objects.
	for _, r := range g.records {
		if r.Aura {
			continue
		}
		if e := &r.Effs[0]; e.Kind == RStrip {
			for _, id := range e.Affected {
				if g.objs[id].Zone == ZField {
					g.objs[id].Stripped = true
				}
			}
		}
	}

	// Aura records: activity, arguments and affected lists.
	var deps cards.Dep
	c := ctx{aura: true}
	for _, r := range g.records {
		if !r.Aura {
			continue
		}
		src := g.objs[r.Source]
		r.Ctrl = src.CurCtrl
		c.ctrl, c.source = r.Ctrl, r.Source
		srcActive := !src.Stripped
		for i := range r.Effs {
			e := &r.Effs[i]
			leaf := e.leaf
			deps |= leaf.Deps
			active := srcActive
			for _, cd := range leaf.Conds {
				if !g.cond(cd, &c) {
					active = false
					break
				}
			}
			e.Active = active
			s := leaf.S
			switch e.Kind {
			case RModify, RSetbody:
				e.A, e.B = g.amount(&s.A, &c), g.amount(&s.B, &c)
			case RGrant:
				e.Kw = s.Kw
			case RCheaper:
				e.Cheaper, e.CardF = int(s.Cheaper), s.CardF
			}
			e.Affected = e.Affected[:0]
			if active && e.Kind != RCheaper {
				e.Affected = g.selObjs(s.Sel, &c, e.Affected)
			}
		}
	}
	g.liveDeps = deps

	// Layer 2: keywords.
	for _, r := range g.records {
		for i := range r.Effs {
			e := &r.Effs[i]
			if r.Aura && !e.Active {
				continue
			}
			switch e.Kind {
			case RGrant:
				for _, id := range e.Affected {
					o := g.objs[id]
					if o.Zone != ZField {
						continue
					}
					o.KwMask |= 1 << e.Kw.K
					if e.Kw.K == cards.Plating {
						o.Plating += e.Kw.N
					}
				}
			case RStrip:
				for _, id := range e.Affected {
					o := g.objs[id]
					if o.Zone == ZField {
						o.KwMask, o.Plating = 0, 0
					}
				}
			}
		}
	}
	// Layers 3 and 4.
	for layer := RSetbody; ; layer = RModify {
		for _, r := range g.records {
			for i := range r.Effs {
				e := &r.Effs[i]
				if e.Kind != layer || (r.Aura && !e.Active) {
					continue
				}
				for _, id := range e.Affected {
					o := g.objs[id]
					if o.Zone != ZField {
						continue
					}
					if layer == RSetbody {
						o.Edge, o.Core = e.A, e.B
					} else {
						o.Edge += e.A
						o.Core += e.B
					}
				}
			}
		}
		if layer == RModify {
			break
		}
	}
	// Layer 5: charge counters.
	for _, id := range g.field {
		o := g.objs[id]
		o.Edge += o.Counters
		o.Core += o.Counters
	}
	// Layer 6: swapstats.
	for _, r := range g.records {
		for i := range r.Effs {
			e := &r.Effs[i]
			if e.Kind != RSwap || (r.Aura && !e.Active) {
				continue
			}
			for _, id := range e.Affected {
				o := g.objs[id]
				if o.Zone == ZField {
					o.Edge, o.Core = o.Core, o.Edge
				}
			}
		}
	}
}
