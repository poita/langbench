package engine

import (
	"github.com/spiremark/cardgame/cards"
)

// ------------------------------------------------------------ zone plumbing

func removeObj(list []*Obj, o *Obj) []*Obj {
	for i, x := range list {
		if x == o {
			copy(list[i:], list[i+1:])
			list[len(list)-1] = nil
			return list[:len(list)-1]
		}
	}
	return list
}

// detach removes o from whatever zone holds it.
func (g *Game) detach(o *Obj) {
	p := &g.pl[o.Owner]
	switch o.zone {
	case ZVault:
		if len(p.vault) > 0 && p.vault[0] == o {
			p.vault[0] = nil
			p.vault = p.vault[1:]
		} else {
			p.vault = removeObj(p.vault, o)
		}
	case ZHand:
		if len(p.hand) > 0 && p.hand[0] == o {
			p.hand[0] = nil
			p.hand = p.hand[1:]
		} else {
			p.hand = removeObj(p.hand, o)
		}
	case ZAsh:
		p.ash = removeObj(p.ash, o)
	case ZRift:
		p.rift = removeObj(p.rift, o)
	case ZField:
		g.field = removeObj(g.field, o)
	case ZChain:
		// The Chain entry owns the card; nothing to detach.
	}
	o.zone = ZNone
	g.touch()
}

func (g *Game) newObj(card *cards.Card, owner Player) *Obj {
	o := &Obj{OID: len(g.byOID), Card: card, Owner: owner, lastCtrl: owner}
	g.byOID = append(g.byOID, o)
	return o
}

func (g *Game) toHand(o *Obj) {
	o.zone = ZHand
	g.pl[o.Owner].hand = append(g.pl[o.Owner].hand, o)
	g.touch()
}

func (g *Game) toAsh(o *Obj) {
	o.zone = ZAsh
	g.pl[o.Owner].ash = append(g.pl[o.Owner].ash, o)
	g.touch()
}

func (g *Game) toRift(o *Obj) {
	o.zone = ZRift
	g.pl[o.Owner].rift = append(g.pl[o.Owner].rift, o)
	g.touch()
}

// ----------------------------------------------------------- entering Field

// place puts o on the Field (17.17 steps 1-3) without emitting or collecting.
func (g *Game) place(o *Obj, ctrl Player, since int) {
	o.zone = ZField
	o.baseCtrl = ctrl
	o.lastCtrl = ctrl
	o.ts = g.newTS()
	o.since = since
	o.ready, o.wounds, o.counters, o.ward, o.doomed = true, 0, 0, 0, false
	o.attacking, o.blocking, o.blocked, o.blockers, o.blocks = false, false, false, nil, nil
	o.tenUsed, o.once = false, nil
	g.field = append(g.field, o)
	for _, ab := range o.Card.Abilities {
		if ab.Kind == cards.AbAura {
			g.records = append(g.records, &record{
				eid: g.newEID(), ts: g.newTS(), ctrl: ctrl, src: o, kind: rAura, ab: ab,
			})
		}
	}
	g.touch()
}

// enterField is the full procedure of 17.17 for a card already detached.
func (g *Game) enterField(o *Obj, ctrl Player) {
	g.place(o, ctrl, g.turn)
	g.emit("ARRIVE", oidS(o), o.Card.ID)
	g.collectArrive(o)
}

// leaveField performs 17.3 step 4: the object stops being on the Field and
// the combat bookkeeping of 7.5 is kept consistent. The caller moves the
// object to its destination zone.
func (g *Game) leaveField(o *Obj) {
	g.ensure()
	o.lastCtrl = o.ctrl
	if o.blocking && o.blocks != nil {
		o.blocks.blockers = removeObj(o.blocks.blockers, o)
	}
	if o.attacking {
		for _, b := range o.blockers {
			b.blocking, b.blocks = false, nil
		}
	}
	g.field = removeObj(g.field, o)
	g.dropAuras(o)
	o.zone = ZNone
	o.ready, o.wounds, o.counters, o.ward, o.doomed = true, 0, 0, 0, false
	o.attacking, o.blocking, o.blocked, o.blockers, o.blocks = false, false, false, nil, nil
	o.tenUsed, o.once = false, nil
	g.touch()
}

