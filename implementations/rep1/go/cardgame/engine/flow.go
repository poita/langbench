package engine

import (
	"errors"
	"io"
	"sort"

	"github.com/spiremark/cardgame/cards"
)

// ErrUnknownCard is returned by New when a setup zone names a card the
// database does not define.
var ErrUnknownCard = errors.New("unknown card")

// New sets up a match (SPEC section 8), writing its events to out, and runs
// the engine forward to the first decision point.
func New(cfg Config, db *cards.Database, out io.Writer) (*Game, error) {
	zones := [][2][]CardCount{cfg.Deck, cfg.Hand, cfg.Field, cfg.Ash, cfg.Rift}
	for _, z := range zones {
		for p := range z {
			for _, cc := range z[p] {
				if _, ok := db.Get(cc.ID); !ok {
					return nil, ErrUnknownCard
				}
			}
		}
	}
	g := &Game{
		cfg: cfg, db: db, out: out, rng: nil,
		nextCID: 1, nextTS: 1, nextEID: 1,
		byOID: []*Obj{nil}, turn: 1, active: cfg.First, phase: "dawn",
		step: sDawn, dirty: true,
	}
	g.rngInit(cfg.Seed)
	for p := A; p <= B; p++ {
		g.pl[p].spire = cfg.Spire
		g.pl[p].cap = cfg.Cap[p]
	}
	var onField []*Obj
	for p := A; p <= B; p++ {
		mk := func(list []CardCount, dst func(*Obj)) {
			for _, cc := range list {
				card, _ := db.Get(cc.ID)
				for i := 0; i < cc.Count; i++ {
					o := g.newObj(card, p)
					dst(o)
				}
			}
		}
		mk(cfg.Deck[p], func(o *Obj) { o.zone = ZVault; g.pl[p].vault = append(g.pl[p].vault, o) })
		mk(cfg.Hand[p], func(o *Obj) { g.toHand(o) })
		mk(cfg.Field[p], func(o *Obj) { onField = append(onField, o) })
		mk(cfg.Ash[p], func(o *Obj) { g.toAsh(o) })
		mk(cfg.Rift[p], func(o *Obj) { g.toRift(o) })
	}
	for _, o := range onField {
		g.place(o, o.Owner, 0)
	}
	g.emit("GAME-START", cfg.First.String())
	if cfg.Shuffle {
		for p := A; p <= B; p++ {
			v := g.pl[p].vault
			g.rng.Shuffle(len(v), func(i, j int) { v[i], v[j] = v[j], v[i] })
			g.emit("SHUFFLE", p.String())
		}
	}
	g.noTriggers = true
	g.draw(cfg.First, cfg.Opening)
	g.draw(cfg.First.Opp(), cfg.Opening)
	g.noTriggers = false
	g.settle()
	if !g.over {
		g.emit("TURN", "1", cfg.First.String())
		g.advance()
	}
	return g, nil
}

// Finish emits the closing "RESULT pending none" line if the match is still
// running. It is idempotent.
func (g *Game) Finish() {
	if g.over || g.finalized {
		return
	}
	g.finalized = true
	g.emit("RESULT", "pending", "none")
}

// -------------------------------------------------------------- match end

func (g *Game) endMatch() {
	for p := A; p <= B; p++ {
		if g.loss[p] != "" {
			g.emit("LOSE", p.String(), g.loss[p])
		}
	}
	switch {
	case g.loss[A] != "" && g.loss[B] != "":
		g.winner, g.reason = "draw", g.loss[A]
	case g.loss[A] != "":
		g.winner, g.reason = "B", g.loss[A]
	default:
		g.winner, g.reason = "A", g.loss[B]
	}
	g.emit("RESULT", g.winner, g.reason)
	g.over = true
	g.decKind = DecNone
}

func (g *Game) concede(p Player) {
	g.setLoss(p, "concede")
	g.endMatch()
}

// ------------------------------------------------------------ state checks

// settle implements 10.5.
func (g *Game) settle() bool {
	acted := false
	for {
		a := g.stateChecks()
		if g.over {
			return true
		}
		b := g.pushTriggers()
		acted = acted || a || b
		if !a && !b {
			return acted
		}
	}
}

func (g *Game) stateChecks() bool {
	for p := A; p <= B; p++ {
		if g.pl[p].spire <= 0 {
			g.setLoss(p, "spire")
		}
	}
	if g.loss[A] != "" || g.loss[B] != "" {
		g.endMatch()
		return true
	}
	g.ensure()
	var doomed []*Obj
	for _, o := range g.field {
		if o.Card.Type == cards.Unit && (o.core <= o.wounds || o.doomed) {
			doomed = append(doomed, o)
		}
	}
	if len(doomed) == 0 {
		return false
	}
	for _, o := range doomed {
		g.destroy(o)
	}
	return true
}

func (g *Game) drain() {
	for {
		g.settle()
		if g.over || len(g.chain) == 0 {
			return
		}
		g.resolveTop()
	}
}

// ------------------------------------------------------------- resolution

func (g *Game) entryCtx(e *entry) *ctx {
	return &ctx{ctrl: e.ctrl, src: e.src, it: e.it, targets: e.targets, specs: e.specs}
}

