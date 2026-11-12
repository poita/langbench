// Package engine implements the Spiremark rules engine: game state, the
// layer system, the effect interpreter, the Chain, triggers, combat and the
// inspection views (DUMP, LEGAL, VAULT).
//
// A Game is created with New, which performs match setup and runs the engine
// forward to the first decision point. Player actions are then submitted with
// Game.Do; each accepted action is processed and the engine again runs
// forward to the next decision point, so the Game is always either waiting
// for input or finished. Every rules event is written as one numbered line to
// the io.Writer given to New (callers should supply a buffered writer).
package engine

import (
	"io"

	"github.com/spiremark/cardgame/cards"
	"github.com/spiremark/cardgame/prng"
)

// Player is one of the two players.
type Player int

// The two players.
const (
	A Player = 0
	B Player = 1
)

// Opp returns the opponent.
func (p Player) Opp() Player { return 1 - p }

func (p Player) String() string {
	if p == A {
		return "A"
	}
	return "B"
}

// Zone is where an object currently is.
type Zone int

// Zones.
const (
	ZNone Zone = iota
	ZVault
	ZHand
	ZField
	ZAsh
	ZRift
	ZChain
)

var zoneNames = [...]string{"none", "vault", "hand", "field", "ash", "rift", "chain"}

func (z Zone) String() string { return zoneNames[z] }

// step identifies the next piece of turn structure the engine will run.
type step int

const (
	sDawn step = iota
	sDraw
	sMain1
	sClashAttack
	sClashBlock
	sRiposte
	sDamage
	sClashEnd
	sClashEndDone
	sMain2
	sDuskTrigger
	sDuskDiscard
	sDuskCleanup
	sAdvance
)

// DecisionKind says what input the engine is waiting for.
type DecisionKind int

// Decision kinds.
const (
	DecNone DecisionKind = iota
	DecPriority
	DecAttackers
	DecBlockers
)

var decNames = [...]string{"over", "priority", "attackers", "blockers"}

func (d DecisionKind) String() string { return decNames[d] }

// Entry (Chain) kinds.
type entryKind int

const (
	entRite entryKind = iota
	entUnit
	entRelic
	entAbility
	entTrigger
)

var entryKindNames = [...]string{"rite", "unit", "relic", "ability", "trigger"}

// Obj is one card instance in the match.
type Obj struct {
	OID   int
	Card  *cards.Card
	Owner Player
	zone  Zone
	ts    int // timestamp of last Field entry, 0 if never

	// Field state.
	baseCtrl  Player
	lastCtrl  Player
	ready     bool
	wounds    int
	counters  int
	ward      int
	doomed    bool
	since     int
	attacking bool
	blocking  bool
	blocked   bool
	blockers  []*Obj
	blocks    *Obj
	tenUsed   bool
	once      []int

	// Derived (valid for Field objects after derive).
	ctrl     Player
	edge     int
	core     int
	kwMask   uint32
	plating  int
	stripped bool
}

// ID returns the object's oid.
func (o *Obj) ID() int { return o.OID }

type tkind int

const (
	tNone tkind = iota
	tPlayer
	tObj
	tEntry
)

// target is a player, an object or a Chain entry.
type target struct {
	kind    tkind
	p       Player
	o       *Obj
	e       *entry
	removed bool
}

func playerTarget(p Player) target { return target{kind: tPlayer, p: p} }
func objTarget(o *Obj) target      { return target{kind: tObj, o: o} }

func (t target) key() [3]int {
	switch t.kind {
	case tPlayer:
		return [3]int{0, int(t.p), 0}
	case tObj:
		return [3]int{1, t.o.ts, t.o.OID}
	case tEntry:
		return [3]int{2, t.e.cid, 0}
	}
	return [3]int{3, 0, 0}
}

func keyLess(a, b [3]int) bool {
	for i := 0; i < 3; i++ {
		if a[i] != b[i] {
			return a[i] < b[i]
		}
	}
	return false
}

func (t target) same(u target) bool {
	if t.kind != u.kind {
		return false
	}
	switch t.kind {
	case tPlayer:
		return t.p == u.p
	case tObj:
		return t.o == u.o
	case tEntry:
		return t.e == u.e
	}
	return true
}

