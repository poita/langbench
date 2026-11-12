package engine

import (
	"sort"

	"github.com/spiremark/cardgame/cards"
)

func (g *Game) addPending(x *Obj, ab *cards.Ability, ctrl Player, it target) {
	g.pending = append(g.pending, &pendingTrig{
		ctrl: ctrl, ts: x.ts, oid: x.OID, idx: ab.Index, src: x, ab: ab, it: it,
	})
}

// fireOwn collects the ev abilities of x itself. Leave and dies listen even
// though x has already left the Field (SPEC 13.1).
func (g *Game) fireOwn(ev cards.Event, x *Obj, it target) {
	exempt := ev == cards.EvLeave || ev == cards.EvDies
	if x.zone == ZField {
		if g.strippedOf(x) && !exempt {
			return
		}
	} else if !exempt {
		return
	}
	ctrl := g.ctrlOf(x)
	for _, ab := range x.Card.Abilities {
		if ab.Kind == cards.AbOn && ab.Event == ev {
			g.addPending(x, ab, ctrl, it)
		}
	}
}

// fireField collects ev abilities from every listening Field object for
// which pred(listener, listenerController) holds.
func (g *Game) fireField(ev cards.Event, it target, pred func(l *Obj, ctrl Player) bool) {
	g.ensure()
	for _, l := range g.field {
		if l.stripped {
			continue
		}
		if pred != nil && !pred(l, l.ctrl) {
			continue
		}
		for _, ab := range l.Card.Abilities {
			if ab.Kind == cards.AbOn && ab.Event == ev {
				g.addPending(l, ab, l.ctrl, it)
			}
		}
	}
}

func (g *Game) collectArrive(o *Obj) {
	g.fireOwn(cards.EvArrive, o, objTarget(o))
	if o.Card.Type != cards.Unit {
		return
	}
	oc := g.ctrlOf(o)
	g.fireField(cards.EvAllyArrive, objTarget(o), func(l *Obj, c Player) bool { return l != o && c == oc })
	g.fireField(cards.EvEnemyArrive, objTarget(o), func(l *Obj, c Player) bool { return l != o && c != oc })
}

// collectDeath collects the triggers of 17.3 step 5 for a unit or relic that
// was destroyed or sacrificed; ctrl is its controller when it left.
func (g *Game) collectDeath(o *Obj, ctrl Player) {
	g.fireOwn(cards.EvDies, o, objTarget(o))
	g.fireOwn(cards.EvLeave, o, objTarget(o))
	if o.Card.Type != cards.Unit {
		return
	}
	g.fireField(cards.EvAllyDies, objTarget(o), func(l *Obj, c Player) bool { return c == ctrl })
	g.fireField(cards.EvEnemyDies, objTarget(o), func(l *Obj, c Player) bool { return c != ctrl })
}

func (g *Game) collectLeave(o *Obj) { g.fireOwn(cards.EvLeave, o, objTarget(o)) }

func (g *Game) collectDraw(p Player, card *Obj) {
	g.fireField(cards.EvYouDraw, objTarget(card), func(l *Obj, c Player) bool { return c == p })
}

func (g *Game) collectSpireLoss(p Player) {
	g.fireField(cards.EvSpireLoss, playerTarget(p), func(l *Obj, c Player) bool { return c == p })
	g.fireField(cards.EvEnemySpireLoss, playerTarget(p), func(l *Obj, c Player) bool { return c != p })
}

func (g *Game) collectDamage(src *Obj, t target) {
	if t.kind == tObj && t.o.zone == ZField {
		g.fireOwn(cards.EvDamaged, t.o, objTarget(src))
	}
	if src.zone == ZField {
		g.fireOwn(cards.EvDealsDamage, src, t)
	}
}

func (g *Game) collectPlayRite(p Player, rite *Obj) {
	g.fireField(cards.EvYouPlayRite, objTarget(rite), func(l *Obj, c Player) bool { return c == p })
	g.fireField(cards.EvEnemyPlaysRite, objTarget(rite), func(l *Obj, c Player) bool { return c != p })
}

// collectDelayed moves every delayed trigger with the given timing (and, for
// your-next-turn-start, the given controller) to the pending list.
func (g *Game) collectDelayed(when cards.When, onlyCtrl bool, ctrl Player) {
	kept := g.delays[:0]
	for _, d := range g.delays {
		if d.when == when && (!onlyCtrl || d.ctrl == ctrl) {
			g.pending = append(g.pending, &pendingTrig{
				ctrl: d.ctrl, ts: d.ts, oid: d.src.OID, idx: 0, src: d.src, delayed: d,
			})
			continue
		}
		kept = append(kept, d)
	}
	for i := len(kept); i < len(g.delays); i++ {
		g.delays[i] = nil
	}
	g.delays = kept
}

// pushTriggers implements 13.3 and reports whether the pending list was
// non-empty.
func (g *Game) pushTriggers() bool {
	if len(g.pending) == 0 {
		return false
	}
	batch := g.pending
	g.pending = nil
	active := g.active
	sort.SliceStable(batch, func(i, j int) bool {
		a, b := batch[i], batch[j]
		ap, bp := 1, 1
		if a.ctrl == active {
			ap = 0
		}
		if b.ctrl == active {
			bp = 0
		}
		if ap != bp {
			return ap < bp
		}
		if a.ts != b.ts {
			return a.ts < b.ts
		}
		if a.oid != b.oid {
			return a.oid < b.oid
		}
		return a.idx < b.idx
	})
	var entries []*entry
	for _, pt := range batch {
		e := &entry{kind: entTrigger, ctrl: pt.ctrl, src: pt.src, it: pt.it}
		if pt.delayed != nil {
			d := pt.delayed
			e.idx = 0
			e.effects = d.effects
			e.specs = d.specs
			e.targets = make([]target, len(d.targets))
			for i, t := range d.targets {
				t.removed = false
				e.targets[i] = t
			}
		} else {
			e.idx = pt.idx
			e.specs = pt.ab.Targets
			if len(e.specs) > 0 {
				ts, ok := g.autoTargets(e.specs, &ctx{ctrl: pt.ctrl, src: pt.src}, nil)
				if !ok {
					g.emit("TRIGGER-NO-TARGET", pt.ctrl.String(), oidS(pt.src), itoa(pt.idx))
					continue
				}
				e.targets = ts
			}
		}
		e.cid = g.nextCID
		g.nextCID++
		f := []string{pt.ctrl.String(), "~" + itoa(e.cid), oidS(e.src), itoa(e.idx)}
		for _, t := range e.targets {
			f = append(f, t.render())
		}
		g.emit("TRIGGER", f...)
		entries = append(entries, e)
	}
	for i := len(entries) - 1; i >= 0; i-- {
		entries[i].onChain = true
		g.chain = append(g.chain, entries[i])
	}
	return true
}
