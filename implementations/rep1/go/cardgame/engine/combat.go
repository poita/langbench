package engine

import (
	"sort"

	"cardgame/cards"
	"cardgame/match"
)

// canAttack implements SPEC 19.2.
func (g *Game) canAttack(oid int) bool {
	if !g.validOid(oid) {
		return false
	}
	o := g.objs[oid]
	if o.Zone != ZField || o.Card.Type != cards.Unit {
		return false
	}
	g.derive()
	return o.CurCtrl == g.active && !o.Exhausted &&
		(o.Since < g.turn || o.hasKw(cards.Vanguard)) && !o.hasKw(cards.Shackled)
}

// canBlock implements SPEC 19.4 for one blocker/attacker pair.
func (g *Game) canBlock(b, a int) bool {
	if !g.validOid(b) || !g.validOid(a) {
		return false
	}
	bo, ao := g.objs[b], g.objs[a]
	if bo.Zone != ZField || bo.Card.Type != cards.Unit {
		return false
	}
	g.derive()
	if bo.CurCtrl != g.active.Opp() || bo.Exhausted || bo.hasKw(cards.Siegework) {
		return false
	}
	if ao.Zone != ZField || ao.Card.Type != cards.Unit || !ao.Attacking {
		return false
	}
	if ao.hasKw(cards.Ghostwalk) && !bo.hasKw(cards.Ghostwalk) && !bo.hasKw(cards.Skyhook) {
		return false
	}
	return true
}

// unitsByOid returns the Field units in ascending oid order.
func (g *Game) unitsByOid() []int {
	var out []int
	for _, id := range g.field {
		if g.objs[id].Card.Type == cards.Unit {
			out = append(out, id)
		}
	}
	sort.Ints(out)
	return out
}

func (g *Game) execAttack(cmd *match.Cmd) string {
	seen := map[uint64]bool{}
	for _, o := range cmd.Objs {
		if seen[o] {
			return errDuplicateAttacker
		}
		seen[o] = true
	}
	for _, o := range cmd.Objs {
		if o > 1<<40 || !g.canAttack(int(o)) {
			return errIllegalAttacker
		}
	}
	for _, id := range g.unitsByOid() {
		if g.canAttack(id) && g.objs[id].hasKw(cards.Relentless) && !seen[uint64(id)] {
			return errMissingAttacker
		}
	}
	g.dec = DecNone
	if len(cmd.Objs) == 0 {
		g.step = StMain2
		return ""
	}
	ids := make([]int, len(cmd.Objs))
	for i, o := range cmd.Objs {
		ids[i] = int(o)
	}
	sort.Ints(ids)
	for _, id := range ids {
		o := g.objs[id]
		o.Attacking = true
		g.touch(cards.DepCombat)
		if !o.hasKw(cards.Vigil) {
			g.setExhausted(id, true)
		}
		g.out.begin("ATTACK")
		g.out.obj(id).end()
	}
	for _, id := range ids {
		g.collectSelf(id, cards.EvAttacks, Subject{SubjObj, id}, true)
	}
	g.step = StAttackRound
	g.beginRound(StBlockDecl)
	return ""
}

