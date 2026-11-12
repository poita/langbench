package engine

import "github.com/spiremark/cardgame/cards"

// derive recomputes the current characteristics of every Field object from
// the continuous-effect records (SPEC 14.3): controllers, stripping, aura
// records, then layers 2 to 6.
func (g *Game) derive() {
	g.dirty = false
	for _, o := range g.field {
		o.ctrl = o.baseCtrl
		o.stripped = false
	}
	// Layer 1.
	for _, r := range g.records {
		if r.kind != rControl {
			continue
		}
		for _, o := range r.affected {
			if o.zone == ZField {
				o.ctrl = r.ctrl
			}
		}
	}
	// Which objects are stripped.
	for _, r := range g.records {
		if r.kind != rStrip {
			continue
		}
		for _, o := range r.affected {
			if o.zone == ZField {
				o.stripped = true
			}
		}
	}
	// Aura records.
	for _, r := range g.records {
		if r.kind == rAura {
			g.evalAura(r)
		}
	}
	// Starting values.
	for _, o := range g.field {
		o.edge, o.core = o.Card.Edge, o.Card.Core
		o.kwMask, o.plating = 0, 0
		for _, k := range o.Card.Keywords {
			o.kwMask |= kwBit(k.K)
			if k.K == cards.Plating {
				o.plating += k.N
			}
		}
	}
	// Layer 2.
	g.eachLayerEffect(func(kind recKind, a, b int, kw cards.KW, objs []*Obj) {
		switch kind {
		case rGrant:
			for _, o := range objs {
				if o.zone == ZField {
					o.kwMask |= kwBit(kw.K)
					if kw.K == cards.Plating {
						o.plating += kw.N
					}
				}
			}
		case rStrip:
			for _, o := range objs {
				if o.zone == ZField {
					o.kwMask, o.plating = 0, 0
				}
			}
		}
	})
	// Layers 3, 4.
	g.eachLayerEffect(func(kind recKind, a, b int, kw cards.KW, objs []*Obj) {
		if kind == rSetbody {
			for _, o := range objs {
				if o.zone == ZField {
					o.edge, o.core = a, b
				}
			}
		}
	})
	g.eachLayerEffect(func(kind recKind, a, b int, kw cards.KW, objs []*Obj) {
		if kind == rModify {
			for _, o := range objs {
				if o.zone == ZField {
					o.edge += a
					o.core += b
				}
			}
		}
	})
	// Layer 5.
	for _, o := range g.field {
		o.edge += o.counters
		o.core += o.counters
	}
	// Layer 6.
	g.eachLayerEffect(func(kind recKind, a, b int, kw cards.KW, objs []*Obj) {
		if kind == rSwap {
			for _, o := range objs {
				if o.zone == ZField {
					o.edge, o.core = o.core, o.edge
				}
			}
		}
	})
}

// eachLayerEffect walks every active record's layer effects in
// (timestamp, eid) order, which is the order of g.records.
func (g *Game) eachLayerEffect(f func(kind recKind, a, b int, kw cards.KW, objs []*Obj)) {
	for _, r := range g.records {
		if r.kind != rAura {
			f(r.kind, r.a, r.b, r.kw, r.affected)
			continue
		}
		for i := range r.parts {
			p := &r.parts[i]
			if !p.active {
				continue
			}
			switch p.kind {
			case cards.StModify:
				f(rModify, p.a, p.b, p.kw, p.objs)
			case cards.StSetbody:
				f(rSetbody, p.a, p.b, p.kw, p.objs)
			case cards.StSwap:
				f(rSwap, p.a, p.b, p.kw, p.objs)
			case cards.StGrant:
				f(rGrant, p.a, p.b, p.kw, p.objs)
			}
		}
	}
}

// evalAura evaluates an aura record's statics against the current board
// using base characteristics.
func (g *Game) evalAura(r *record) {
	r.parts = r.parts[:0]
	src := r.src
	r.ctrl = src.ctrl
	c := &ctx{ctrl: src.ctrl, src: src, aura: true}
	live := src.zone == ZField && !src.stripped
	for _, st := range r.ab.Statics {
		g.flattenStatic(r, st, live, c)
	}
}

func (g *Game) flattenStatic(r *record, st *cards.Static, active bool, c *ctx) {
	if st.Kind == cards.StWhen {
		ok := g.cond(st.Cond, c)
		for _, sub := range st.Body {
			g.flattenStatic(r, sub, active && ok, c)
		}
		return
	}
	p := auraPart{kind: st.Kind, active: active}
	switch st.Kind {
	case cards.StModify, cards.StSetbody:
		p.a, p.b = g.amt(st.A1, c), g.amt(st.A2, c)
	case cards.StGrant:
		p.kw = st.KW
	case cards.StCheaper:
		p.n, p.cf = st.N, st.CardFilters
	}
	if active && st.Sel != nil {
		p.objs = g.objs(st.Sel, c)
	}
	r.parts = append(r.parts, p)
}

// printedCostAfterAuras computes the Ember cost player p pays for card c.
func (g *Game) playCost(p Player, c *cards.Card) int {
	g.ensure()
	cost := c.Cost
	for _, r := range g.records {
		if r.kind != rAura || r.ctrl != p {
			continue
		}
		for i := range r.parts {
			pt := &r.parts[i]
			if pt.kind != cards.StCheaper || !pt.active {
				continue
			}
			match := true
			for _, f := range pt.cf {
				switch f.Kind {
				case cards.FType:
					match = c.Type == f.Type
				case cards.FTag:
					match = c.HasTag(f.Tag)
				case cards.FCost:
					match = f.Cmp.Test(c.Cost, f.N)
				}
				if !match {
					break
				}
			}
			if match {
				cost -= pt.n
			}
		}
	}
	if cost < 0 {
		cost = 0
	}
	return cost
}