// resolveTop implements 11.6 for the entry on top of the Chain.
func (g *Game) resolveTop() {
	e := g.chain[len(g.chain)-1]
	g.emit("RESOLVE", "~"+itoa(e.cid))
	c := g.entryCtx(e)
	allRemoved := len(e.targets) > 0
	for i := range e.targets {
		legal := g.targetLegal(&e.specs[i], e.targets[i], c, e)
		e.targets[i].removed = !legal
		if legal {
			allRemoved = false
		}
	}
	if allRemoved {
		g.emit("FIZZLE", "~"+itoa(e.cid))
	} else {
		switch e.kind {
		case entRite:
			g.execAll(e.src.Card.Abilities[0].Effects, c)
		case entUnit, entRelic:
			g.enterField(e.src, e.ctrl)
		default:
			if e.effects != nil || e.idx == 0 {
				g.execAll(e.effects, c)
			} else {
				g.execAll(e.src.Card.Ability(e.idx).Effects, c)
			}
		}
	}
	g.removeEntry(e)
	switch e.kind {
	case entRite:
		if e.src.zone == ZChain {
			g.toAsh(e.src)
			g.emit("SPENT", oidS(e.src), e.src.Card.ID)
		}
	case entUnit, entRelic:
		if e.src.zone == ZChain { // fizzled
			g.toAsh(e.src)
		}
	}
}

// -------------------------------------------------------- turn structure

func (g *Game) advance() {
	for !g.over && g.decKind == DecNone {
		g.stepOnce()
	}
}

// startRound begins a priority round (10.4); next is the step to run when it
// ends.
func (g *Game) startRound(next step) {
	g.step = next
	g.passes = 0
	g.settle()
	if g.over {
		return
	}
	g.decKind, g.decPlayer = DecPriority, g.active
}

func (g *Game) enterPhase(name string) {
	g.phase = name
	g.emit("PHASE", name)
}

func (g *Game) stepOnce() {
	switch g.step {
	case sDawn:
		g.enterPhase("dawn")
		a := g.active
		c := g.pl[a].cap + 1
		if c > g.cfg.MaxCap {
			c = g.cfg.MaxCap
		}
		g.pl[a].cap = c
		for p := A; p <= B; p++ {
			g.pl[p].ember = g.pl[p].cap
			g.emit("EMBER", p.String(), itoa(g.pl[p].ember), itoa(g.pl[p].cap))
		}
		g.touch()
		g.ensure()
		for _, o := range append([]*Obj(nil), g.field...) {
			if o.ctrl == a && !o.ready {
				g.setReady(o, true)
			}
		}
		for _, o := range g.field {
			o.tenUsed, o.once = false, nil
		}
		g.fireField(cards.EvTurnStart, playerTarget(a), nil)
		g.fireField(cards.EvYourTurnStart, playerTarget(a), func(l *Obj, c Player) bool { return c == a })
		g.collectDelayed(cards.YourNextTurnStart, true, a)
		g.drain()
		g.step = sDraw
	case sDraw:
		g.enterPhase("draw")
		if g.turn != 1 {
			g.draw(g.active, 1)
		}
		g.drain()
		g.step = sMain1
	case sMain1:
		g.enterPhase("main1")
		g.startRound(sClashAttack)
	case sClashAttack:
		g.enterPhase("clash-attack")
		g.settle()
		if g.over {
			return
		}
		g.decKind, g.decPlayer = DecAttackers, g.active
	case sClashBlock:
		g.enterPhase("clash-block")
		g.settle()
		if g.over {
			return
		}
		g.decKind, g.decPlayer = DecBlockers, g.active.Opp()
	case sRiposte:
		any := false
		for _, o := range g.field {
			if g.inCombat(o) && g.hasKW(o, cards.Riposte) {
				any = true
				break
			}
		}
		if !any {
			g.step = sDamage
			return
		}
		g.enterPhase("clash-riposte")
		g.riposteSet = map[*Obj]bool{}
		for _, o := range g.field {
			if g.inCombat(o) && g.hasKW(o, cards.Riposte) {
				g.riposteSet[o] = true
			}
		}
		g.combatDamage(func(o *Obj) bool { return g.riposteSet[o] })
		g.startRound(sDamage)
	case sDamage:
		g.enterPhase("clash-damage")
		g.combatDamage(func(o *Obj) bool { return !g.riposteSet[o] })
		g.startRound(sClashEnd)
	case sClashEnd:
		g.enterPhase("clash-end")
		for _, o := range g.field {
			if g.inCombat(o) {
				g.fireOwn(cards.EvEndOfCombat, o, objTarget(o))
			}
		}
		g.collectDelayed(cards.EndOfCombat, false, A)
		g.startRound(sClashEndDone)
	case sClashEndDone:
		for _, o := range g.field {
			o.attacking, o.blocking, o.blocked, o.blockers, o.blocks = false, false, false, nil, nil
		}
		g.riposteSet = nil
		g.touch()
		g.step = sMain2
	case sMain2:
		g.enterPhase("main2")
		g.startRound(sDuskTrigger)
	case sDuskTrigger:
		g.enterPhase("dusk-trigger")
		a := g.active
		g.fireField(cards.EvTurnEnd, playerTarget(a), nil)
		g.fireField(cards.EvYourTurnEnd, playerTarget(a), func(l *Obj, c Player) bool { return c == a })
		g.collectDelayed(cards.TurnEnd, false, A)
		g.startRound(sDuskDiscard)
	case sDuskDiscard:
		g.enterPhase("dusk-discard")
		for len(g.pl[g.active].hand) > g.cfg.HandMax {
			g.discardOne(g.active)
		}
		g.drain()
		g.step = sDuskCleanup
	case sDuskCleanup:
		g.enterPhase("dusk-cleanup")
		for _, o := range g.field {
			o.wounds, o.doomed, o.ward = 0, false, 0
		}
		g.pl[A].shield, g.pl[B].shield = 0, 0
		kept := g.records[:0]
		for _, r := range g.records {
			if r.kind == rControl {
				for _, o := range r.affected {
					if o.zone == ZField {
						o.since = g.turn
					}
				}
			}
			if r.kind == rAura {
				kept = append(kept, r)
			}
		}
		for i := len(kept); i < len(g.records); i++ {
			g.records[i] = nil
		}
		g.records = kept
		keptD := g.delays[:0]
		for _, d := range g.delays {
			if d.when == cards.YourNextTurnStart {
				keptD = append(keptD, d)
			}
		}
		for i := len(keptD); i < len(g.delays); i++ {
			g.delays[i] = nil
		}
		g.delays = keptD
		g.touch()
		g.drain()
		g.step = sAdvance
	case sAdvance:
		g.turn++
		g.active = g.active.Opp()
		if g.turn > g.cfg.TurnLimit {
			g.winner, g.reason = "draw", "turn-limit"
			g.emit("RESULT", "draw", "turn-limit")
			g.over = true
			g.decKind = DecNone
			return
		}
		g.emit("TURN", itoa(g.turn), g.active.String())
		g.step = sDawn
	}
}

