package engine

import "cardgame/cards"

// Player identifies one of the two players: 0 is A and 1 is B.
type Player uint8

// The two players.
const (
	A Player = 0
	B Player = 1
)

// Opp returns the opponent.
func (p Player) Opp() Player { return p ^ 1 }

func (p Player) String() string {
	if p == A {
		return "A"
	}
	return "B"
}

// Zone is the place an object currently occupies.
type Zone uint8

// Zones. ZChain holds a card that is the source of a Chain entry.
const (
	ZVault Zone = iota
	ZHand
	ZField
	ZAsh
	ZRift
	ZChain
)

var zoneNames = [...]string{"vault", "hand", "field", "ash", "rift", "chain"}

// DecisionKind is the kind of input the engine is waiting for.
type DecisionKind uint8

// Decision kinds.
const (
	DecNone DecisionKind = iota
	DecPriority
	DecAttackers
	DecBlockers
)

var decisionNames = [...]string{"over", "priority", "attackers", "blockers"}

// Obj is one card instance of the match. Objects live in a dense slice
// indexed by oid.
type Obj struct {
	Card  *cards.Card
	Owner Player
	Zone  Zone
	TS    int    // timestamp of the last entry to the Field, 0 if never
	Ctrl  Player // base controller on the Field; last controller afterwards

	// Per-Field state (SPEC 7.5).
	Exhausted    bool
	Wounds       int
	Counters     int
	Ward         int
	Doomed       bool
	Since        int
	Attacking    bool
	Blocking     bool
	Blocked      bool
	Blockers     []int
	BlockedAtk   int
	TenacityUsed bool
	Once         []int // ability numbers used this turn

	// Derived characteristics, valid for Field objects after derive().
	CurCtrl  Player
	Edge     int
	Core     int
	KwMask   uint32
	Plating  int
	Stripped bool
}

func (o *Obj) hasKw(k cards.Keyword) bool { return o.KwMask&(1<<k) != 0 }

// resetField clears the per-Field state when an object leaves or enters.
func (o *Obj) resetField() {
	o.Exhausted = false
	o.Wounds, o.Counters, o.Ward = 0, 0, 0
	o.Doomed = false
	o.Attacking, o.Blocking, o.Blocked = false, false, false
	o.Blockers = o.Blockers[:0]
	o.BlockedAtk = 0
	o.TenacityUsed = false
	o.Once = o.Once[:0]
}

// RecKind is the kind of a continuous-effect record.
type RecKind uint8

// Record kinds.
const (
	RModify RecKind = iota
	RSetbody
	RSwap
	RGrant
	RStrip
	RControl
	RCheaper
)

// Eff is one effect carried by a record. Discrete records have exactly one;
// an aura record has one per leaf static of its clause.
type Eff struct {
	Kind     RecKind
	A, B     int
	Kw       cards.KwInst
	Cheaper  int
	CardF    []cards.CardFilter
	Active   bool
	Affected []int
	leaf     *cards.Leaf
}

// Record is a continuous-effect record (SPEC 14.1).
type Record struct {
	Eid, TS int
	Ctrl    Player
	Source  int
	Aura    bool // aura records belong to a source on the Field; Ctrl is then its current controller
	Effs    []Eff
}

// TargetKind distinguishes players, objects and Chain entries.
type TargetKind uint8

// Target kinds.
const (
	TPlayer TargetKind = iota
	TObject
	TChain
)

// Target is one chosen target of an ability.
type Target struct {
	Kind    TargetKind
	ID      int
	Removed bool
}

// EntryKind is the kind of a Chain entry.
type EntryKind uint8

// Chain entry kinds.
const (
	EKRite EntryKind = iota
	EKUnit
	EKRelic
	EKAbility
	EKTrigger
)

var entryKindNames = [...]string{"rite", "unit", "relic", "ability", "trigger"}

// SubjKind is the kind of a trigger subject.
type SubjKind uint8

// Subject kinds.
const (
	SubjNone SubjKind = iota
	SubjObj
	SubjPlayer
)

// Subject is the `it` of a triggered ability.
type Subject struct {
	Kind SubjKind
	ID   int
}

// Entry is a Chain entry.
type Entry struct {
	Cid     int
	Kind    EntryKind
	Ctrl    Player
	Source  int
	Index   int
	Targets []Target
	Specs   []cards.TargetSpec
	Delayed *Delayed
	Subj    Subject
}

// Delayed is a delayed trigger (SPEC 13.5).
type Delayed struct {
	TS      int
	Ctrl    Player
	Source  int
	When    cards.When
	Effects []*cards.Effect
	Targets []Target
	Specs   []cards.TargetSpec
}

// Pending is a collected trigger waiting for the next push.
type Pending struct {
	Ctrl    Player
	Source  int
	TS      int
	Index   int
	Subj    Subject
	Delayed *Delayed
}

// Step is a turn step.
type Step uint8

// Turn steps, in order. Some are internal sub-stages of the clash phase.
const (
	StDawn Step = iota
	StDraw
	StMain1
	StAttackDecl
	StAttackRound
	StBlockDecl
	StBlockRound
	StRiposte
	StDamage
	StClashEnd
	StClashCleanup
	StMain2
	StDuskTrigger
	StDuskDiscard
	StDuskCleanup
)

var stepPhaseNames = [...]string{
	"dawn", "draw", "main1", "clash-attack", "clash-attack", "clash-block", "clash-block",
	"clash-riposte", "clash-damage", "clash-end", "clash-end", "main2", "dusk-trigger", "dusk-discard", "dusk-cleanup",
}

type playerState struct {
	Spire  int
	Ember  int
	Cap    int
	Shield int
	Vault  []int // top first
	Hand   []int
	Ash    []int
	Rift   []int
}
