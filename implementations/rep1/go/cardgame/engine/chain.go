package engine

import (
	"sort"

	"cardgame/cards"
	"cardgame/match"
)

// validOid reports whether id names an existing object.
func (g *Game) validOid(id int) bool { return id > 0 && id < len(g.objs) }

// legalTarget reports whether t is a legal target for the specification
// (SPEC 12.1, 12.2). selfCid is the entry being announced or resolved.
func (g *Game) legalTarget(sp *cards.TargetSpec, t Target, c *ctx, selfCid int) bool {
	switch sp.Kind {
	case cards.TSPlayer:
		return t.Kind == TPlayer
	case cards.TSChained:
		if t.Kind != TChain || t.ID == selfCid {
			return false
		}
		for _, en := range g.chain {
			if en.Cid == t.ID {
				return true
			}
		}
		return false
	case cards.TSAshcard:
		return t.Kind == TObject && g.validOid(t.ID) && g.objs[t.ID].Zone == ZAsh &&
			g.filtersOK(sp.Filters, t.ID, c)
	case cards.TSAny:
		if t.Kind == TPlayer {
			return true
		}
		return g.legalUnit(sp, t, c)
	case cards.TSUnit:
		return g.legalUnit(sp, t, c)
	case cards.TSRelic:
		if t.Kind != TObject || !g.validOid(t.ID) {
			return false
		}
		o := g.objs[t.ID]
		return o.Zone == ZField && o.Card.Type == cards.Relic && g.filtersOK(sp.Filters, t.ID, c)
	}
	return false
}

func (g *Game) legalUnit(sp *cards.TargetSpec, t Target, c *ctx) bool {
	if t.Kind != TObject || !g.validOid(t.ID) {
		return false
	}
	o := g.objs[t.ID]
	if o.Zone != ZField || o.Card.Type != cards.Unit {
		return false
	}
	g.derive()
	if o.hasKw(cards.Spectral) && o.CurCtrl != c.ctrl {
		return false
	}
	return g.filtersOK(sp.Filters, t.ID, c)
}

// candidates lists the legal targets for one specification in ascending
// target-key order.
func (g *Game) candidates(sp *cards.TargetSpec, c *ctx, selfCid int) []Target {
	var out []Target
	switch sp.Kind {
	case cards.TSPlayer, cards.TSAny:
		out = append(out, Target{Kind: TPlayer, ID: 0}, Target{Kind: TPlayer, ID: 1})
		if sp.Kind == cards.TSPlayer {
			return out
		}
		fallthrough
	case cards.TSUnit, cards.TSRelic:
		g.derive()
		for _, id := range g.field {
			t := Target{Kind: TObject, ID: id}
			if g.legalTarget(sp, t, c, selfCid) {
				out = append(out, t)
			}
		}
	case cards.TSChained:
		ids := make([]int, 0, len(g.chain))
		for _, en := range g.chain {
			if en.Cid != selfCid {
				ids = append(ids, en.Cid)
			}
		}
		sort.Ints(ids)
		for _, id := range ids {
			out = append(out, Target{Kind: TChain, ID: id})
		}
	case cards.TSAshcard:
		var ids []int
		for p := Player(0); p < 2; p++ {
			for _, id := range g.pl[p].Ash {
				if g.filtersOK(sp.Filters, id, c) {
					ids = append(ids, id)
				}
			}
		}
		g.canonical(ids)
		for _, id := range ids {
			out = append(out, Target{Kind: TObject, ID: id})
		}
	}
	return out
}

func sameTarget(a, b Target) bool { return a.Kind == b.Kind && a.ID == b.ID }

// autoTargets picks, for each specification, the smallest-key legal
// candidate distinct from those already chosen (SPEC 13.4).
func (g *Game) autoTargets(specs []cards.TargetSpec, ctrl Player, source int) ([]Target, bool) {
	c := &ctx{ctrl: ctrl, source: source}
	var chosen []Target
	for i := range specs {
		found := false
		for _, cand := range g.candidates(&specs[i], c, 0) {
			dup := false
			for _, ch := range chosen {
				if sameTarget(ch, cand) {
					dup = true
					break
				}
			}
			if !dup {
				chosen = append(chosen, cand)
				found = true
				break
			}
		}
		if !found {
			return nil, false
		}
	}
	return chosen, true
}

// tuples enumerates every legal target tuple in lexicographic key order.
func (g *Game) tuples(specs []cards.TargetSpec, c *ctx) [][]Target {
	if len(specs) == 0 {
		return [][]Target{nil}
	}
	cands := make([][]Target, len(specs))
	for i := range specs {
		cands[i] = g.candidates(&specs[i], c, 0)
		if len(cands[i]) == 0 {
			return nil
		}
	}
	var out [][]Target
	cur := make([]Target, len(specs))
	var rec func(i int)
	rec = func(i int) {
		if i == len(specs) {
			out = append(out, append([]Target(nil), cur...))
			return
		}
		for _, cand := range cands[i] {
			dup := false
			for j := 0; j < i; j++ {
				if sameTarget(cur[j], cand) {
					dup = true
					break
				}
			}
			if dup {
				continue
			}
			cur[i] = cand
			rec(i + 1)
		}
	}
	rec(0)
	return out
}

