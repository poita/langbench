package engine

import (
	"sort"

	"cardgame/cards"
)

// addPending records a collected trigger.
func (g *Game) addPending(src, idx int, ctrl Player, subj Subject) {
	if g.noTriggers {
		return
	}
	g.pending = append(g.pending, Pending{Ctrl: ctrl, Source: src, TS: g.objs[src].TS, Index: idx, Subj: subj})
}

// collectFrom collects the `ev` abilities of one object. When checkStrip is
// set the object must be on the Field and not stripped (SPEC 13.1).
func (g *Game) collectFrom(oid int, ev cards.Event, ctrl Player, subj Subject, checkStrip bool) {
	o := g.objs[oid]
	list := o.Card.ByEvent[ev]
	if len(list) == 0 {
		return
	}
	if checkStrip {
		g.derive()
		if o.Zone != ZField || o.Stripped {
			return
		}
	}
	for _, idx := range list {
		g.addPending(oid, idx, ctrl, subj)
	}
}

// collectSelf collects abilities of a Field object under its current
// controller.
func (g *Game) collectSelf(oid int, ev cards.Event, subj Subject, checkStrip bool) {
	if len(g.objs[oid].Card.ByEvent[ev]) == 0 {
		return
	}
	g.collectFrom(oid, ev, g.ctrlOf(oid), subj, checkStrip)
}

// collectControlled collects `ev` from every Field object controlled by p.
func (g *Game) collectControlled(ev cards.Event, p Player, subj Subject) {
	g.derive()
	for _, id := range g.field {
		if g.objs[id].CurCtrl == p {
			g.collectFrom(id, ev, p, subj, true)
		}
	}
}

// collectAll collects `ev` from every Field object.
func (g *Game) collectAll(ev cards.Event, subj Subject) {
	g.derive()
	for _, id := range g.field {
		g.collectFrom(id, ev, g.objs[id].CurCtrl, subj, true)
	}
}

func (g *Game) collectSpireLoss(p Player) {
	subj := Subject{SubjPlayer, int(p)}
	g.derive()
	for _, id := range g.field {
		c := g.objs[id].CurCtrl
		if c == p {
			g.collectFrom(id, cards.EvSpireLoss, c, subj, true)
		} else {
			g.collectFrom(id, cards.EvEnemySpireLoss, c, subj, true)
		}
	}
}

// collectArrive collects the triggers of an object that has just entered
// the Field.
func (g *Game) collectArrive(oid int) {
	subj := Subject{SubjObj, oid}
	g.collectSelf(oid, cards.EvArrive, subj, true)
	if !g.isUnit(oid) {
		return
	}
	g.derive()
	mine := g.objs[oid].CurCtrl
	for _, id := range g.field {
		if id == oid {
			continue
		}
		c := g.objs[id].CurCtrl
		if c == mine {
			g.collectFrom(id, cards.EvAllyArrive, c, subj, true)
		} else {
			g.collectFrom(id, cards.EvEnemyArrive, c, subj, true)
		}
	}
}

// collectLeave collects `leave` from an object that has left the Field.
func (g *Game) collectLeave(oid int, ctrl Player) {
	g.collectFrom(oid, cards.EvLeave, ctrl, Subject{SubjObj, oid}, false)
}

// collectDeath collects the triggers of an object destroyed or sacrificed.
func (g *Game) collectDeath(oid int, ctrl Player, wasUnit bool) {
	subj := Subject{SubjObj, oid}
	g.collectFrom(oid, cards.EvDies, ctrl, subj, false)
	g.collectFrom(oid, cards.EvLeave, ctrl, subj, false)
	if !wasUnit {
		return
	}
	g.derive()
	for _, id := range g.field {
		c := g.objs[id].CurCtrl
		if c == ctrl {
			g.collectFrom(id, cards.EvAllyDies, c, subj, true)
		} else {
			g.collectFrom(id, cards.EvEnemyDies, c, subj, true)
		}
	}
}

// collectDelayed collects every delayed trigger with the given timing for
// which want returns true, and discards them from the pending-delayed list.
func (g *Game) collectDelayed(when cards.When, want func(*Delayed) bool) {
	k := 0
	for _, d := range g.delayed {
		if d.When == when && want(d) {
			if !g.noTriggers {
				g.pending = append(g.pending, Pending{Ctrl: d.Ctrl, Source: d.Source, TS: d.TS, Delayed: d})
			}
			continue
		}
		g.delayed[k] = d
		k++
	}
	for i := k; i < len(g.delayed); i++ {
		g.delayed[i] = nil
	}
	g.delayed = g.delayed[:k]
}