// ------------------------------------------------------------------ combat

func (g *Game) canAttack(o *Obj) bool {
	if o == nil || o.zone != ZField || g.ctrlOf(o) != g.active || o.Card.Type != cards.Unit || !o.ready {
		return false
	}
	if g.settling(o) && !g.hasKW(o, cards.Vanguard) {
		return false
	}
	return !g.hasKW(o, cards.Shackled)
}

func (g *Game) canBlock(b, a *Obj) bool {
	if b == nil || a == nil || b.zone != ZField || g.ctrlOf(b) != g.active.Opp() ||
		b.Card.Type != cards.Unit || !b.ready || g.hasKW(b, cards.Siegework) {
		return false
	}
	if a.zone != ZField || !a.attacking {
		return false
	}
	if g.hasKW(a, cards.Ghostwalk) && !g.hasKW(b, cards.Ghostwalk) && !g.hasKW(b, cards.Skyhook) {
		return false
	}
	return true
}

type assignment struct {
	src *Obj
	tgt target
	n   int
}

// combatDamage deals the combat damage of every unit in combat for which
// deals returns true (19.5, 19.6, 17.2).
func (g *Game) combatDamage(deals func(*Obj) bool) {
	g.ensure()
	var units []*Obj
	for _, o := range g.field {
		if g.inCombat(o) && deals(o) {
			units = append(units, o)
		}
	}
	var as []assignment
	defender := g.active.Opp()
	for _, u := range units {
		e := g.edgeOf(u)
		if e <= 0 {
			continue
		}
		switch {
		case u.blocking:
			if u.blocks != nil {
				as = append(as, assignment{u, objTarget(u.blocks), e})
			}
		case !u.blocked:
			as = append(as, assignment{u, playerTarget(defender), e})
		default:
			var list []*Obj
			for _, b := range u.blockers {
				if b.zone == ZField && b.blocking && b.blocks == u {
					list = append(list, b)
				}
			}
			if len(list) == 0 {
				continue
			}
			sortObjs(list)
			r := e
			amounts := make([]int, len(list))
			venom := g.hasKW(u, cards.Venom)
			for i, b := range list {
				need := 1
				if !venom {
					need = max(0, g.coreOf(b)-b.wounds)
				}
				a := min(r, need)
				amounts[i] = a
				r -= a
			}
			if r > 0 {
				if g.hasKW(u, cards.Pierce) {
					as = append(as, assignment{u, playerTarget(defender), r})
				} else {
					amounts[len(amounts)-1] += r
				}
			}
			for i, b := range list {
				if amounts[i] > 0 {
					as = append(as, assignment{u, objTarget(b), amounts[i]})
				}
			}
		}
	}
	sort.SliceStable(as, func(i, j int) bool {
		si, sj := (target{kind: tObj, o: as[i].src}).key(), (target{kind: tObj, o: as[j].src}).key()
		if si != sj {
			return keyLess(si, sj)
		}
		return keyLess(as[i].tgt.key(), as[j].tgt.key())
	})
	for _, a := range as {
		g.dealDamage(a.src, a.tgt, a.n)
	}
}