func (g *Game) dropAuras(o *Obj) {
	out := g.records[:0]
	for _, r := range g.records {
		if r.kind == rAura && r.src == o {
			continue
		}
		out = append(out, r)
	}
	for i := len(out); i < len(g.records); i++ {
		g.records[i] = nil
	}
	g.records = out
}

// removeFromCombat implements the control-change part of 17.13.
func (g *Game) removeFromCombat(o *Obj) {
	if o.blocking && o.blocks != nil {
		o.blocks.blockers = removeObj(o.blocks.blockers, o)
	}
	if o.attacking {
		for _, b := range o.blockers {
			b.blocking, b.blocks = false, nil
		}
	}
	o.attacking, o.blocking, o.blockers, o.blocks = false, false, nil, nil
	g.touch()
}

// ------------------------------------------------------- destroy and friends

func (g *Game) destroy(o *Obj) {
	if o.zone != ZField {
		return
	}
	if g.hasKW(o, cards.Tenacity) && !o.tenUsed {
		o.tenUsed, o.wounds, o.doomed = true, 0, false
		g.touch()
		g.emit("TENACITY", oidS(o))
		return
	}
	g.die(o, "DESTROY")
}

func (g *Game) sacrifice(o *Obj) {
	if o.zone != ZField {
		return
	}
	g.die(o, "SACRIFICE")
}

func (g *Game) die(o *Obj, event string) {
	g.leaveField(o)
	ctrl := o.lastCtrl
	g.toAsh(o)
	g.emit(event, oidS(o), o.Card.ID)
	g.collectDeath(o, ctrl)
}

func (g *Game) exile(o *Obj) {
	from := o.zone
	if from == ZNone || from == ZChain {
		return
	}
	if from == ZField {
		g.leaveField(o)
	} else {
		g.detach(o)
	}
	g.toRift(o)
	g.emit("EXILE", oidS(o), o.Card.ID, from.String())
	if from == ZField {
		g.collectLeave(o)
	}
}

func (g *Game) bounce(o *Obj) {
	if o.zone != ZField {
		return
	}
	g.leaveField(o)
	g.toHand(o)
	g.emit("BOUNCE", oidS(o), o.Card.ID)
	g.collectLeave(o)
}

// ---------------------------------------------------------------- resources

func (g *Game) setLoss(p Player, reason string) {
	if g.loss[p] == "" {
		g.loss[p] = reason
	}
}

// drawOne makes p draw a card (17.7); false when the vault was empty.
func (g *Game) drawOne(p Player) bool {
	pl := &g.pl[p]
	if len(pl.vault) == 0 {
		g.emit("DRAW-EMPTY", p.String())
		g.setLoss(p, "vault")
		return false
	}
	o := pl.vault[0]
	g.detach(o)
	g.toHand(o)
	g.emit("DRAW", p.String(), oidS(o), o.Card.ID)
	if !g.noTriggers {
		g.collectDraw(p, o)
	}
	return true
}

func (g *Game) draw(p Player, n int) {
	for i := 0; i < n; i++ {
		if !g.drawOne(p) {
			return
		}
	}
}

func (g *Game) discardOne(p Player) {
	pl := &g.pl[p]
	if len(pl.hand) == 0 {
		return
	}
	o := pl.hand[0]
	g.detach(o)
	g.toAsh(o)
	g.emit("DISCARD", p.String(), oidS(o), o.Card.ID)
}

func (g *Game) millOne(p Player) {
	pl := &g.pl[p]
	if len(pl.vault) == 0 {
		return
	}
	o := pl.vault[0]
	g.detach(o)
	g.toAsh(o)
	g.emit("MILL", p.String(), oidS(o), o.Card.ID)
}

