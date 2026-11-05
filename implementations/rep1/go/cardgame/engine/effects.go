package engine

import (
	"cardgame/cards"
)

// exec runs a list of effects in order.
func (g *Game) exec(effs []*cards.Effect, c *ctx) {
	for _, e := range effs {
		g.execOne(e, c)
	}
}

func (g *Game) players(e *cards.Effect, c *ctx) []Player { return g.selPlayers(e.Sel, c) }

func (g *Game) execOne(e *cards.Effect, c *ctx) {
	switch e.Kind {
	case cards.EffNothing:
	case cards.EffDamage:
		n := g.amount(&e.A, c)
		if n <= 0 {
			return
		}
		for _, t := range g.dmgTargets(e.Sel, c) {
			g.dealDamage(c.source, t, n)
		}
	case cards.EffDestroy:
		for _, id := range g.selObjs(e.Sel, c, nil) {
			g.destroyObj(id)
		}
	case cards.EffSacrifice:
		for _, id := range g.selObjs(e.Sel, c, nil) {
			g.sacrificeObj(id)
		}
	case cards.EffExile:
		for _, id := range g.selObjs(e.Sel, c, nil) {
			g.exileObj(id)
		}
	case cards.EffBounce:
		for _, id := range g.selObjs(e.Sel, c, nil) {
			g.bounceObj(id)
		}
	case cards.EffDraw:
		n := g.amount(&e.A, c)
		if n <= 0 {
			return
		}
		for _, p := range g.players(e, c) {
			for i := 0; i < n; i++ {
				if !g.drawOne(p) {
					break
				}
			}
		}
	case cards.EffDiscard:
		n := g.amount(&e.A, c)
		if n <= 0 {
			return
		}
		for _, p := range g.players(e, c) {
			for i := 0; i < n && len(g.pl[p].Hand) > 0; i++ {
				g.discardOne(p)
			}
		}
	case cards.EffMill:
		n := g.amount(&e.A, c)
		if n <= 0 {
			return
		}
		for _, p := range g.players(e, c) {
			for i := 0; i < n && len(g.pl[p].Vault) > 0; i++ {
				g.millOne(p)
			}
		}
	case cards.EffSpire:
		n := g.amount(&e.A, c)
		for _, p := range g.players(e, c) {
			g.changeSpire(p, n)
		}
	case cards.EffEmber:
		n := g.amount(&e.A, c)
		if n <= 0 {
			return
		}
		for _, p := range g.players(e, c) {
			g.gainEmber(p, n)
		}
	case cards.EffCap:
		n := g.amount(&e.A, c)
		if n <= 0 {
			return
		}
		for _, p := range g.players(e, c) {
			g.raiseCap(p, n)
		}
	case cards.EffModify, cards.EffSetbody:
		a, b := g.amount(&e.A, c), g.amount(&e.B, c)
		kind, name := RModify, "BUFF"
		if e.Kind == cards.EffSetbody {
			kind, name = RSetbody, "SETBODY"
		}
		rec := g.newDiscrete(c, Eff{Kind: kind, A: a, B: b}, g.selObjs(e.Sel, c, nil))
		for _, id := range rec.Effs[0].Affected {
			g.out.begin(name)
			g.out.obj(id).num(a).num(b).end()
		}
	case cards.EffSwapstats:
		rec := g.newDiscrete(c, Eff{Kind: RSwap}, g.selObjs(e.Sel, c, nil))
		for _, id := range rec.Effs[0].Affected {
			g.out.begin("SWAP")
			g.out.obj(id).end()
		}
	case cards.EffGrant:
		rec := g.newDiscrete(c, Eff{Kind: RGrant, Kw: e.Kw}, g.selObjs(e.Sel, c, nil))
		for _, id := range rec.Effs[0].Affected {
			g.out.begin("GRANT")
			g.out.obj(id).str(e.Kw.String()).end()
		}
	case cards.EffStrip:
		rec := g.newDiscrete(c, Eff{Kind: RStrip}, g.selObjs(e.Sel, c, nil))
		for _, id := range rec.Effs[0].Affected {
			g.out.begin("STRIP")
			g.out.obj(id).end()
		}
	case cards.EffControl:
		rec := g.newDiscrete(c, Eff{Kind: RControl}, g.selObjs(e.Sel, c, nil))
		for _, id := range rec.Effs[0].Affected {
			o := g.objs[id]
			o.Since = g.turn
			if o.Card.Type == cards.Unit {
				g.removeFromCombat(id)
			}
			g.out.begin("CONTROL")
			g.out.obj(id).player(c.ctrl).end()
		}
	case cards.EffCounters:
		n := g.amount(&e.A, c)
		for _, id := range g.selObjs(e.Sel, c, nil) {
			o := g.objs[id]
			if o.Zone != ZField {
				continue
			}
			nv := o.Counters + n
			if nv < 0 {
				nv = 0
			}
			if nv != o.Counters {
				d := nv - o.Counters
				o.Counters = nv
				g.stale = true
				g.out.begin("COUNTERS")
				g.out.obj(id).signed(d).num(nv).end()
			}
		}
	case cards.EffReady:
		for _, id := range g.selObjs(e.Sel, c, nil) {
			g.setExhausted(id, false)
		}
	case cards.EffExhaust:
		for _, id := range g.selObjs(e.Sel, c, nil) {
			g.setExhausted(id, true)
		}
	case cards.EffDoom:
		for _, id := range g.selObjs(e.Sel, c, nil) {
			if g.onField(id) && g.isUnit(id) {
				g.objs[id].Doomed = true
				g.out.begin("DOOM")
				g.out.obj(id).end()
			}
		}
	case cards.EffWard:
		n := g.amount(&e.A, c)
		if n <= 0 {
			return
		}
		for _, id := range g.selObjs(e.Sel, c, nil) {
			if o := g.objs[id]; o.Zone == ZField {
				o.Ward += n
				g.out.begin("WARD")
				g.out.obj(id).num(n).num(o.Ward).end()
			}
		}
	case cards.EffShield:
		n := g.amount(&e.A, c)
		if n <= 0 {
			return
		}
		for _, p := range g.players(e, c) {
			g.pl[p].Shield += n
			g.out.begin("SHIELD")
			g.out.player(p).num(n).num(g.pl[p].Shield).end()
		}
	case cards.EffSummon, cards.EffConjure:
		n := g.amount(&e.A, c)
		if n <= 0 {
			return
		}
		for _, p := range g.players(e, c) {
			for i := 0; i < n; i++ {
				oid := g.newObj(e.Card, p)
				g.objs[oid].Zone = ZChain
				g.out.begin("CREATE")
				if e.Kind == cards.EffSummon {
					g.out.obj(oid).str(e.Card.ID).str("field").end()
					g.enterField(oid, p)
				} else {
					g.out.obj(oid).str(e.Card.ID).str("hand").end()
					g.attach(oid, ZHand)
				}
			}
		}
	case cards.EffReanimate:
		for _, id := range g.selObjs(e.Sel, c, nil) {
			if o := g.objs[id]; o.Zone == ZAsh && o.Card.Type == cards.Unit {
				g.detach(id)
				g.enterField(id, c.ctrl)
			}
		}
	case cards.EffRecall:
		for _, id := range g.selObjs(e.Sel, c, nil) {
			if o := g.objs[id]; o.Zone == ZAsh {
				g.detach(id)
				g.attach(id, ZHand)
				g.out.begin("RECALL")
				g.out.obj(id).str(o.Card.ID).end()
			}
		}
	case cards.EffNegate:
		g.negate(e.Sel, c)
	case cards.EffDig:
		for _, p := range g.players(e, c) {
			g.dig(p, e, c)
		}
	case cards.EffDelay:
		d := &Delayed{
			TS: g.nextTS, Ctrl: c.ctrl, Source: c.source, When: e.When,
			Effects: e.Body, Specs: c.specs,
		}
		g.nextTS++
		for _, t := range c.targets {
			t.Removed = false
			d.Targets = append(d.Targets, t)
		}
		g.delayed = append(g.delayed, d)
		g.out.begin("DELAY")
		g.out.player(c.ctrl).str(e.When.String()).end()
	case cards.EffIf:
		if g.cond(e.Cond, c) {
			g.exec(e.Body, c)
		} else if e.HasElse {
			g.exec(e.Else, c)
		}
	case cards.EffEach:
		ids := g.selObjs(e.Sel, c, nil)
		zones := make([]Zone, len(ids))
		for i, id := range ids {
			zones[i] = g.objs[id].Zone
		}
		savedThat, savedHas := c.that, c.hasThat
		for i, id := range ids {
			if g.objs[id].Zone != zones[i] {
				continue
			}
			c.that, c.hasThat = id, true
			g.exec(e.Body, c)
		}
		c.that, c.hasThat = savedThat, savedHas
	case cards.EffRepeat:
		n := g.amount(&e.A, c)
		for i := 0; i < n; i++ {
			g.exec(e.Body, c)
		}
	}
}