func (g *Game) execBlock(cmd *match.Cmd) string {
	seen := map[uint64]bool{}
	for _, pr := range cmd.Pairs {
		if seen[pr.Blocker] {
			return errDuplicateBlocker
		}
		seen[pr.Blocker] = true
	}
	for _, pr := range cmd.Pairs {
		if pr.Blocker > 1<<40 || pr.Attacker > 1<<40 || !g.canBlock(int(pr.Blocker), int(pr.Attacker)) {
			return errIllegalBlocker
		}
	}
	blocked := map[uint64]bool{}
	for _, pr := range cmd.Pairs {
		blocked[pr.Attacker] = true
	}
	for _, a := range g.unitsByOid() {
		ao := g.objs[a]
		if !ao.Attacking || !ao.hasKw(cards.Provoke) || blocked[uint64(a)] {
			continue
		}
		for _, b := range g.unitsByOid() {
			if !seen[uint64(b)] && g.canBlock(b, a) {
				return errMissingRequiredBlk
			}
		}
	}
	g.dec = DecNone
	pairs := append([]match.Pair(nil), cmd.Pairs...)
	sort.Slice(pairs, func(i, j int) bool { return pairs[i].Blocker < pairs[j].Blocker })
	for _, pr := range pairs {
		b, a := int(pr.Blocker), int(pr.Attacker)
		bo, ao := g.objs[b], g.objs[a]
		bo.Blocking = true
		bo.BlockedAtk = a
		ao.Blockers = append(ao.Blockers, b)
		ao.Blocked = true
		g.out.begin("BLOCK")
		g.out.obj(b).obj(a).end()
	}
	g.touch(cards.DepCombat)
	attackers := []int{}
	for _, id := range g.unitsByOid() {
		if o := g.objs[id]; o.Attacking {
			g.canonical(o.Blockers)
			attackers = append(attackers, id)
		}
	}
	for _, id := range attackers {
		if len(g.objs[id].Blockers) == 0 {
			g.out.begin("UNBLOCKED")
			g.out.obj(id).end()
		}
	}
	for _, pr := range pairs {
		g.collectSelf(int(pr.Blocker), cards.EvBlocks, Subject{SubjObj, int(pr.Attacker)}, true)
	}
	for _, id := range attackers {
		if bl := g.objs[id].Blockers; len(bl) > 0 {
			g.collectSelf(id, cards.EvBlocked, Subject{SubjObj, bl[0]}, true)
		}
	}
	for _, id := range attackers {
		if len(g.objs[id].Blockers) == 0 {
			g.collectSelf(id, cards.EvUnblocked, Subject{SubjObj, id}, true)
		}
	}
	g.step = StBlockRound
	g.beginRound(StRiposte)
	return ""
}

func (g *Game) inCombat(id int) bool {
	o := g.objs[id]
	return o.Zone == ZField && (o.Attacking || o.Blocking)
}

func (g *Game) anyRiposte() bool {
	g.derive()
	for _, id := range g.field {
		if g.inCombat(id) && g.objs[id].hasKw(cards.Riposte) {
			return true
		}
	}
	return false
}

type assignment struct {
	src int
	tgt Target
	amt int
}

// dealCombatDamage deals the combat damage of the riposte sub-step (when
// riposte is true) or of the main damage sub-step (SPEC 19.5, 19.6).
func (g *Game) dealCombatDamage(riposte bool) {
	g.derive()
	var dealers []int
	for _, id := range g.field {
		if !g.inCombat(id) {
			continue
		}
		if riposte {
			if g.objs[id].hasKw(cards.Riposte) {
				dealers = append(dealers, id)
			}
		} else if !containsInt(g.riposters, id) {
			dealers = append(dealers, id)
		}
	}
	if riposte {
		g.riposters = append(g.riposters[:0], dealers...)
	} else {
		g.riposters = g.riposters[:0]
	}
	defender := g.active.Opp()
	var all []assignment
	for _, id := range dealers {
		o := g.objs[id]
		e := o.Edge
		if e <= 0 {
			continue
		}
		switch {
		case o.Blocking:
			all = append(all, assignment{id, Target{Kind: TObject, ID: o.BlockedAtk}, e})
		case o.Attacking && !o.Blocked:
			all = append(all, assignment{id, Target{Kind: TPlayer, ID: int(defender)}, e})
		case o.Attacking:
			var live []int
			for _, b := range o.Blockers {
				if g.objs[b].Zone == ZField && g.objs[b].Blocking && g.objs[b].BlockedAtk == id {
					live = append(live, b)
				}
			}
			if len(live) == 0 {
				continue
			}
			r := e
			venom := o.hasKw(cards.Venom)
			amts := make([]int, len(live))
			for i, b := range live {
				need := 1
				if !venom {
					need = max(0, g.objs[b].Core-g.objs[b].Wounds)
				}
				amts[i] = min(r, need)
				r -= amts[i]
			}
			var toPlayer int
			if r > 0 {
				if o.hasKw(cards.Pierce) {
					toPlayer = r
				} else {
					amts[len(amts)-1] += r
				}
			}
			if toPlayer > 0 {
				all = append(all, assignment{id, Target{Kind: TPlayer, ID: int(defender)}, toPlayer})
			}
			for i, b := range live {
				if amts[i] > 0 {
					all = append(all, assignment{id, Target{Kind: TObject, ID: b}, amts[i]})
				}
			}
		}
	}
	for _, a := range all {
		g.dealDamage(a.src, a.tgt, a.amt)
	}
}

func containsInt(s []int, v int) bool {
	for _, x := range s {
		if x == v {
			return true
		}
	}
	return false
}