// pushTriggers implements SPEC 13.3: sort the batch, choose targets, emit
// TRIGGER lines and put the surviving entries on the Chain so that the first
// in trigger order resolves first. It reports whether the batch was
// non-empty.
func (g *Game) pushTriggers() bool {
	if len(g.pending) == 0 {
		return false
	}
	batch := g.pending
	g.pending = nil
	active := g.active
	key := func(p *Pending) (int, int, int, int) {
		b := 1
		if p.Ctrl == active {
			b = 0
		}
		return b, p.TS, p.Source, p.Index
	}
	sort.SliceStable(batch, func(i, j int) bool {
		a1, a2, a3, a4 := key(&batch[i])
		b1, b2, b3, b4 := key(&batch[j])
		switch {
		case a1 != b1:
			return a1 < b1
		case a2 != b2:
			return a2 < b2
		case a3 != b3:
			return a3 < b3
		}
		return a4 < b4
	})
	var entries []*Entry
	for i := range batch {
		p := &batch[i]
		en := &Entry{Kind: EKTrigger, Ctrl: p.Ctrl, Source: p.Source, Index: p.Index, Subj: p.Subj, Delayed: p.Delayed}
		if p.Delayed != nil {
			en.Targets = append([]Target(nil), p.Delayed.Targets...)
			en.Specs = p.Delayed.Specs
		} else {
			ab := g.objs[p.Source].Card.Abilities[p.Index-1]
			en.Specs = ab.Targets
			if len(ab.Targets) > 0 {
				ts, ok := g.autoTargets(ab.Targets, p.Ctrl, p.Source)
				if !ok {
					g.out.begin("TRIGGER-NO-TARGET")
					g.out.player(p.Ctrl).obj(p.Source).num(p.Index).end()
					continue
				}
				en.Targets = ts
			}
		}
		en.Cid = g.nextCid
		g.nextCid++
		g.out.begin("TRIGGER")
		g.out.player(en.Ctrl).cid(en.Cid).obj(en.Source).num(en.Index)
		for _, t := range en.Targets {
			g.out.target(t)
		}
		g.out.end()
		entries = append(entries, en)
	}
	for i := len(entries) - 1; i >= 0; i-- {
		g.chain = append(g.chain, entries[i])
	}
	return true
}

// settle implements SPEC 10.5. It reports whether anything happened.
func (g *Game) settle() bool {
	acted := false
	for {
		a := g.stateChecks()
		if g.over {
			return acted || a
		}
		b := g.pushTriggers()
		acted = acted || a || b
		if !a && !b {
			return acted
		}
	}
}

// stateChecks implements SPEC 18. It reports whether the destruction check
// acted. It may end the match.
func (g *Game) stateChecks() bool {
	for p := Player(0); p < 2; p++ {
		if g.pl[p].Spire <= 0 {
			g.recordLoss(p, "spire")
		}
	}
	if g.lost[A] || g.lost[B] {
		g.endMatch()
		return false
	}
	g.derive()
	var doomed []int
	for _, id := range g.field {
		o := g.objs[id]
		if o.Card.Type == cards.Unit && (o.Core <= o.Wounds || o.Doomed) {
			doomed = append(doomed, id)
		}
	}
	for _, id := range doomed {
		g.destroyObj(id)
	}
	return len(doomed) > 0
}

// endMatch finishes the match from the recorded losses.
func (g *Game) endMatch() {
	g.over = true
	g.dec = DecNone
	for p := Player(0); p < 2; p++ {
		if g.lost[p] {
			g.out.begin("LOSE")
			g.out.player(p).str(g.lossReason[p]).end()
		}
	}
	switch {
	case g.lost[A] && g.lost[B]:
		g.winner, g.resReason = "draw", g.lossReason[A]
	case g.lost[A]:
		g.winner, g.resReason = "B", g.lossReason[A]
	default:
		g.winner, g.resReason = "A", g.lossReason[B]
	}
	g.out.begin("RESULT")
	g.out.str(g.winner).str(g.resReason).end()
}

// endDraw ends the match as a draw without losers.
func (g *Game) endDraw(reason string) {
	g.over = true
	g.dec = DecNone
	g.winner, g.resReason = "draw", reason
	g.out.begin("RESULT")
	g.out.str("draw").str(reason).end()
}
