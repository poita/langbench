// Package engine implements the Spiremark rules engine.
//
// A Game is created from a validated card database and a parsed setup block.
// It simulates the match as a resumable state machine: after New and after
// every accepted action it runs rules processing forward until the next
// decision point (priority, attackers or blockers) or until the match ends.
// All output — one line per rules event plus the inspection blocks and ERR
// lines — accumulates in an internal buffer.
package engine

import (
	"errors"
	"io"
	"sort"

	"cardgame/cards"
	"cardgame/match"
	"cardgame/rng"
)

// ErrUnknownCard is returned by New when a setup zone line names a card the
// database does not define.
var ErrUnknownCard = errors.New("engine: unknown card")

// Game is one Spiremark match in progress.
type Game struct {
	db  *cards.DB
	cfg *match.Setup
	out log
	rnd *rng.Rand

	objs  []*Obj // indexed by oid; objs[0] is unused
	field []int  // Field objects in canonical (timestamp, oid) order
	pl    [2]playerState

	records []*Record
	delayed []*Delayed
	chain   []*Entry // bottom first
	pending []Pending

	nextTS, nextEid, nextCid int

	// Turn state.
	turn   int
	active Player
	first  Player
	step   Step

	// Decision state.
	dec        DecisionKind
	waiter     Player
	holder     Player
	passCount  int
	afterRound Step

	// Combat bookkeeping.
	riposters []int

	// Result.
	over       bool
	lost       [2]bool
	lossReason [2]string
	winner     string
	resReason  string

	// Derivation cache.
	stale    bool
	liveDeps cards.Dep

	noTriggers bool
}

// New validates the setup against the database, builds the initial state,
// runs the setup procedure of SPEC section 8 and stops at the first decision
// point. It emits nothing and returns ErrUnknownCard if a zone line names an
// undefined card.
func New(db *cards.DB, cfg *match.Setup) (*Game, error) {
	for p := 0; p < 2; p++ {
		for z := 0; z < match.NumSetupZones; z++ {
			for _, e := range cfg.Zones[p][z] {
				if db.Card(e.CardID) == nil {
					return nil, ErrUnknownCard
				}
			}
		}
	}
	g := &Game{
		db: db, cfg: cfg,
		objs:   make([]*Obj, 1, 64),
		nextTS: 1, nextEid: 1, nextCid: 1,
		turn: 1, first: Player(cfg.First), stale: true,
	}
	g.active = g.first
	g.step = StDawn
	for p := Player(0); p < 2; p++ {
		g.pl[p] = playerState{Spire: int(cfg.Spire), Cap: cfg.Cap[p]}
	}
	var onField []int
	for p := Player(0); p < 2; p++ {
		for z := 0; z < match.NumSetupZones; z++ {
			for _, e := range cfg.Zones[p][z] {
				card := db.Card(e.CardID)
				for i := 0; i < e.Count; i++ {
					oid := g.newObj(card, p)
					o := g.objs[oid]
					switch z {
					case match.ZoneDeck:
						o.Zone = ZVault
						g.pl[p].Vault = append(g.pl[p].Vault, oid)
					case match.ZoneHand:
						o.Zone = ZHand
						g.pl[p].Hand = append(g.pl[p].Hand, oid)
					case match.ZoneField:
						o.Zone = ZChain // not in any zone list yet
						onField = append(onField, oid)
					case match.ZoneAsh:
						o.Zone = ZAsh
						g.pl[p].Ash = append(g.pl[p].Ash, oid)
					case match.ZoneRift:
						o.Zone = ZRift
						g.pl[p].Rift = append(g.pl[p].Rift, oid)
					}
				}
			}
		}
	}
	for _, oid := range onField {
		g.placeOnField(oid, g.objs[oid].Owner)
		g.objs[oid].Since = 0
	}
	g.rnd = rng.New(cfg.Seed)
	g.out.begin("GAME-START")
	g.out.player(g.first).end()
	if cfg.Shuffle {
		for p := Player(0); p < 2; p++ {
			v := g.pl[p].Vault
			g.rnd.Shuffle(len(v), func(i, j int) { v[i], v[j] = v[j], v[i] })
			g.out.begin("SHUFFLE")
			g.out.player(p).end()
		}
	}
	g.noTriggers = true
	for _, p := range []Player{g.first, g.first.Opp()} {
		for i := 0; i < cfg.Opening; i++ {
			if !g.drawOne(p) {
				break
			}
		}
	}
	g.noTriggers = false
	g.settle()
	if !g.over {
		g.beginTurn()
		g.advance()
	}
	return g, nil
}

func (g *Game) newObj(c *cards.Card, owner Player) int {
	g.objs = append(g.objs, &Obj{Card: c, Owner: owner, Ctrl: owner})
	return len(g.objs) - 1
}

// Over reports whether the match has ended.
func (g *Game) Over() bool { return g.over }

// Finish emits the final RESULT line of a match that is still running.
func (g *Game) Finish() {
	if !g.over {
		g.out.begin("RESULT")
		g.out.str("pending").str("none").end()
	}
}

// WriteTo writes everything produced so far to w and clears the buffer.
func (g *Game) WriteTo(w io.Writer) (int64, error) {
	n, err := w.Write(g.out.buf)
	g.out.buf = g.out.buf[:0]
	return int64(n), err
}

// Output returns the bytes produced so far without clearing them.
func (g *Game) Output() []byte { return g.out.buf }

