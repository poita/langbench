package engine

import (
	"sort"

	"github.com/spiremark/cardgame/cards"
)

// ActionKind identifies a player action.
type ActionKind int

// Action kinds.
const (
	ActPass ActionKind = iota
	ActConcede
	ActPlay
	ActAct
	ActAttack
	ActBlock
)

// RefKind says what a TargetRef names.
type RefKind int

// Target reference kinds.
const (
	RefPlayer RefKind = iota
	RefObject
	RefEntry
)

// TargetRef names a target as written in a script: a player, an object id
// or a Chain entry id.
type TargetRef struct {
	Kind   RefKind
	Player Player
	ID     uint64
}

// BlockPair is one blocker:attacker assignment.
type BlockPair struct{ Blocker, Attacker uint64 }

// Action is a player action. Only the fields relevant to Kind are used.
type Action struct {
	Kind      ActionKind
	Player    Player
	Pos       uint64 // PLAY: 1-based hand position
	Object    uint64 // ACT: object id
	Index     uint64 // ACT: 1-based ability number
	Targets   []TargetRef
	Attackers []uint64
	Blocks    []BlockPair
}

// ActionError is returned by Do for a rejected action. Kind is the ERR token
// of SPEC section 24, for example "bad-timing".
type ActionError struct{ Kind string }

func (e *ActionError) Error() string { return e.Kind }

func reject(kind string) error { return &ActionError{kind} }

// Do submits an action. A rejected action changes nothing and returns an
// *ActionError; an accepted one is processed and the engine runs forward to
// the next decision point (or the end of the match).
func (g *Game) Do(a Action) error {
	if g.over {
		return reject("game-over")
	}
	if a.Player != g.decPlayer {
		return reject("not-your-turn")
	}
	want := DecPriority
	switch a.Kind {
	case ActAttack:
		want = DecAttackers
	case ActBlock:
		want = DecBlockers
	case ActConcede:
		want = g.decKind
	}
	if g.decKind != want {
		return reject("wrong-decision")
	}
	var err error
	switch a.Kind {
	case ActConcede:
		g.concede(a.Player)
	case ActPass:
		g.doPass(a.Player)
	case ActPlay:
		err = g.doPlay(a)
	case ActAct:
		err = g.doAct(a)
	case ActAttack:
		err = g.doAttack(a)
	case ActBlock:
		err = g.doBlock(a)
	}
	if err != nil {
		return err
	}
	g.advance()
	return nil
}

func (g *Game) doPass(p Player) {
	g.emit("PASS", p.String())
	g.passes++
	if g.passes == 1 {
		g.decPlayer = p.Opp()
		return
	}
	if len(g.chain) == 0 {
		g.decKind = DecNone
		return
	}
	g.passes = 0
	g.resolveTop()
	g.settle()
	if g.over {
		return
	}
	g.decPlayer = g.active
}

// afterEntryAction hands priority back after a PLAY or ACT.
func (g *Game) afterEntryAction(p Player) {
	g.passes = 0
	g.decPlayer = p
	if g.settle() && !g.over {
		g.passes = 0
		g.decPlayer = g.active
	}
}

// resolveRefs converts script target references into targets, reporting
// whether every reference names something that exists.
func (g *Game) resolveRefs(refs []TargetRef) ([]target, bool) {
	out := make([]target, 0, len(refs))
	for _, r := range refs {
		switch r.Kind {
		case RefPlayer:
			out = append(out, playerTarget(r.Player))
		case RefObject:
			o := g.Lookup(clampID(r.ID))
			if o == nil {
				return nil, false
			}
			out = append(out, objTarget(o))
		case RefEntry:
			var found *entry
			for _, e := range g.chain {
				if uint64(e.cid) == r.ID {
					found = e
				}
			}
			if found == nil {
				return nil, false
			}
			out = append(out, target{kind: tEntry, e: found})
		}
	}
	return out, true
}

func clampID(id uint64) int {
	if id > 1<<40 {
		return 0
	}
	return int(id)
}

// checkTargets implements the bad-target-count and illegal-target checks.
func (g *Game) checkTargets(specs []cards.TargetSpec, refs []TargetRef, c *ctx) ([]target, error) {
	if len(refs) != len(specs) {
		return nil, reject("bad-target-count")
	}
	ts, ok := g.resolveRefs(refs)
	if !ok {
		return nil, reject("illegal-target")
	}
	for i := range ts {
		for j := 0; j < i; j++ {
			if ts[i].same(ts[j]) {
				return nil, reject("illegal-target")
			}
		}
		if !g.targetLegal(&specs[i], ts[i], c, nil) {
			return nil, reject("illegal-target")
		}
	}
	return ts, nil
}