func tokenTarget(t match.Token) Target {
	id := int(t.N)
	if t.N > 1<<40 {
		id = -1
	}
	switch t.Kind {
	case match.TokPlayer:
		return Target{Kind: TPlayer, ID: id}
	case match.TokObject:
		return Target{Kind: TObject, ID: id}
	}
	return Target{Kind: TChain, ID: id}
}

// checkTargets validates command tokens against the specifications.
func (g *Game) checkTargets(specs []cards.TargetSpec, toks []match.Token, c *ctx) ([]Target, bool) {
	ts := make([]Target, len(toks))
	for i, tk := range toks {
		ts[i] = tokenTarget(tk)
		for j := 0; j < i; j++ {
			if sameTarget(ts[j], ts[i]) {
				return nil, false
			}
		}
		if !g.legalTarget(&specs[i], ts[i], c, 0) {
			return nil, false
		}
	}
	return ts, true
}

// playCost computes the Ember cost of playing card for p (SPEC 11.2 step 4).
func (g *Game) playCost(p Player, card *cards.Card) int {
	g.derive()
	cost := int(card.Cost)
	for _, r := range g.records {
		if !r.Aura || r.Ctrl != p {
			continue
		}
		for i := range r.Effs {
			e := &r.Effs[i]
			if e.Kind != RCheaper || !e.Active {
				continue
			}
			ok := true
			for _, f := range e.CardF {
				switch f.Kind {
				case cards.FType:
					ok = card.Type == f.Type
				case cards.FTag:
					ok = card.HasTag(f.Tag)
				case cards.FCost:
					ok = f.Cmp.Test(card.Cost, f.N)
				}
				if !ok {
					break
				}
			}
			if ok {
				cost -= e.Cheaper
			}
		}
	}
	if cost < 0 {
		cost = 0
	}
	return cost
}

// canPlayNow implements the timing rules of SPEC 11.1 for a card.
func (g *Game) canPlayNow(p Player, card *cards.Card) bool {
	if g.dec != DecPriority || g.holder != p {
		return false
	}
	if card.Type == cards.Rite && card.HasKeyword(cards.Swift) {
		return true
	}
	return p == g.active && (g.step == StMain1 || g.step == StMain2) && len(g.chain) == 0
}

// execPlay handles an accepted-or-rejected PLAY; it returns an error kind or
// "" on success.
func (g *Game) execPlay(p Player, cmd *match.Cmd) string {
	hand := g.pl[p].Hand
	if cmd.Pos == 0 || cmd.Pos > uint64(len(hand)) {
		return errNoSuchCard
	}
	oid := hand[cmd.Pos-1]
	card := g.objs[oid].Card
	if !g.canPlayNow(p, card) {
		return errBadTiming
	}
	var specs []cards.TargetSpec
	if card.Type == cards.Rite {
		specs = card.Abilities[0].Targets
	}
	if len(cmd.Targets) != len(specs) {
		return errBadTargetCount
	}
	c := &ctx{ctrl: p, source: oid}
	targets, ok := g.checkTargets(specs, cmd.Targets, c)
	if !ok {
		return errIllegalTarget
	}
	cost := g.playCost(p, card)
	if g.pl[p].Ember < cost {
		return errCannotAfford
	}
	g.detach(oid)
	g.objs[oid].Zone = ZChain
	en := &Entry{Cid: g.nextCid, Kind: EKRite, Ctrl: p, Source: oid, Targets: targets, Specs: specs}
	g.nextCid++
	switch card.Type {
	case cards.Unit:
		en.Kind = EKUnit
	case cards.Relic:
		en.Kind = EKRelic
	}
	g.chain = append(g.chain, en)
	g.out.begin("PLAY")
	g.out.player(p).cid(en.Cid).obj(oid).str(card.ID)
	for _, t := range targets {
		g.out.target(t)
	}
	g.out.end()
	if cost > 0 {
		g.pl[p].Ember -= cost
		g.touch(cards.DepEmber)
		g.out.begin("PAY")
		g.out.player(p).str("ember").num(cost).end()
	}
	if card.Type == cards.Rite {
		subj := Subject{SubjObj, oid}
		g.collectControlled(cards.EvYouPlayRite, p, subj)
		g.collectControlled(cards.EvEnemyPlaysRite, p.Opp(), subj)
	}
	return ""
}

// costPayable reports whether every cost item can be paid (SPEC 11.3 step 4).
func (g *Game) costPayable(p Player, oid int, ab *cards.Ability, idx int) bool {
	o := g.objs[oid]
	g.derive()
	for _, it := range ab.Cost {
		switch it.Kind {
		case cards.CostEmber:
			if int64(g.pl[p].Ember) < it.N {
				return false
			}
		case cards.CostDiscard:
			if int64(len(g.pl[p].Hand)) < it.N {
				return false
			}
		case cards.CostExhaust:
			if o.Zone != ZField || o.Exhausted || (o.Since >= g.turn && !o.hasKw(cards.Vanguard)) {
				return false
			}
		case cards.CostSacself:
			if o.Zone != ZField {
				return false
			}
		case cards.CostCounters:
			if int64(o.Counters) < it.N {
				return false
			}
		case cards.CostOnce:
			for _, u := range o.Once {
				if u == idx {
					return false
				}
			}
		}
	}
	return true
}

