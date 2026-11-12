package engine

import (
	"github.com/spiremark/cardgame/cards"
)

func (g *Game) execAll(effs []*cards.Effect, c *ctx) {
	for _, e := range effs {
		g.exec(e, c)
	}
}

func (g *Game) exec(e *cards.Effect, c *ctx) {
	switch e.Op {
	case cards.OpDamage:
		n := g.amt(e.A1, c)
		if n <= 0 {
			return
		}
		for _, t := range g.dselTargets(e.DSel, c) {
			g.dealDamage(c.src, t, n)
		}
	case cards.OpDestroy:
		for _, o := range g.objs(e.Sel, c) {
			g.destroy(o)
		}
	case cards.OpSacrifice:
		for _, o := range g.objs(e.Sel, c) {
			g.sacrifice(o)
		}
	case cards.OpExile:
		for _, o := range g.objs(e.Sel, c) {
			g.exile(o)
		}
	case cards.OpBounce:
		for _, o := range g.objs(e.Sel, c) {
			g.bounce(o)
		}
	case cards.OpDraw:
		n := g.amt(e.A1, c)
		if n <= 0 {
			return
		}
		for _, p := range g.players(e.PSel, c) {
			g.draw(p, n)
		}
	case cards.OpDiscard:
		n := g.amt(e.A1, c)
		if n <= 0 {
			return
		}
		for _, p := range g.players(e.PSel, c) {
			for i := 0; i < n && len(g.pl[p].hand) > 0; i++ {
				g.discardOne(p)
			}
		}
	case cards.OpMill:
		n := g.amt(e.A1, c)
		if n <= 0 {
			return
		}
		for _, p := range g.players(e.PSel, c) {
			for i := 0; i < n && len(g.pl[p].vault) > 0; i++ {
				g.millOne(p)
			}
		}
	case cards.OpSpire:
		n := g.amt(e.A1, c)
		for _, p := range g.players(e.PSel, c) {
			g.changeSpire(p, n)
		}
	case cards.OpEmber:
		n := g.amt(e.A1, c)
		if n <= 0 {
			return
		}
		for _, p := range g.players(e.PSel, c) {
			g.gainEmber(p, n)
		}
	case cards.OpCap:
		n := g.amt(e.A1, c)
		if n <= 0 {
			return
		}
		for _, p := range g.players(e.PSel, c) {
			g.raiseCap(p, n)
		}
	case cards.OpModify:
		a, b := g.amt(e.A1, c), g.amt(e.A2, c)
		r := g.addRecord(rModify, c.ctrl, c.src, a, b, cards.KW{}, g.objs(e.Sel, c))
		for _, o := range r.affected {
			g.emit("BUFF", oidS(o), itoa(a), itoa(b))
		}
	case cards.OpSetbody:
		a, b := g.amt(e.A1, c), g.amt(e.A2, c)
		r := g.addRecord(rSetbody, c.ctrl, c.src, a, b, cards.KW{}, g.objs(e.Sel, c))
		for _, o := range r.affected {
			g.emit("SETBODY", oidS(o), itoa(a), itoa(b))
		}
	case cards.OpSwapstats:
		r := g.addRecord(rSwap, c.ctrl, c.src, 0, 0, cards.KW{}, g.objs(e.Sel, c))
		for _, o := range r.affected {
			g.emit("SWAP", oidS(o))
		}
	case cards.OpGrant:
		r := g.addRecord(rGrant, c.ctrl, c.src, 0, 0, e.KW, g.objs(e.Sel, c))
		for _, o := range r.affected {
			g.emit("GRANT", oidS(o), e.KW.String())
		}
	case cards.OpStrip:
		r := g.addRecord(rStrip, c.ctrl, c.src, 0, 0, cards.KW{}, g.objs(e.Sel, c))
		for _, o := range r.affected {
			g.emit("STRIP", oidS(o))
		}
	case cards.OpControl:
		r := g.addRecord(rControl, c.ctrl, c.src, 0, 0, cards.KW{}, g.objs(e.Sel, c))
		for _, o := range r.affected {
			o.since = g.turn
			g.removeFromCombat(o)
		}
		for _, o := range r.affected {
			g.emit("CONTROL", oidS(o), c.ctrl.String())
		}
	case cards.OpCounters:
		n := g.amt(e.A1, c)
		for _, o := range g.objs(e.Sel, c) {
			g.addCounters(o, n)
		}
	case cards.OpReady, cards.OpExhaust:
		for _, o := range g.objs(e.Sel, c) {
			g.setReady(o, e.Op == cards.OpReady)
		}
	case cards.OpDoom:
		for _, o := range g.objs(e.Sel, c) {
			g.doom(o)
		}
	case cards.OpWard:
		n := g.amt(e.A1, c)
		if n <= 0 {
			return
		}
		for _, o := range g.objs(e.Sel, c) {
			if o.zone == ZField {
				o.ward += n
				g.emit("WARD", oidS(o), itoa(n), itoa(o.ward))
			}
		}
	case cards.OpShield:
		n := g.amt(e.A1, c)
		if n <= 0 {
			return
		}
		for _, p := range g.players(e.PSel, c) {
			g.pl[p].shield += n
			g.emit("SHIELD", p.String(), itoa(n), itoa(g.pl[p].shield))
		}
	case cards.OpSummon, cards.OpConjure:
		n := g.amt(e.A1, c)
		if n <= 0 {
			return
		}
		card, _ := g.db.Get(e.CardID)
		for _, p := range g.players(e.PSel, c) {
			for i := 0; i < n; i++ {
				o := g.newObj(card, p)
				if e.Op == cards.OpSummon {
					g.emit("CREATE", oidS(o), card.ID, "field")
					g.enterField(o, p)
				} else {
					g.emit("CREATE", oidS(o), card.ID, "hand")
					g.toHand(o)
				}
			}
		}
	case cards.OpReanimate:
		for _, o := range g.objs(e.Sel, c) {
			if o.zone == ZAsh && o.Card.Type == cards.Unit {
				g.detach(o)
				g.enterField(o, c.ctrl)
			}
		}
	case cards.OpRecall:
		for _, o := range g.objs(e.Sel, c) {
			if o.zone == ZAsh {
				g.detach(o)
				g.toHand(o)
				g.emit("RECALL", oidS(o), o.Card.ID)
			}
		}
	case cards.OpNegate:
		if e.Sel.N <= len(c.targets) {
			t := c.targets[e.Sel.N-1]
			if t.kind == tEntry && !t.removed && t.e.onChain {
				g.negate(t.e)
			}
		}
	case cards.OpDig:
		g.dig(e, c)
	case cards.OpDelay:
		d := &delayed{
			ts: g.newTS(), ctrl: c.ctrl, src: c.src, when: e.When, effects: e.Body,
			specs: c.specs,
		}
		d.targets = make([]target, len(c.targets))
		for i, t := range c.targets {
			t.removed = false
			d.targets[i] = t
		}
		g.delays = append(g.delays, d)
		g.emit("DELAY", c.ctrl.String(), e.When.String())
	case cards.OpIf:
		if g.cond(e.Cond, c) {
			g.execAll(e.Body, c)
		} else if e.HasElse {
			g.execAll(e.Else, c)
		}
	case cards.OpEach:
		list := g.objs(e.Sel, c)
		zones := make([]Zone, len(list))
		for i, o := range list {
			zones[i] = o.zone
		}
		saved := c.that
		for i, o := range list {
			if o.zone != zones[i] {
				continue
			}
			c.that = o
			g.execAll(e.Body, c)
		}
		c.that = saved
	case cards.OpRepeat:
		n := g.amt(e.A1, c)
		for i := 0; i < n; i++ {
			g.execAll(e.Body, c)
		}
	case cards.OpNothing:
	}
}