// newDiscrete creates a turn-duration record over the objects of ids that
// are on the Field.
func (g *Game) newDiscrete(c *ctx, e Eff, ids []int) *Record {
	for _, id := range ids {
		if g.objs[id].Zone == ZField {
			e.Affected = append(e.Affected, id)
		}
	}
	e.Active = true
	rec := &Record{Eid: g.nextEid, TS: g.nextTS, Ctrl: c.ctrl, Source: c.source, Effs: []Eff{e}}
	g.nextEid++
	g.nextTS++
	g.records = append(g.records, rec)
	g.stale = true
	return rec
}

func (g *Game) setExhausted(id int, ex bool) {
	o := g.objs[id]
	if o.Zone != ZField || o.Exhausted == ex {
		return
	}
	o.Exhausted = ex
	g.touch(cards.DepReady)
	if ex {
		g.out.begin("EXHAUST")
	} else {
		g.out.begin("READY")
	}
	g.out.obj(id).end()
}

// ------------------------------------------------------------ primitives ---

func (g *Game) recordLoss(p Player, reason string) {
	if !g.lost[p] {
		g.lost[p] = true
		g.lossReason[p] = reason
	}
}

// drawOne makes p draw one card (SPEC 17.7). It reports false when the Vault
// was empty.
func (g *Game) drawOne(p Player) bool {
	ps := &g.pl[p]
	if len(ps.Vault) == 0 {
		g.out.begin("DRAW-EMPTY")
		g.out.player(p).end()
		g.recordLoss(p, "vault")
		return false
	}
	oid := ps.Vault[0]
	ps.Vault = ps.Vault[1:]
	g.attach(oid, ZHand)
	g.out.begin("DRAW")
	g.out.player(p).obj(oid).str(g.objs[oid].Card.ID).end()
	if !g.noTriggers {
		g.collectControlled(cards.EvYouDraw, p, Subject{SubjObj, oid})
	}
	return true
}

