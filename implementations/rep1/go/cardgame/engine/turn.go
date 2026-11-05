package engine

import (
	"cardgame/cards"
	"cardgame/match"
)

// Exec processes one parsed script command read from the given 1-based
// input line: an action is validated and applied (or rejected with an ERR
// line), a directive prints its block.
func (g *Game) Exec(cmd match.Cmd, line int) {
	switch cmd.Kind {
	case match.CmdDump:
		g.writeDump()
		return
	case match.CmdLegal:
		g.writeLegal()
		return
	case match.CmdVault:
		g.writeVault()
		return
	case match.CmdCard:
		g.writeCard(cmd.CardID)
		return
	}
	if kind := g.apply(&cmd); kind != "" {
		g.Reject(line, kind)
		return
	}
	switch g.cfg.Trace {
	case match.TraceLegal:
		g.writeLegal()
	case match.TraceState:
		g.writeDump()
	}
}

// Reject emits an ERR line. The driver uses it for unparsable lines.
func (g *Game) Reject(line int, kind string) {
	g.out.buf = append(g.out.buf, "ERR "...)
	g.out.buf = appendInt(g.out.buf, line)
	g.out.buf = append(g.out.buf, ' ')
	g.out.buf = append(g.out.buf, kind...)
	g.out.buf = append(g.out.buf, '\n')
}

func appendInt(b []byte, n int) []byte {
	if n == 0 {
		return append(b, '0')
	}
	var t [20]byte
	i := len(t)
	for n > 0 {
		i--
		t[i] = byte('0' + n%10)
		n /= 10
	}
	return append(b, t[i:]...)
}

// apply validates and performs an action, returning an error kind or "".
func (g *Game) apply(cmd *match.Cmd) string {
	if g.over {
		return errGameOver
	}
	p := Player(cmd.Player)
	if p != g.waiter {
		return errNotYourTurn
	}
	switch cmd.Kind {
	case match.CmdPass, match.CmdPlay, match.CmdAct:
		if g.dec != DecPriority {
			return errWrongDecision
		}
	case match.CmdAttack:
		if g.dec != DecAttackers {
			return errWrongDecision
		}
	case match.CmdBlock:
		if g.dec != DecBlockers {
			return errWrongDecision
		}
	}
	switch cmd.Kind {
	case match.CmdConcede:
		g.recordLoss(p, "concede")
		g.endMatch()
		return ""
	case match.CmdPass:
		g.out.begin("PASS")
		g.out.player(p).end()
		g.doPass()
	case match.CmdPlay:
		if k := g.execPlay(p, cmd); k != "" {
			return k
		}
		g.afterPriorityAction(p)
	case match.CmdAct:
		if k := g.execAct(p, cmd); k != "" {
			return k
		}
		g.afterPriorityAction(p)
	case match.CmdAttack:
		if k := g.execAttack(cmd); k != "" {
			return k
		}
	case match.CmdBlock:
		if k := g.execBlock(cmd); k != "" {
			return k
		}
	}
	if !g.over {
		g.advance()
	}
	return ""
}

func (g *Game) afterPriorityAction(p Player) {
	g.passCount = 0
	g.holder = p
	g.waiter = p
	if g.settle() {
		g.passCount = 0
		g.holder = g.active
		g.waiter = g.active
	}
	if g.over {
		g.dec = DecNone
	}
}

// doPass implements SPEC 10.3.
func (g *Game) doPass() {
	g.passCount++
	switch {
	case g.passCount == 1:
		g.holder = g.holder.Opp()
		g.waiter = g.holder
	case len(g.chain) > 0:
		g.passCount = 0
		g.resolveTop()
		g.settle()
		g.holder = g.active
		g.waiter = g.active
		if g.over {
			g.dec = DecNone
		}
	default:
		g.dec = DecNone
		g.step = g.afterRound
	}
}

// beginRound starts a priority round; next is the step to run when it ends.
func (g *Game) beginRound(next Step) {
	g.afterRound = next
	g.passCount = 0
	g.settle()
	if g.over {
		return
	}
	g.holder = g.active
	g.waiter = g.active
	g.dec = DecPriority
}

func (g *Game) phase(name string) {
	g.out.begin("PHASE")
	g.out.str(name).end()
}

func (g *Game) beginTurn() {
	g.out.begin("TURN")
	g.out.num(g.turn).player(g.active).end()
	g.step = StDawn
}

// drain implements SPEC 10.6.
func (g *Game) drain() {
	for {
		g.settle()
		if g.over || len(g.chain) == 0 {
			return
		}
		g.resolveTop()
	}
}