func (g *Game) payCost(p Player, oid int, ab *cards.Ability, idx int) {
	o := g.objs[oid]
	for _, it := range ab.Cost {
		n := int(it.N)
		switch it.Kind {
		case cards.CostEmber:
			if n > 0 {
				g.pl[p].Ember -= n
				g.touch(cards.DepEmber)
				g.out.begin("PAY")
				g.out.player(p).str("ember").num(n).end()
			}
		case cards.CostSpire:
			if n > 0 {
				g.out.begin("PAY")
				g.out.player(p).str("spire").num(n).end()
				g.changeSpire(p, -n)
			}
		case cards.CostDiscard:
			for i := 0; i < n && len(g.pl[p].Hand) > 0; i++ {
				g.discardOne(p)
			}
		case cards.CostExhaust:
			g.setExhausted(oid, true)
		case cards.CostSacself:
			g.sacrificeObj(oid)
		case cards.CostCounters:
			if n > 0 && o.Zone == ZField {
				nv := max(0, o.Counters-n)
				if d := nv - o.Counters; d != 0 {
					o.Counters = nv
					g.stale = true
					g.out.begin("COUNTERS")
					g.out.obj(oid).signed(d).num(nv).end()
				}
			}
		case cards.CostOnce:
			o.Once = append(o.Once, idx)
		}
	}
}

// execAct handles an ACT command; it returns an error kind or "".
func (g *Game) execAct(p Player, cmd *match.Cmd) string {
	if cmd.Obj > 1<<40 || !g.onField(int(cmd.Obj)) || g.ctrlOf(int(cmd.Obj)) != p {
		return errNoSuchObject
	}
	oid := int(cmd.Obj)
	o := g.objs[oid]
	g.derive()
	if cmd.Index == 0 || cmd.Index > uint64(len(o.Card.Abilities)) {
		return errNoSuchAbility
	}
	idx := int(cmd.Index)
	ab := o.Card.Abilities[idx-1]
	if ab.Kind != cards.AbAct || o.Stripped {
		return errNoSuchAbility
	}
	if len(cmd.Targets) != len(ab.Targets) {
		return errBadTargetCount
	}
	c := &ctx{ctrl: p, source: oid}
	targets, ok := g.checkTargets(ab.Targets, cmd.Targets, c)
	if !ok {
		return errIllegalTarget
	}
	if !g.costPayable(p, oid, ab, idx) {
		return errCostUnpayable
	}
	en := &Entry{Cid: g.nextCid, Kind: EKAbility, Ctrl: p, Source: oid, Index: idx, Targets: targets, Specs: ab.Targets}
	g.nextCid++
	g.chain = append(g.chain, en)
	g.out.begin("ACTIVATE")
	g.out.player(p).cid(en.Cid).obj(oid).num(idx)
	for _, t := range targets {
		g.out.target(t)
	}
	g.out.end()
	g.payCost(p, oid, ab, idx)
	return ""
}

// resolveTop resolves the entry on top of the Chain (SPEC 11.6).
func (g *Game) resolveTop() {
	en := g.chain[len(g.chain)-1]
	g.out.begin("RESOLVE")
	g.out.cid(en.Cid).end()
	c := &ctx{ctrl: en.Ctrl, source: en.Source, subj: en.Subj, targets: en.Targets, specs: en.Specs}
	allRemoved := len(en.Targets) > 0
	for i := range en.Targets {
		t := &en.Targets[i]
		t.Removed = !g.legalTarget(&en.Specs[i], *t, c, en.Cid)
		if !t.Removed {
			allRemoved = false
		}
	}
	if allRemoved {
		g.out.begin("FIZZLE")
		g.out.cid(en.Cid).end()
	} else {
		switch en.Kind {
		case EKRite:
			g.exec(g.objs[en.Source].Card.Abilities[0].Effects, c)
		case EKUnit, EKRelic:
			g.enterField(en.Source, en.Ctrl)
		default:
			if en.Delayed != nil {
				g.exec(en.Delayed.Effects, c)
			} else {
				g.exec(g.objs[en.Source].Card.Abilities[en.Index-1].Effects, c)
			}
		}
	}
	for i, x := range g.chain {
		if x == en {
			g.chain = append(g.chain[:i], g.chain[i+1:]...)
			break
		}
	}
	if en.Kind == EKRite || (allRemoved && (en.Kind == EKUnit || en.Kind == EKRelic)) {
		g.attach(en.Source, ZAsh)
		g.out.begin("SPENT")
		g.out.obj(en.Source).str(g.objs[en.Source].Card.ID).end()
	}
}