func (g *Game) playTiming(p Player, o *Obj) bool {
	if o.Card.Type == cards.Rite && o.Card.HasPrinted(cards.Swift) {
		return true
	}
	return g.active == p && (g.phase == "main1" || g.phase == "main2") && len(g.chain) == 0
}

func resolveSpecs(card *cards.Card) []cards.TargetSpec {
	if card.Type == cards.Rite && len(card.Abilities) > 0 && card.Abilities[0].Kind == cards.AbResolve {
		return card.Abilities[0].Targets
	}
	return nil
}

func (g *Game) doPlay(a Action) error {
	p := a.Player
	hand := g.pl[p].hand
	if a.Pos == 0 || a.Pos > uint64(len(hand)) {
		return reject("no-such-card")
	}
	o := hand[a.Pos-1]
	if !g.playTiming(p, o) {
		return reject("bad-timing")
	}
	specs := resolveSpecs(o.Card)
	ts, err := g.checkTargets(specs, a.Targets, &ctx{ctrl: p, src: o})
	if err != nil {
		return err
	}
	cost := g.playCost(p, o.Card)
	if g.pl[p].ember < cost {
		return reject("cannot-afford")
	}
	g.detach(o)
	o.zone = ZChain
	kind := entRite
	switch o.Card.Type {
	case cards.Unit:
		kind = entUnit
	case cards.Relic:
		kind = entRelic
	}
	e := &entry{cid: g.nextCID, kind: kind, ctrl: p, src: o, targets: ts, specs: specs, onChain: true}
	g.nextCID++
	g.chain = append(g.chain, e)
	f := []string{p.String(), "~" + itoa(e.cid), oidS(o), o.Card.ID}
	for _, t := range ts {
		f = append(f, t.render())
	}
	g.emit("PLAY", f...)
	if cost > 0 {
		g.pl[p].ember -= cost
		g.touch()
		g.emit("PAY", p.String(), "ember", itoa(cost))
	}
	if kind == entRite {
		g.collectPlayRite(p, o)
	}
	g.afterEntryAction(p)
	return nil
}

func (g *Game) costPayable(p Player, o *Obj, idx int, ci cards.CostItem) bool {
	switch ci.Kind {
	case cards.CostEmber:
		return g.pl[p].ember >= ci.N
	case cards.CostSpire:
		return true
	case cards.CostDiscard:
		return len(g.pl[p].hand) >= ci.N
	case cards.CostExhaust:
		return o.zone == ZField && o.ready && (!g.settling(o) || g.hasKW(o, cards.Vanguard))
	case cards.CostSacself:
		return o.zone == ZField
	case cards.CostCounters:
		return o.counters >= ci.N
	case cards.CostOnce:
		for _, i := range o.once {
			if i == idx {
				return false
			}
		}
		return true
	}
	return false
}

func (g *Game) allCostsPayable(p Player, o *Obj, ab *cards.Ability) bool {
	for _, ci := range ab.Cost {
		if !g.costPayable(p, o, ab.Index, ci) {
			return false
		}
	}
	return true
}

func (g *Game) payCost(p Player, o *Obj, idx int, ci cards.CostItem) {
	switch ci.Kind {
	case cards.CostEmber:
		if ci.N > 0 {
			g.pl[p].ember -= ci.N
			g.touch()
			g.emit("PAY", p.String(), "ember", itoa(ci.N))
		}
	case cards.CostSpire:
		if ci.N > 0 {
			g.emit("PAY", p.String(), "spire", itoa(ci.N))
			g.changeSpire(p, -ci.N)
		}
	case cards.CostDiscard:
		for i := 0; i < ci.N; i++ {
			g.discardOne(p)
		}
	case cards.CostExhaust:
		g.setReady(o, false)
	case cards.CostSacself:
		g.sacrifice(o)
	case cards.CostCounters:
		g.addCounters(o, -ci.N)
	case cards.CostOnce:
		o.once = append(o.once, idx)
	}
}