func (g *Game) dig(e *cards.Effect, c *ctx) {
	fc := &ctx{ctrl: c.ctrl, src: c.src}
	for _, p := range g.players(e.PSel, c) {
		pl := &g.pl[p]
		n := e.K
		if n > len(pl.vault) {
			n = len(pl.vault)
		}
		if n < 0 {
			n = 0
		}
		top := append([]*Obj(nil), pl.vault[:n]...)
		for i := 0; i < n; i++ {
			pl.vault[i] = nil
		}
		pl.vault = pl.vault[n:]
		for _, o := range top {
			o.zone = ZNone
		}
		g.touch()
		hit := -1
		for i, o := range top {
			if g.matchFilters(o, e.Filters, fc) {
				hit = i
				break
			}
		}
		if hit >= 0 {
			o := top[hit]
			top = append(top[:hit:hit], top[hit+1:]...)
			g.toHand(o)
			g.emit("DIG", p.String(), oidS(o), o.Card.ID)
		} else {
			g.emit("DIG-MISS", p.String())
		}
		for _, o := range top {
			o.zone = ZVault
			pl.vault = append(pl.vault, o)
			g.emit("BOTTOM", p.String(), oidS(o), o.Card.ID)
		}
		g.touch()
	}
}

// negate implements 17.20.
func (g *Game) negate(e *entry) {
	g.removeEntry(e)
	g.emit("NEGATE", "~"+itoa(e.cid))
	if e.kind == entRite || e.kind == entUnit || e.kind == entRelic {
		g.toAsh(e.src)
		g.emit("SPENT", oidS(e.src), e.src.Card.ID)
	}
}

func (g *Game) removeEntry(e *entry) {
	e.onChain = false
	for i, x := range g.chain {
		if x == e {
			copy(g.chain[i:], g.chain[i+1:])
			g.chain[len(g.chain)-1] = nil
			g.chain = g.chain[:len(g.chain)-1]
			return
		}
	}
}
