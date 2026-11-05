package engine

import "cardgame/cards"

// ctx is the evaluation context of an ability: who controls it, which
// object it is printed on, its targets and trigger subject, and the object
// bound by the innermost `each`.
type ctx struct {
	ctrl    Player
	source  int
	subj    Subject
	targets []Target
	specs   []cards.TargetSpec
	that    int
	hasThat bool
	aura    bool // inside an aura: edge/core amounts use base values
}

// baseEdge and baseCore are printed values plus charge counters (SPEC 6.2).
func (g *Game) baseEdge(oid int) int {
	o := g.objs[oid]
	return int(o.Card.Edge) + o.Counters
}

func (g *Game) baseCore(oid int) int {
	o := g.objs[oid]
	return int(o.Card.Core) + o.Counters
}

// curEdge and curCore are the values the game rules use.
func (g *Game) curEdge(oid int) int {
	o := g.objs[oid]
	if o.Zone != ZField {
		return int(o.Card.Edge)
	}
	g.derive()
	return o.Edge
}

func (g *Game) curCore(oid int) int {
	o := g.objs[oid]
	if o.Zone != ZField {
		return int(o.Card.Core)
	}
	g.derive()
	return o.Core
}

// holder of an object for scope and (mine)/(enemy) purposes: controller on
// the Field, owner elsewhere.
func (g *Game) scopeOwner(oid int) Player {
	o := g.objs[oid]
	if o.Zone == ZField {
		g.derive()
		return o.CurCtrl
	}
	return o.Owner
}

func (g *Game) filterOK(f *cards.Filter, oid int, c *ctx) bool {
	o := g.objs[oid]
	switch f.Kind {
	case cards.FKw:
		return o.Card.HasKeyword(f.Kw)
	case cards.FNoKw:
		return !o.Card.HasKeyword(f.Kw)
	case cards.FTag:
		return o.Card.HasTag(f.Tag)
	case cards.FType:
		return o.Card.Type == f.Type
	case cards.FCost:
		return f.Cmp.Test(o.Card.Cost, f.N)
	case cards.FEdge:
		return f.Cmp.Test(int64(g.baseEdge(oid)), f.N)
	case cards.FCore:
		return f.Cmp.Test(int64(g.baseCore(oid)), f.N)
	case cards.FWounded:
		return o.Zone == ZField && o.Wounds > 0
	case cards.FReady:
		return o.Zone == ZField && !o.Exhausted
	case cards.FExhausted:
		return o.Zone == ZField && o.Exhausted
	case cards.FSettling:
		return o.Zone == ZField && o.Since >= g.turn
	case cards.FAttacking:
		return o.Zone == ZField && o.Attacking
	case cards.FBlocking:
		return o.Zone == ZField && o.Blocking
	case cards.FMine:
		return g.scopeOwner(oid) == c.ctrl
	case cards.FEnemy:
		return g.scopeOwner(oid) != c.ctrl
	case cards.FOther:
		return oid != c.source
	case cards.FNot:
		return !g.filterOK(f.Inner, oid, c)
	}
	return false
}

func (g *Game) filtersOK(fs []cards.Filter, oid int, c *ctx) bool {
	for i := range fs {
		if !g.filterOK(&fs[i], oid, c) {
			return false
		}
	}
	return true
}

func scopeOK(s cards.Scope, who, ctrl Player) bool {
	switch s {
	case cards.Yours:
		return who == ctrl
	case cards.Theirs:
		return who != ctrl
	}
	return true
}

// fieldMatches appends the Field objects of the given type that satisfy the
// scope and filters, in canonical order.
func (g *Game) fieldMatches(typ cards.Type, scope cards.Scope, fs []cards.Filter, c *ctx, out []int) []int {
	if !c.aura {
		g.derive()
	}
	for _, id := range g.field {
		o := g.objs[id]
		if o.Card.Type != typ || !scopeOK(scope, o.CurCtrl, c.ctrl) {
			continue
		}
		if g.filtersOK(fs, id, c) {
			out = append(out, id)
		}
	}
	return out
}

// selObjs evaluates an object selector, appending to out. Results are in
// canonical object order.
func (g *Game) selObjs(s *cards.Sel, c *ctx, out []int) []int {
	switch s.Kind {
	case cards.SelSelf:
		return append(out, c.source)
	case cards.SelIt:
		if c.subj.Kind == SubjObj {
			out = append(out, c.subj.ID)
		}
	case cards.SelThat:
		if c.hasThat {
			out = append(out, c.that)
		}
	case cards.SelT:
		if s.N <= len(c.targets) {
			t := c.targets[s.N-1]
			if t.Kind == TObject && !t.Removed {
				out = append(out, t.ID)
			}
		}
	case cards.SelUnits:
		out = g.fieldMatches(cards.Unit, s.Scope, s.Filters, c, out)
	case cards.SelRelics:
		out = g.fieldMatches(cards.Relic, s.Scope, s.Filters, c, out)
	case cards.SelRandomUnit:
		list := g.fieldMatches(cards.Unit, s.Scope, s.Filters, c, nil)
		if len(list) > 0 {
			out = append(out, list[g.rnd.Below(uint64(len(list)))])
		}
	case cards.SelCards:
		start := len(out)
		for p := Player(0); p < 2; p++ {
			if !scopeOK(s.Scope, p, c.ctrl) {
				continue
			}
			var zone []int
			switch s.Zone {
			case cards.ZoneHand:
				zone = g.pl[p].Hand
			case cards.ZoneAsh:
				zone = g.pl[p].Ash
			case cards.ZoneVault:
				zone = g.pl[p].Vault
			default:
				zone = g.pl[p].Rift
			}
			for _, id := range zone {
				if g.filtersOK(s.Filters, id, c) {
					out = append(out, id)
				}
			}
		}
		g.canonical(out[start:])
	}
	return out
}