func (g *Game) discardOne(p Player) {
	ps := &g.pl[p]
	if len(ps.Hand) == 0 {
		return
	}
	oid := ps.Hand[0]
	g.detach(oid)
	g.attach(oid, ZAsh)
	g.out.begin("DISCARD")
	g.out.player(p).obj(oid).str(g.objs[oid].Card.ID).end()
}

func (g *Game) millOne(p Player) {
	ps := &g.pl[p]
	if len(ps.Vault) == 0 {
		return
	}
	oid := ps.Vault[0]
	ps.Vault = ps.Vault[1:]
	g.attach(oid, ZAsh)
	g.out.begin("MILL")
	g.out.player(p).obj(oid).str(g.objs[oid].Card.ID).end()
}

func (g *Game) changeSpire(p Player, delta int) {
	if delta == 0 {
		return
	}
	g.pl[p].Spire += delta
	g.touch(cards.DepSpire)
	g.out.begin("SPIRE")
	g.out.player(p).signed(delta).num(g.pl[p].Spire).end()
	if delta < 0 {
		g.collectSpireLoss(p)
	}
}

func (g *Game) gainEmber(p Player, n int) {
	g.pl[p].Ember += n
	g.touch(cards.DepEmber)
	g.out.begin("EMBERGAIN")
	g.out.player(p).num(n).num(g.pl[p].Ember).end()
}

func (g *Game) raiseCap(p Player, n int) {
	c := g.pl[p].Cap + n
	if c > g.cfg.MaxCap {
		c = g.cfg.MaxCap
	}
	g.pl[p].Cap = c
	g.out.begin("CAP")
	g.out.player(p).num(n).num(c).end()
}

// dealDamage implements SPEC 17.1 including prevention (15.2).
func (g *Game) dealDamage(src int, t Target, n int) {
	if n <= 0 {
		return
	}
	var pool *int
	prevented := 0
	if t.Kind == TObject {
		o := g.objs[t.ID]
		if o.Zone != ZField || o.Card.Type != cards.Unit {
			return // relics have no wounds; other zones take no damage
		}
		g.derive()
		rem := n - o.Plating
		if rem < 0 {
			rem = 0
		}
		pool = &o.Ward
		u := min(*pool, rem)
		*pool -= u
		prevented = n - (rem - u)
		n = rem - u
	} else {
		pool = &g.pl[t.ID].Shield
		u := min(*pool, n)
		*pool -= u
		prevented = u
		n -= u
	}
	if prevented > 0 {
		g.out.begin("PREVENT")
		g.out.target(t).num(prevented).end()
	}
	if n == 0 {
		return
	}
	g.out.begin("DAMAGE")
	g.out.obj(src).target(t).num(n).end()
	srcUnitOnField := g.onField(src) && g.isUnit(src)
	if t.Kind == TObject {
		g.objs[t.ID].Wounds += n
		g.touch(cards.DepWounds)
	} else {
		p := Player(t.ID)
		g.pl[p].Spire -= n
		g.touch(cards.DepSpire)
		g.out.begin("SPIRE")
		g.out.player(p).signed(-n).num(g.pl[p].Spire).end()
		g.collectSpireLoss(p)
	}
	if t.Kind == TObject && srcUnitOnField && g.hasKw(src, cards.Venom) {
		g.objs[t.ID].Doomed = true
		g.out.begin("DOOM")
		g.out.obj(t.ID).end()
	}
	if srcUnitOnField && g.hasKw(src, cards.Siphon) {
		cp := g.ctrlOf(src)
		g.pl[cp].Spire += n
		g.touch(cards.DepSpire)
		g.out.begin("SPIRE")
		g.out.player(cp).signed(n).num(g.pl[cp].Spire).end()
	}
	if !g.noTriggers {
		if t.Kind == TObject && g.onField(t.ID) {
			g.collectSelf(t.ID, cards.EvDamaged, Subject{SubjObj, src}, true)
		}
		if g.onField(src) {
			subj := Subject{SubjObj, t.ID}
			if t.Kind == TPlayer {
				subj = Subject{SubjPlayer, t.ID}
			}
			g.collectSelf(src, cards.EvDealsDamage, subj, true)
		}
	}
}

