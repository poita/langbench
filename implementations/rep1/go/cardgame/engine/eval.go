package engine

import (
	"sort"

	"github.com/spiremark/cardgame/cards"
)

// ctx is the evaluation context of an ability: who controls it, what its
// source is, and what its triggers and targets are bound to.
type ctx struct {
	ctrl    Player
	src     *Obj
	it      target
	that    *Obj
	targets []target
	specs   []cards.TargetSpec
	aura    bool // inside an aura derivation: edge/core amounts are base
}

func kwBit(k cards.Keyword) uint32 { return 1 << uint(k) }

// ensure re-derives characteristics when state changed since the last time.
func (g *Game) ensure() {
	if g.dirty {
		g.derive()
	}
}

func (g *Game) ctrlOf(o *Obj) Player {
	if o.zone != ZField {
		return o.lastCtrl
	}
	g.ensure()
	return o.ctrl
}

func (g *Game) edgeOf(o *Obj) int {
	if o.zone != ZField {
		return o.Card.Edge
	}
	g.ensure()
	return o.edge
}

func (g *Game) coreOf(o *Obj) int {
	if o.zone != ZField {
		return o.Card.Core
	}
	g.ensure()
	return o.core
}

func (g *Game) hasKW(o *Obj, k cards.Keyword) bool {
	if o.zone != ZField {
		return o.Card.HasPrinted(k)
	}
	g.ensure()
	return o.kwMask&kwBit(k) != 0
}

func (g *Game) strippedOf(o *Obj) bool {
	if o.zone != ZField {
		return false
	}
	g.ensure()
	return o.stripped
}

func (g *Game) settling(o *Obj) bool { return o.zone == ZField && o.since >= g.turn }

func (g *Game) isUnitOnField(o *Obj) bool {
	return o.zone == ZField && o.Card.Type == cards.Unit
}

// inCombat reports whether o is on the Field and attacking or blocking.
func (g *Game) inCombat(o *Obj) bool { return o.zone == ZField && (o.attacking || o.blocking) }

// ---------------------------------------------------------------- filters

func baseEdge(o *Obj) int { return o.Card.Edge + o.counters }
func baseCore(o *Obj) int { return o.Card.Core + o.counters }

func (g *Game) matchFilters(o *Obj, fs []cards.Filter, c *ctx) bool {
	for i := range fs {
		if !g.matchFilter(o, &fs[i], c) {
			return false
		}
	}
	return true
}

func (g *Game) matchFilter(o *Obj, f *cards.Filter, c *ctx) bool {
	switch f.Kind {
	case cards.FKw:
		return o.Card.HasPrinted(f.KW)
	case cards.FNoKw:
		return !o.Card.HasPrinted(f.KW)
	case cards.FTag:
		return o.Card.HasTag(f.Tag)
	case cards.FType:
		return o.Card.Type == f.Type
	case cards.FCost:
		return f.Cmp.Test(o.Card.Cost, f.N)
	case cards.FEdge:
		return f.Cmp.Test(baseEdge(o), f.N)
	case cards.FCore:
		return f.Cmp.Test(baseCore(o), f.N)
	case cards.FWounded:
		return o.zone == ZField && o.wounds > 0
	case cards.FReady:
		return o.zone == ZField && o.ready
	case cards.FExhausted:
		return o.zone == ZField && !o.ready
	case cards.FSettling:
		return g.settling(o)
	case cards.FAttacking:
		return o.zone == ZField && o.attacking
	case cards.FBlocking:
		return o.zone == ZField && o.blocking
	case cards.FMine:
		return g.sideOf(o) == c.ctrl
	case cards.FEnemy:
		return g.sideOf(o) != c.ctrl
	case cards.FOther:
		return o != c.src
	case cards.FNot:
		return !g.matchFilter(o, f.Not, c)
	}
	return false
}

// sideOf is the current controller for Field objects and the owner elsewhere.
func (g *Game) sideOf(o *Obj) Player {
	if o.zone == ZField {
		return g.ctrlOf(o)
	}
	return o.Owner
}

func scopeOK(sc cards.Scope, side, ctrl Player) bool {
	switch sc {
	case cards.Yours:
		return side == ctrl
	case cards.Theirs:
		return side != ctrl
	}
	return true
}

// ------------------------------------------------------------- selectors

func (g *Game) zoneList(p Player, z cards.CardZone) []*Obj {
	switch z {
	case cards.ZHand:
		return g.pl[p].hand
	case cards.ZAsh:
		return g.pl[p].ash
	case cards.ZVault:
		return g.pl[p].vault
	}
	return g.pl[p].rift
}

// fieldUnits lists matching Field objects of the given type in canonical order.
func (g *Game) fieldMatching(typ cards.Type, sel *cards.Selector, c *ctx) []*Obj {
	g.ensure()
	var out []*Obj
	for _, o := range g.field {
		if o.Card.Type != typ || !scopeOK(sel.Scope, o.ctrl, c.ctrl) {
			continue
		}
		if g.matchFilters(o, sel.Filters, c) {
			out = append(out, o)
		}
	}
	return out
}