func (t target) render() string {
	switch t.kind {
	case tPlayer:
		return t.p.String()
	case tObj:
		return oidS(t.o)
	case tEntry:
		return "~" + itoa(t.e.cid)
	}
	return "-"
}

// entry is an item on the Chain.
type entry struct {
	cid     int
	kind    entryKind
	ctrl    Player
	src     *Obj
	idx     int
	targets []target
	specs   []cards.TargetSpec
	it      target
	effects []*cards.Effect // delayed triggers only
	onChain bool
}

type recKind int

const (
	rModify recKind = iota
	rSetbody
	rSwap
	rGrant
	rStrip
	rControl
	rAura
)

// auraPart is the evaluated form of one static of an aura record.
type auraPart struct {
	kind   cards.StaticKind
	a, b   int
	kw     cards.KW
	n      int
	cf     []cards.CardFilter
	active bool
	objs   []*Obj
}

// record is a continuous-effect record (SPEC 14.1).
type record struct {
	eid      int
	ts       int
	ctrl     Player
	src      *Obj
	kind     recKind
	a, b     int
	kw       cards.KW
	affected []*Obj
	ab       *cards.Ability
	parts    []auraPart
}

type delayed struct {
	ts      int
	ctrl    Player
	src     *Obj
	when    cards.When
	effects []*cards.Effect
	targets []target
	specs   []cards.TargetSpec
}

type pendingTrig struct {
	ctrl    Player
	ts, oid int
	idx     int
	src     *Obj
	ab      *cards.Ability
	it      target
	delayed *delayed
}

type playerState struct {
	spire, ember, cap, shield int
	vault, hand, ash, rift    []*Obj
}

// Config describes a match to set up. The zero value is not valid: Spire,
// MaxCap, TurnLimit and so on must be filled in (see DefaultConfig).
type Config struct {
	Seed      uint64
	Spire     int
	Opening   int
	MaxCap    int
	HandMax   int
	TurnLimit int
	First     Player
	Shuffle   bool
	Cap       [2]int
	Deck      [2][]CardCount
	Hand      [2][]CardCount
	Field     [2][]CardCount
	Ash       [2][]CardCount
	Rift      [2][]CardCount
}

// CardCount is a card id with a number of copies.
type CardCount struct {
	ID    string
	Count int
}

// DefaultConfig returns a Config holding the defaults of SPEC 4.1.
func DefaultConfig() Config {
	return Config{Spire: 25, Opening: 5, MaxCap: 10, HandMax: 7, TurnLimit: 200, Shuffle: true}
}

// Game is a running match.
type Game struct {
	cfg Config
	db  *cards.Database
	out io.Writer
	rng *prng.Rand
	seq int

	pl    [2]playerState
	byOID []*Obj // index = oid; byOID[0] unused
	field []*Obj // canonical order (entry order)
	chain []*entry

	nextCID, nextTS, nextEID int

	records []*record
	delays  []*delayed
	pending []*pendingTrig

	turn   int
	active Player
	phase  string
	step   step

	decKind   DecisionKind
	decPlayer Player
	passes    int
	roundNext step

	loss      [2]string
	over      bool
	winner    string
	reason    string
	finalized bool

	dirty      bool
	noTriggers bool
	riposteSet map[*Obj]bool
	scratch    []byte
}

// Result describes how a finished match ended.
type Result struct {
	Over   bool
	Winner string // "A", "B" or "draw"
	Reason string
}

// Result returns the match result; Over is false while the match runs.
func (g *Game) Result() Result {
	return Result{Over: g.over, Winner: g.winner, Reason: g.reason}
}

// Decision reports who the engine is waiting for and what it expects. After
// the match ends the kind is DecNone.
func (g *Game) Decision() (Player, DecisionKind) { return g.decPlayer, g.decKind }

// Turn returns the current turn number.
func (g *Game) Turn() int { return g.turn }

// Active returns the active player.
func (g *Game) Active() Player { return g.active }

// Phase returns the name of the current phase or step.
func (g *Game) Phase() string { return g.phase }