func (g *Game) hasKw(oid int, k cards.Keyword) bool {
	g.derive()
	return g.objs[oid].hasKw(k)
}

// destroyObj implements SPEC 17.3.
func (g *Game) destroyObj(oid int) {
	o := g.objs[oid]
	if o.Zone != ZField {
		return
	}
	g.derive()
	if o.hasKw(cards.Tenacity) && !o.TenacityUsed {
		o.TenacityUsed = true
		o.Wounds = 0
		o.Doomed = false
		g.touch(cards.DepWounds)
		g.out.begin("TENACITY")
		g.out.obj(oid).end()
		return
	}
	g.removeAndCollectDeath(oid, "DESTROY")
}

func (g *Game) sacrificeObj(oid int) {
	if g.objs[oid].Zone != ZField {
		return
	}
	g.removeAndCollectDeath(oid, "SACRIFICE")
}

func (g *Game) removeAndCollectDeath(oid int, event string) {
	o := g.objs[oid]
	wasUnit := o.Card.Type == cards.Unit
	ctrl := g.leaveField(oid)
	g.attach(oid, ZAsh)
	g.out.begin(event)
	g.out.obj(oid).str(o.Card.ID).end()
	g.collectDeath(oid, ctrl, wasUnit)
}

// exileObj implements SPEC 17.5.
func (g *Game) exileObj(oid int) {
	o := g.objs[oid]
	from := o.Zone
	fromField := from == ZField
	var ctrl Player
	if fromField {
		ctrl = g.leaveField(oid)
	} else {
		g.detach(oid)
	}
	g.attach(oid, ZRift)
	g.out.begin("EXILE")
	g.out.obj(oid).str(o.Card.ID).str(zoneNames[from]).end()
	if fromField {
		g.collectLeave(oid, ctrl)
	}
}

// bounceObj implements SPEC 17.6.
func (g *Game) bounceObj(oid int) {
	o := g.objs[oid]
	if o.Zone != ZField {
		return
	}
	ctrl := g.leaveField(oid)
	g.attach(oid, ZHand)
	g.out.begin("BOUNCE")
	g.out.obj(oid).str(o.Card.ID).end()
	g.collectLeave(oid, ctrl)
}

func (g *Game) negate(s *cards.Sel, c *ctx) {
	if s.N > len(c.targets) {
		return
	}
	t := c.targets[s.N-1]
	if t.Kind != TChain || t.Removed {
		return
	}
	for i, en := range g.chain {
		if en.Cid != t.ID {
			continue
		}
		g.chain = append(g.chain[:i], g.chain[i+1:]...)
		g.out.begin("NEGATE")
		g.out.cid(en.Cid).end()
		if en.Kind == EKRite || en.Kind == EKUnit || en.Kind == EKRelic {
			g.attach(en.Source, ZAsh)
			g.out.begin("SPENT")
			g.out.obj(en.Source).str(g.objs[en.Source].Card.ID).end()
		}
		return
	}
}

// dig implements SPEC 17.21 for one player.
func (g *Game) dig(p Player, e *cards.Effect, c *ctx) {
	ps := &g.pl[p]
	k := int(e.DigK)
	if k < 0 {
		k = 0
	}
	if k > len(ps.Vault) {
		k = len(ps.Vault)
	}
	look := append([]int(nil), ps.Vault[:k]...)
	ps.Vault = ps.Vault[k:]
	g.touch(cards.DepZones)
	found := -1
	for i, id := range look {
		if g.filtersOK(e.Filters, id, c) {
			found = i
			break
		}
	}
	if found >= 0 {
		id := look[found]
		g.attach(id, ZHand)
		g.out.begin("DIG")
		g.out.player(p).obj(id).str(g.objs[id].Card.ID).end()
		look = append(look[:found], look[found+1:]...)
	} else {
		g.out.begin("DIG-MISS")
		g.out.player(p).end()
	}
	for _, id := range look {
		g.attach(id, ZVault)
		g.out.begin("BOTTOM")
		g.out.player(p).obj(id).str(g.objs[id].Card.ID).end()
	}
}