// advance runs rules processing forward until the next decision point or
// the end of the match.
func (g *Game) advance() {
	for !g.over && g.dec == DecNone {
		switch g.step {
		case StDawn:
			g.phase("dawn")
			g.doDawn()
			g.drain()
			g.step = StDraw
		case StDraw:
			g.phase("draw")
			if !(g.turn == 1 && g.active == g.first) {
				g.drawOne(g.active)
			}
			g.drain()
			g.step = StMain1
		case StMain1:
			g.phase("main1")
			g.beginRound(StAttackDecl)
		case StAttackDecl:
			g.phase("clash-attack")
			g.settle()
			if !g.over {
				g.dec, g.waiter = DecAttackers, g.active
			}
		case StBlockDecl:
			g.phase("clash-block")
			g.settle()
			if !g.over {
				g.dec, g.waiter = DecBlockers, g.active.Opp()
			}
		case StRiposte:
			if !g.anyRiposte() {
				g.step = StDamage
				continue
			}
			g.phase("clash-riposte")
			g.dealCombatDamage(true)
			g.beginRound(StDamage)
		case StDamage:
			g.phase("clash-damage")
			g.dealCombatDamage(false)
			g.beginRound(StClashEnd)
		case StClashEnd:
			g.phase("clash-end")
			g.derive()
			for _, id := range g.field {
				o := g.objs[id]
				if o.Card.Type == cards.Unit && (o.Attacking || o.Blocking) {
					g.collectFrom(id, cards.EvEndOfCombat, o.CurCtrl, Subject{SubjObj, id}, true)
				}
			}
			g.collectDelayed(cards.EndOfCombat, func(*Delayed) bool { return true })
			g.beginRound(StClashCleanup)
		case StClashCleanup:
			for _, id := range g.field {
				o := g.objs[id]
				o.Attacking, o.Blocking, o.Blocked, o.BlockedAtk = false, false, false, 0
				o.Blockers = o.Blockers[:0]
			}
			g.touch(cards.DepCombat)
			g.step = StMain2
		case StMain2:
			g.phase("main2")
			g.beginRound(StDuskTrigger)
		case StDuskTrigger:
			g.phase("dusk-trigger")
			g.derive()
			act := g.active
			for _, id := range g.field {
				c := g.objs[id].CurCtrl
				subj := Subject{SubjPlayer, int(act)}
				g.collectFrom(id, cards.EvTurnEnd, c, subj, true)
				if c == act {
					g.collectFrom(id, cards.EvYourTurnEnd, c, subj, true)
				}
			}
			g.collectDelayed(cards.TurnEnd, func(*Delayed) bool { return true })
			g.beginRound(StDuskDiscard)
		case StDuskDiscard:
			g.phase("dusk-discard")
			for len(g.pl[g.active].Hand) > g.cfg.HandMax {
				g.discardOne(g.active)
			}
			g.drain()
			g.step = StDuskCleanup
		case StDuskCleanup:
			g.phase("dusk-cleanup")
			g.cleanup()
			g.drain()
			if g.over {
				return
			}
			g.turn++
			g.active = g.active.Opp()
			g.touch(cards.DepTurn)
			if g.turn > g.cfg.TurnLimit {
				g.endDraw("turn-limit")
				return
			}
			g.beginTurn()
		}
	}
}

// doDawn performs the turn-based actions of SPEC 9.1 (after PHASE dawn).
func (g *Game) doDawn() {
	act := g.active
	ps := &g.pl[act]
	ps.Cap = min(ps.Cap+1, g.cfg.MaxCap)
	for p := Player(0); p < 2; p++ {
		g.pl[p].Ember = g.pl[p].Cap
		g.out.begin("EMBER")
		g.out.player(p).num(g.pl[p].Ember).num(g.pl[p].Cap).end()
	}
	g.touch(cards.DepEmber)
	g.derive()
	for _, id := range g.field {
		o := g.objs[id]
		if o.CurCtrl == act && o.Exhausted {
			g.setExhausted(id, false)
		}
	}
	for _, id := range g.field {
		o := g.objs[id]
		o.TenacityUsed = false
		o.Once = o.Once[:0]
	}
	subj := Subject{SubjPlayer, int(act)}
	for _, id := range g.field {
		c := g.objs[id].CurCtrl
		g.collectFrom(id, cards.EvTurnStart, c, subj, true)
		if c == act {
			g.collectFrom(id, cards.EvYourTurnStart, c, subj, true)
		}
	}
	g.collectDelayed(cards.YourNextTurnStart, func(d *Delayed) bool { return d.Ctrl == act })
}

// cleanup implements SPEC 9.7 (without the drain).
func (g *Game) cleanup() {
	for _, id := range g.field {
		o := g.objs[id]
		o.Wounds = 0
		o.Doomed = false
		o.Ward = 0
	}
	g.pl[A].Shield, g.pl[B].Shield = 0, 0
	k := 0
	for _, r := range g.records {
		if r.Aura {
			g.records[k] = r
			k++
			continue
		}
		if e := &r.Effs[0]; e.Kind == RControl {
			for _, id := range e.Affected {
				if g.objs[id].Zone == ZField {
					g.objs[id].Since = g.turn
				}
			}
		}
	}
	for i := k; i < len(g.records); i++ {
		g.records[i] = nil
	}
	g.records = g.records[:k]
	d := 0
	for _, x := range g.delayed {
		if x.When == cards.YourNextTurnStart {
			g.delayed[d] = x
			d++
		}
	}
	for i := d; i < len(g.delayed); i++ {
		g.delayed[i] = nil
	}
	g.delayed = g.delayed[:d]
	g.stale = true
}