// selPlayers evaluates a player selector.
func (g *Game) selPlayers(s *cards.Sel, c *ctx) []Player {
	switch s.Kind {
	case cards.SelYou:
		return []Player{c.ctrl}
	case cards.SelFoe:
		return []Player{c.ctrl.Opp()}
	case cards.SelBoth:
		return []Player{A, B}
	case cards.SelT:
		if s.N <= len(c.targets) {
			t := c.targets[s.N-1]
			if t.Kind == TPlayer && !t.Removed {
				return []Player{Player(t.ID)}
			}
		}
	case cards.SelOwnerOf:
		in := s.Inner
		if in.Kind == cards.SelT && in.N <= len(c.targets) {
			if t := c.targets[in.N-1]; t.Kind == TPlayer {
				if t.Removed {
					return nil
				}
				return []Player{Player(t.ID)}
			}
		}
		var seen [2]bool
		for _, id := range g.selObjs(in, c, nil) {
			seen[g.objs[id].Owner] = true
		}
		var out []Player
		for p := Player(0); p < 2; p++ {
			if seen[p] {
				out = append(out, p)
			}
		}
		return out
	}
	return nil
}

// dmgTargets evaluates a damage selector: players first, then objects, in
// ascending target-key order.
func (g *Game) dmgTargets(s *cards.Sel, c *ctx) []Target {
	var out []Target
	switch s.Kind {
	case cards.SelYou, cards.SelFoe, cards.SelBoth, cards.SelOwnerOf:
		for _, p := range g.selPlayers(s, c) {
			out = append(out, Target{Kind: TPlayer, ID: int(p)})
		}
		return out
	case cards.SelT:
		if s.N <= len(c.targets) {
			t := c.targets[s.N-1]
			if !t.Removed && t.Kind != TChain {
				out = append(out, Target{Kind: t.Kind, ID: t.ID})
			}
		}
		return out
	}
	for _, id := range g.selObjs(s, c, nil) {
		out = append(out, Target{Kind: TObject, ID: id})
	}
	return out
}

func (g *Game) playerSum(s *cards.Sel, c *ctx, f func(*playerState) int) int {
	sum := 0
	for _, p := range g.selPlayers(s, c) {
		sum += f(&g.pl[p])
	}
	return sum
}

func (g *Game) amount(a *cards.Amount, c *ctx) int {
	switch a.Kind {
	case cards.AmtConst:
		return int(a.N)
	case cards.AmtCount:
		return len(g.selObjs(a.Sel, c, nil))
	case cards.AmtHand:
		return g.playerSum(a.Sel, c, func(p *playerState) int { return len(p.Hand) })
	case cards.AmtAsh:
		return g.playerSum(a.Sel, c, func(p *playerState) int { return len(p.Ash) })
	case cards.AmtVault:
		return g.playerSum(a.Sel, c, func(p *playerState) int { return len(p.Vault) })
	case cards.AmtEdge, cards.AmtCore:
		sum := 0
		for _, id := range g.selObjs(a.Sel, c, nil) {
			switch {
			case c.aura && a.Kind == cards.AmtEdge:
				sum += g.baseEdge(id)
			case c.aura:
				sum += g.baseCore(id)
			case a.Kind == cards.AmtEdge:
				sum += g.curEdge(id)
			default:
				sum += g.curCore(id)
			}
		}
		return sum
	case cards.AmtWounds:
		sum := 0
		for _, id := range g.selObjs(a.Sel, c, nil) {
			if g.objs[id].Zone == ZField {
				sum += g.objs[id].Wounds
			}
		}
		return sum
	}
	return 0
}

func (g *Game) cond(cd *cards.Cond, c *ctx) bool {
	switch cd.Kind {
	case cards.CondCount:
		return cd.Cmp.Test(int64(len(g.selObjs(cd.Sel, c, nil))), cd.N)
	case cards.CondSpire:
		return cd.Cmp.Test(int64(g.playerSum(cd.Sel, c, func(p *playerState) int { return p.Spire })), cd.N)
	case cards.CondHand:
		return cd.Cmp.Test(int64(g.playerSum(cd.Sel, c, func(p *playerState) int { return len(p.Hand) })), cd.N)
	case cards.CondAsh:
		return cd.Cmp.Test(int64(g.playerSum(cd.Sel, c, func(p *playerState) int { return len(p.Ash) })), cd.N)
	case cards.CondVault:
		return cd.Cmp.Test(int64(g.playerSum(cd.Sel, c, func(p *playerState) int { return len(p.Vault) })), cd.N)
	case cards.CondEmber:
		return cd.Cmp.Test(int64(g.playerSum(cd.Sel, c, func(p *playerState) int { return p.Ember })), cd.N)
	case cards.CondMyTurn:
		return g.active == c.ctrl
	case cards.CondAnd:
		for _, s := range cd.Subs {
			if !g.cond(s, c) {
				return false
			}
		}
		return true
	case cards.CondOr:
		for _, s := range cd.Subs {
			if g.cond(s, c) {
				return true
			}
		}
		return false
	case cards.CondNot:
		return !g.cond(cd.Subs[0], c)
	}
	return false
}