func (g *Game) changeSpire(p Player, delta int) {
	if delta == 0 {
		return
	}
	g.pl[p].spire += delta
	g.touch()
	g.emit("SPIRE", p.String(), signed(delta), itoa(g.pl[p].spire))
	if delta < 0 {
		g.collectSpireLoss(p)
	}
}

func (g *Game) gainEmber(p Player, n int) {
	if n <= 0 {
		return
	}
	g.pl[p].ember += n
	g.touch()
	g.emit("EMBERGAIN", p.String(), itoa(n), itoa(g.pl[p].ember))
}

func (g *Game) raiseCap(p Player, n int) {
	if n <= 0 {
		return
	}
	c := g.pl[p].cap + n
	if c > g.cfg.MaxCap {
		c = g.cfg.MaxCap
	}
	g.pl[p].cap = c
	g.emit("CAP", p.String(), itoa(n), itoa(c))
}

func (g *Game) addCounters(o *Obj, n int) {
	if o.zone != ZField {
		return
	}
	old := o.counters
	o.counters += n
	if o.counters < 0 {
		o.counters = 0
	}
	if o.counters != old {
		g.touch()
		g.emit("COUNTERS", oidS(o), signed(o.counters-old), itoa(o.counters))
	}
}

func (g *Game) setReady(o *Obj, ready bool) {
	if o.zone != ZField || o.ready == ready {
		return
	}
	o.ready = ready
	g.touch()
	if ready {
		g.emit("READY", oidS(o))
	} else {
		g.emit("EXHAUST", oidS(o))
	}
}

func (g *Game) doom(o *Obj) {
	if !g.isUnitOnField(o) {
		return
	}
	o.doomed = true
	g.emit("DOOM", oidS(o))
}

// -------------------------------------------------------------------- damage

// dealDamage implements 17.1 for a single source/target pair.
func (g *Game) dealDamage(src *Obj, t target, n int) {
	if n <= 0 {
		return
	}
	if t.kind == tObj {
		if t.o.zone != ZField || t.o.Card.Type != cards.Unit {
			return // relics have no wounds; other zones are skipped
		}
	}
	// Prevention (15.2).
	remaining := n
	if t.kind == tObj {
		remaining -= g.platingOf(t.o)
		if remaining < 0 {
			remaining = 0
		}
		u := min(t.o.ward, remaining)
		t.o.ward -= u
		remaining -= u
	} else {
		u := min(g.pl[t.p].shield, remaining)
		g.pl[t.p].shield -= u
		remaining -= u
	}
	if prevented := n - remaining; prevented > 0 {
		g.emit("PREVENT", t.render(), itoa(prevented))
	}
	if remaining == 0 {
		return
	}
	m := remaining
	g.emit("DAMAGE", oidS(src), t.render(), itoa(m))
	if t.kind == tObj {
		t.o.wounds += m
		g.touch()
	} else {
		g.changeSpire(t.p, -m)
	}
	srcUnit := src.zone == ZField && src.Card.Type == cards.Unit
	if t.kind == tObj && srcUnit && g.hasKW(src, cards.Venom) {
		g.doom(t.o)
	}
	if srcUnit && g.hasKW(src, cards.Siphon) {
		g.changeSpire(g.ctrlOf(src), m)
	}
	g.collectDamage(src, t)
}

func (g *Game) platingOf(o *Obj) int {
	g.ensure()
	return o.plating
}

// ------------------------------------------------------------------- records

func (g *Game) addRecord(kind recKind, ctrl Player, src *Obj, a, b int, kw cards.KW, affected []*Obj) *record {
	var onField []*Obj
	for _, o := range affected {
		if o.zone == ZField {
			onField = append(onField, o)
		}
	}
	sortObjs(onField)
	r := &record{eid: g.newEID(), ts: g.newTS(), ctrl: ctrl, src: src, kind: kind, a: a, b: b, kw: kw, affected: onField}
	g.records = append(g.records, r)
	g.touch()
	return r
}