// --------------------------------------------------------- zone helpers ---

func removeInt(s []int, v int) []int {
	for i, x := range s {
		if x == v {
			return append(s[:i], s[i+1:]...)
		}
	}
	return s
}

// zoneList returns a pointer to the slice holding the object in a private
// zone of its owner.
func (g *Game) zoneList(owner Player, z Zone) *[]int {
	ps := &g.pl[owner]
	switch z {
	case ZVault:
		return &ps.Vault
	case ZHand:
		return &ps.Hand
	case ZAsh:
		return &ps.Ash
	case ZRift:
		return &ps.Rift
	}
	return nil
}

// detach removes the object from the zone it is in (not the Field).
func (g *Game) detach(oid int) {
	o := g.objs[oid]
	if l := g.zoneList(o.Owner, o.Zone); l != nil {
		*l = removeInt(*l, oid)
		g.touch(cards.DepZones)
	}
}

// attach appends the object to a private zone of its owner.
func (g *Game) attach(oid int, z Zone) {
	o := g.objs[oid]
	o.Zone = z
	l := g.zoneList(o.Owner, z)
	*l = append(*l, oid)
	g.touch(cards.DepZones)
}

// touch marks derived data stale when the changed state is observable.
func (g *Game) touch(dep cards.Dep) {
	if g.liveDeps&dep != 0 {
		g.stale = true
	}
}

// canonical sorts oids by (timestamp, oid).
func (g *Game) canonical(ids []int) {
	sort.Slice(ids, func(i, j int) bool {
		a, b := g.objs[ids[i]], g.objs[ids[j]]
		if a.TS != b.TS {
			return a.TS < b.TS
		}
		return ids[i] < ids[j]
	})
}

// ctrlOf returns the current controller of a Field object, or the
// controller recorded when it last left the Field.
func (g *Game) ctrlOf(oid int) Player {
	o := g.objs[oid]
	if o.Zone == ZField {
		g.derive()
		return o.CurCtrl
	}
	return o.Ctrl
}

func (g *Game) onField(oid int) bool {
	return oid > 0 && oid < len(g.objs) && g.objs[oid].Zone == ZField
}

func (g *Game) isUnit(oid int) bool { return g.objs[oid].Card.Type == cards.Unit }

// ---------------------------------------------------------- Field entry ---

// placeOnField performs steps 1–3 of SPEC 17.17 (placement, timestamp,
// state reset, aura records) without emitting anything.
func (g *Game) placeOnField(oid int, ctrl Player) {
	o := g.objs[oid]
	if o.Zone != ZField {
		g.detach(oid)
	}
	o.Zone = ZField
	o.Ctrl = ctrl
	o.TS = g.nextTS
	g.nextTS++
	g.field = append(g.field, oid)
	o.resetField()
	o.Since = g.turn
	for _, a := range o.Card.Abilities {
		if a.Kind != cards.AbAura {
			continue
		}
		rec := &Record{Eid: g.nextEid, TS: g.nextTS, Ctrl: ctrl, Source: oid, Aura: true}
		g.nextEid++
		g.nextTS++
		for k := range a.Leaves {
			leaf := &a.Leaves[k]
			rec.Effs = append(rec.Effs, Eff{Kind: leafKind(leaf.S), leaf: leaf})
		}
		g.records = append(g.records, rec)
	}
	g.stale = true
}

func leafKind(s *cards.Static) RecKind {
	switch s.Kind {
	case cards.StModify:
		return RModify
	case cards.StSetbody:
		return RSetbody
	case cards.StSwap:
		return RSwap
	case cards.StGrant:
		return RGrant
	}
	return RCheaper
}

// enterField is the full procedure of SPEC 17.17: placement, ARRIVE event
// and trigger collection.
func (g *Game) enterField(oid int, ctrl Player) {
	g.placeOnField(oid, ctrl)
	g.out.begin("ARRIVE")
	g.out.obj(oid).str(g.objs[oid].Card.ID).end()
	g.collectArrive(oid)
}

// leaveField removes an object from the Field and returns the controller it
// had at that moment. Combat status of other objects is repaired first.
func (g *Game) leaveField(oid int) Player {
	g.derive()
	o := g.objs[oid]
	ctrl := o.CurCtrl
	g.removeFromCombat(oid)
	g.field = removeInt(g.field, oid)
	// Remove the object's aura records.
	k := 0
	for _, r := range g.records {
		if r.Aura && r.Source == oid {
			continue
		}
		g.records[k] = r
		k++
	}
	for i := k; i < len(g.records); i++ {
		g.records[i] = nil
	}
	g.records = g.records[:k]
	o.Ctrl = ctrl
	o.resetField()
	g.stale = true
	return ctrl
}

// removeFromCombat implements "Removal from combat" (SPEC 7.5).
func (g *Game) removeFromCombat(oid int) {
	o := g.objs[oid]
	if o.Blocking {
		if a := g.objs[o.BlockedAtk]; a != nil {
			a.Blockers = removeInt(a.Blockers, oid)
		}
		o.Blocking = false
		o.BlockedAtk = 0
	}
	if o.Attacking {
		for _, b := range o.Blockers {
			bo := g.objs[b]
			bo.Blocking = false
			bo.BlockedAtk = 0
		}
		o.Blockers = o.Blockers[:0]
		o.Attacking = false
	}
	g.touch(cards.DepCombat)
}