func (g *Game) doAct(a Action) error {
	p := a.Player
	o := g.Lookup(clampID(a.Object))
	if o == nil || o.zone != ZField || g.ctrlOf(o) != p {
		return reject("no-such-object")
	}
	var ab *cards.Ability
	if a.Index <= uint64(len(o.Card.Abilities)) {
		ab = o.Card.Ability(int(a.Index))
	}
	if ab == nil || ab.Kind != cards.AbAct || g.strippedOf(o) {
		return reject("no-such-ability")
	}
	ts, err := g.checkTargets(ab.Targets, a.Targets, &ctx{ctrl: p, src: o})
	if err != nil {
		return err
	}
	if !g.allCostsPayable(p, o, ab) {
		return reject("cost-unpayable")
	}
	e := &entry{cid: g.nextCID, kind: entAbility, ctrl: p, src: o, idx: ab.Index, targets: ts, specs: ab.Targets, onChain: true}
	g.nextCID++
	g.chain = append(g.chain, e)
	f := []string{p.String(), "~" + itoa(e.cid), oidS(o), itoa(ab.Index)}
	for _, t := range ts {
		f = append(f, t.render())
	}
	g.emit("ACTIVATE", f...)
	for _, ci := range ab.Cost {
		g.payCost(p, o, ab.Index, ci)
	}
	g.afterEntryAction(p)
	return nil
}

func (g *Game) doAttack(a Action) error {
	ids := a.Attackers
	seen := map[uint64]bool{}
	for _, id := range ids {
		if seen[id] {
			return reject("duplicate-attacker")
		}
		seen[id] = true
	}
	var objs []*Obj
	for _, id := range ids {
		o := g.Lookup(clampID(id))
		if !g.canAttack(o) {
			return reject("illegal-attacker")
		}
		objs = append(objs, o)
	}
	g.ensure()
	for _, o := range g.field {
		if g.canAttack(o) && g.hasKW(o, cards.Relentless) && !seen[uint64(o.OID)] {
			return reject("missing-required-attacker")
		}
	}
	g.decKind = DecNone
	if len(objs) == 0 {
		g.step = sMain2
		return nil
	}
	sort.Slice(objs, func(i, j int) bool { return objs[i].OID < objs[j].OID })
	for _, o := range objs {
		o.attacking = true
		g.touch()
		if !g.hasKW(o, cards.Vigil) {
			g.setReady(o, false)
		}
		g.emit("ATTACK", oidS(o))
	}
	for _, o := range objs {
		g.fireOwn(cards.EvAttacks, o, objTarget(o))
	}
	g.startRound(sClashBlock)
	return nil
}

func (g *Game) doBlock(a Action) error {
	seen := map[uint64]bool{}
	for _, bp := range a.Blocks {
		if seen[bp.Blocker] {
			return reject("duplicate-blocker")
		}
		seen[bp.Blocker] = true
	}
	type pair struct{ b, a *Obj }
	var pairs []pair
	for _, bp := range a.Blocks {
		b, at := g.Lookup(clampID(bp.Blocker)), g.Lookup(clampID(bp.Attacker))
		if !g.canBlock(b, at) {
			return reject("illegal-blocker")
		}
		pairs = append(pairs, pair{b, at})
	}
	// Provoke (19.4).
	blocked := map[*Obj]bool{}
	for _, pr := range pairs {
		blocked[pr.a] = true
	}
	g.ensure()
	for _, at := range g.field {
		if !at.attacking || blocked[at] || !g.hasKW(at, cards.Provoke) {
			continue
		}
		for _, b := range g.field {
			if !seen[uint64(b.OID)] && g.canBlock(b, at) {
				return reject("missing-required-block")
			}
		}
	}
	g.decKind = DecNone
	sort.Slice(pairs, func(i, j int) bool { return pairs[i].b.OID < pairs[j].b.OID })
	for _, pr := range pairs {
		pr.b.blocking, pr.b.blocks = true, pr.a
		pr.a.blockers = append(pr.a.blockers, pr.b)
		pr.a.blocked = true
		g.emit("BLOCK", oidS(pr.b), oidS(pr.a))
	}
	g.touch()
	var attackers []*Obj
	for _, o := range g.field {
		if o.attacking {
			sortObjs(o.blockers)
			attackers = append(attackers, o)
		}
	}
	sort.Slice(attackers, func(i, j int) bool { return attackers[i].OID < attackers[j].OID })
	var unblocked []*Obj
	for _, o := range attackers {
		if len(o.blockers) == 0 {
			unblocked = append(unblocked, o)
			g.emit("UNBLOCKED", oidS(o))
		}
	}
	for _, pr := range pairs {
		g.fireOwn(cards.EvBlocks, pr.b, objTarget(pr.a))
	}
	for _, o := range attackers {
		if o.blocked && len(o.blockers) > 0 {
			g.fireOwn(cards.EvBlocked, o, objTarget(o.blockers[0]))
		}
	}
	for _, o := range unblocked {
		g.fireOwn(cards.EvUnblocked, o, objTarget(o))
	}
	g.startRound(sRiposte)
	return nil
}