// objs evaluates an object selector, in canonical order.
func (g *Game) objs(sel *cards.Selector, c *ctx) []*Obj {
	switch sel.Kind {
	case cards.SelSelf:
		if c.src == nil {
			return nil
		}
		return []*Obj{c.src}
	case cards.SelIt:
		if c.it.kind == tObj {
			return []*Obj{c.it.o}
		}
		return nil
	case cards.SelThat:
		if c.that == nil {
			return nil
		}
		return []*Obj{c.that}
	case cards.SelTarget:
		if sel.N <= len(c.targets) {
			t := c.targets[sel.N-1]
			if t.kind == tObj && !t.removed {
				return []*Obj{t.o}
			}
		}
		return nil
	case cards.SelUnits:
		return g.fieldMatching(cards.Unit, sel, c)
	case cards.SelRelics:
		return g.fieldMatching(cards.Relic, sel, c)
	case cards.SelRandomUnit:
		list := g.fieldMatching(cards.Unit, sel, c)
		if len(list) == 0 {
			return nil
		}
		return []*Obj{list[g.rng.Below(uint64(len(list)))]}
	case cards.SelCards:
		var out []*Obj
		for p := A; p <= B; p++ {
			if !scopeOK(sel.Scope, p, c.ctrl) {
				continue
			}
			for _, o := range g.zoneList(p, sel.Zone) {
				if g.matchFilters(o, sel.Filters, c) {
					out = append(out, o)
				}
			}
		}
		sortObjs(out)
		return out
	}
	return nil
}

// players evaluates a player selector.
func (g *Game) players(ps *cards.PlayerSel, c *ctx) []Player {
	switch ps.Kind {
	case cards.PYou:
		return []Player{c.ctrl}
	case cards.PFoe:
		return []Player{c.ctrl.Opp()}
	case cards.PBoth:
		return []Player{A, B}
	case cards.PTarget:
		if ps.N <= len(c.targets) {
			t := c.targets[ps.N-1]
			if t.kind == tPlayer && !t.removed {
				return []Player{t.p}
			}
		}
		return nil
	case cards.POwnerOf:
		if ps.Sel.Kind == cards.SelTarget && ps.Sel.N <= len(c.targets) {
			t := c.targets[ps.Sel.N-1]
			if t.kind == tPlayer {
				if t.removed {
					return nil
				}
				return []Player{t.p}
			}
		}
		var seen [2]bool
		for _, o := range g.objs(ps.Sel, c) {
			seen[o.Owner] = true
		}
		var out []Player
		for p := A; p <= B; p++ {
			if seen[p] {
				out = append(out, p)
			}
		}
		return out
	}
	return nil
}

// dselTargets evaluates a damage selector into targets in ascending key order.
func (g *Game) dselTargets(d *cards.DSel, c *ctx) []target {
	var out []target
	if d.Player != nil {
		for _, p := range g.players(d.Player, c) {
			out = append(out, playerTarget(p))
		}
	} else if d.Obj.Kind == cards.SelTarget {
		if d.Obj.N <= len(c.targets) {
			t := c.targets[d.Obj.N-1]
			if !t.removed && (t.kind == tPlayer || t.kind == tObj) {
				out = append(out, t)
			}
		}
	} else {
		for _, o := range g.objs(d.Obj, c) {
			out = append(out, objTarget(o))
		}
	}
	sort.SliceStable(out, func(i, j int) bool { return keyLess(out[i].key(), out[j].key()) })
	return out
}

// ---------------------------------------------------------------- amounts

func (g *Game) sumPlayers(ps *cards.PlayerSel, c *ctx, f func(Player) int) int {
	n := 0
	for _, p := range g.players(ps, c) {
		n += f(p)
	}
	return n
}

func (g *Game) amt(a *cards.Amount, c *ctx) int {
	switch a.Kind {
	case cards.AConst:
		return a.N
	case cards.ACount:
		return len(g.objs(a.Sel, c))
	case cards.AHand:
		return g.sumPlayers(a.PSel, c, func(p Player) int { return len(g.pl[p].hand) })
	case cards.AAsh:
		return g.sumPlayers(a.PSel, c, func(p Player) int { return len(g.pl[p].ash) })
	case cards.AVault:
		return g.sumPlayers(a.PSel, c, func(p Player) int { return len(g.pl[p].vault) })
	case cards.AEdge, cards.ACore:
		n := 0
		for _, o := range g.objs(a.Sel, c) {
			switch {
			case c.aura && a.Kind == cards.AEdge:
				n += baseEdge(o)
			case c.aura:
				n += baseCore(o)
			case a.Kind == cards.AEdge:
				n += g.edgeOf(o)
			default:
				n += g.coreOf(o)
			}
		}
		return n
	case cards.AWounds:
		n := 0
		for _, o := range g.objs(a.Sel, c) {
			n += o.wounds
		}
		return n
	}
	return 0
}

func (g *Game) cond(k *cards.Cond, c *ctx) bool {
	switch k.Kind {
	case cards.CCount:
		return k.Cmp.Test(len(g.objs(k.Sel, c)), k.N)
	case cards.CSpire:
		return k.Cmp.Test(g.sumPlayers(k.PSel, c, func(p Player) int { return g.pl[p].spire }), k.N)
	case cards.CHand:
		return k.Cmp.Test(g.sumPlayers(k.PSel, c, func(p Player) int { return len(g.pl[p].hand) }), k.N)
	case cards.CAsh:
		return k.Cmp.Test(g.sumPlayers(k.PSel, c, func(p Player) int { return len(g.pl[p].ash) }), k.N)
	case cards.CVault:
		return k.Cmp.Test(g.sumPlayers(k.PSel, c, func(p Player) int { return len(g.pl[p].vault) }), k.N)
	case cards.CEmber:
		return k.Cmp.Test(g.sumPlayers(k.PSel, c, func(p Player) int { return g.pl[p].ember }), k.N)
	case cards.CMyTurn:
		return g.active == c.ctrl
	case cards.CAnd:
		for _, s := range k.Subs {
			if !g.cond(s, c) {
				return false
			}
		}
		return true
	case cards.COr:
		for _, s := range k.Subs {
			if g.cond(s, c) {
				return true
			}
		}
		return false
	case cards.CNot:
		return !g.cond(k.Subs[0], c)
	}
	return false
}
