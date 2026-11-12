// Package cards defines the typed card model of Spiremark, and reads and
// validates card databases written as s-expressions.
//
// A Database is parsed once into trees of Effect, Selector, Filter, Amount,
// Cond and Static values which the engine package interprets directly;
// nothing is re-parsed while a game runs.
package cards

import "github.com/spiremark/cardgame/sexpr"

// Type is a card type.
type Type int

// Card types.
const (
	Unit Type = iota
	Rite
	Relic
)

var typeNames = [...]string{"unit", "rite", "relic"}

func (t Type) String() string { return typeNames[t] }

// Keyword identifies one of the sixteen keywords.
type Keyword int

// Keywords, in no particular order.
const (
	Vanguard Keyword = iota
	Vigil
	Riposte
	Pierce
	Ghostwalk
	Skyhook
	Venom
	Siphon
	Plating
	Provoke
	Spectral
	Tenacity
	Siegework
	Shackled
	Relentless
	Swift
	numKeywords
)

var keywordNames = [...]string{
	"vanguard", "vigil", "riposte", "pierce", "ghostwalk", "skyhook", "venom",
	"siphon", "plating", "provoke", "spectral", "tenacity", "siegework",
	"shackled", "relentless", "swift",
}

func (k Keyword) String() string { return keywordNames[k] }

// KeywordByName looks a keyword up by its printed name.
func KeywordByName(s string) (Keyword, bool) {
	for i, n := range keywordNames {
		if n == s {
			return Keyword(i), true
		}
	}
	return 0, false
}

// KW is one keyword instance. N is meaningful only for Plating.
type KW struct {
	K Keyword
	N int
}

// String renders the keyword as in CARD output: "plating:N" or the name.
func (k KW) String() string {
	if k.K == Plating {
		return "plating:" + itoa(k.N)
	}
	return k.K.String()
}

// Cmp is a comparator.
type Cmp int

// Comparators.
const (
	Le Cmp = iota
	Lt
	Eq
	Ge
	Gt
	Ne
)

var cmpNames = [...]string{"le", "lt", "eq", "ge", "gt", "ne"}

// Test applies the comparator: l <cmp> r.
func (c Cmp) Test(l, r int) bool {
	switch c {
	case Le:
		return l <= r
	case Lt:
		return l < r
	case Eq:
		return l == r
	case Ge:
		return l >= r
	case Gt:
		return l > r
	}
	return l != r
}

// Scope restricts a selector to one side of the table.
type Scope int

// Scopes.
const (
	Yours Scope = iota
	Theirs
	All
)

// CardZone is a zone a (cards ...) selector can name.
type CardZone int

// Zones usable in (cards <zone> ...).
const (
	ZHand CardZone = iota
	ZAsh
	ZVault
	ZRift
)

// FilterKind enumerates the filter forms of SPEC section 6.5.
type FilterKind int

// Filter kinds.
const (
	FKw FilterKind = iota
	FNoKw
	FTag
	FType
	FCost
	FEdge
	FCore
	FWounded
	FReady
	FExhausted
	FSettling
	FAttacking
	FBlocking
	FMine
	FEnemy
	FOther
	FNot
)

// Filter is one predicate of a selector or target specification.
type Filter struct {
	Kind FilterKind
	KW   Keyword
	Tag  string
	Type Type
	Cmp  Cmp
	N    int
	Not  *Filter
}

// SelKind enumerates selector forms.
type SelKind int

// Selector kinds.
const (
	SelSelf SelKind = iota
	SelIt
	SelThat
	SelTarget
	SelUnits
	SelRelics
	SelCards
	SelRandomUnit
)

// Selector denotes zero or more objects.
type Selector struct {
	Kind    SelKind
	N       int // target number for SelTarget (1-based)
	Scope   Scope
	Zone    CardZone
	Filters []Filter
}

// PSelKind enumerates player-selector forms.
type PSelKind int

// Player selector kinds.
const (
	PYou PSelKind = iota
	PFoe
	PBoth
	PTarget
	POwnerOf
)

// PlayerSel denotes zero, one or two players.
type PlayerSel struct {
	Kind PSelKind
	N    int       // target number for PTarget
	Sel  *Selector // for POwnerOf
}

// DSel is the second argument of damage: a player selector or an object
// selector (or, for (t n), whichever the target is).
type DSel struct {
	Player *PlayerSel
	Obj    *Selector
}

// AmtKind enumerates amount forms.
type AmtKind int

// Amount kinds.
const (
	AConst AmtKind = iota
	ACount
	AHand
	AAsh
	AVault
	AEdge
	ACore
	AWounds
)

// Amount evaluates to a signed integer.
type Amount struct {
	Kind AmtKind
	N    int
	Sel  *Selector
	PSel *PlayerSel
}

// CondKind enumerates condition forms.
type CondKind int

// Condition kinds.
const (
	CCount CondKind = iota
	CSpire
	CHand
	CAsh
	CVault
	CEmber
	CMyTurn
	CAnd
	COr
	CNot
)

// Cond is a boolean condition.
type Cond struct {
	Kind CondKind
	Cmp  Cmp
	N    int
	Sel  *Selector
	PSel *PlayerSel
	Subs []*Cond
}

// Op identifies an effect form.
type Op int

// Effect operations.
const (
	OpDamage Op = iota
	OpDestroy
	OpSacrifice
	OpExile
	OpBounce
	OpDraw
	OpDiscard
	OpMill
	OpSpire
	OpEmber
	OpCap
	OpModify
	OpSetbody
	OpSwapstats
	OpGrant
	OpStrip
	OpControl
	OpCounters
	OpReady
	OpExhaust
	OpDoom
	OpWard
	OpShield
	OpSummon
	OpConjure
	OpReanimate
	OpRecall
	OpNegate
	OpDig
	OpDelay
	OpIf
	OpEach
	OpRepeat
	OpNothing
)

// When is the timing of a delayed trigger.
type When int

// Delay timings.
const (
	TurnEnd When = iota
	EndOfCombat
	YourNextTurnStart
)

var whenNames = [...]string{"turn-end", "end-of-combat", "your-next-turn-start"}

func (w When) String() string { return whenNames[w] }

// Effect is one node of an effect tree. Which fields are used depends on Op.
type Effect struct {
	Op      Op
	A1, A2  *Amount
	Sel     *Selector
	PSel    *PlayerSel
	DSel    *DSel
	KW      KW
	CardID  string
	K       int      // dig: number of cards
	Filters []Filter // dig: filters
	When    When
	Cond    *Cond
	Body    []*Effect
	Else    []*Effect
	HasElse bool
	Node    sexpr.Node // original form, for canonical printing
}

// StaticKind enumerates aura statics.
type StaticKind int

// Static kinds.
const (
	StModify StaticKind = iota
	StSetbody
	StSwap
	StGrant
	StCheaper
	StWhen
)

// CardFilter is a filter on a card about to be played (printed values).
type CardFilter struct {
	Kind FilterKind // FType, FTag or FCost
	Type Type
	Tag  string
	Cmp  Cmp
	N    int
}

// Static is one continuous effect of an aura.
type Static struct {
	Kind        StaticKind
	A1, A2      *Amount
	Sel         *Selector
	KW          KW
	N           int
	CardFilters []CardFilter
	Cond        *Cond
	Body        []*Static
	Node        sexpr.Node
}

// CostKind enumerates activated-ability cost items.
type CostKind int

// Cost item kinds.
const (
	CostEmber CostKind = iota
	CostSpire
	CostDiscard
	CostExhaust
	CostSacself
	CostCounters
	CostOnce
)

// CostItem is one payment of an activated ability.
type CostItem struct {
	Kind CostKind
	N    int
}

// TSKind enumerates target-specification forms.
type TSKind int

// Target specification kinds.
const (
	TSUnit TSKind = iota
	TSRelic
	TSAny
	TSPlayer
	TSChained
	TSAshcard
)

// TargetSpec says what one target of an ability may be.
type TargetSpec struct {
	Kind    TSKind
	Filters []Filter
}

// AbilityKind says which clause an ability came from.
type AbilityKind int

// Ability kinds.
const (
	AbResolve AbilityKind = iota
	AbOn
	AbAct
	AbAura
)

// Event is a trigger event.
type Event int

// Trigger events.
const (
	EvArrive Event = iota
	EvLeave
	EvDies
	EvAllyArrive
	EvEnemyArrive
	EvAllyDies
	EvEnemyDies
	EvTurnStart
	EvYourTurnStart
	EvTurnEnd
	EvYourTurnEnd
	EvAttacks
	EvBlocks
	EvBlocked
	EvUnblocked
	EvDamaged
	EvDealsDamage
	EvYouPlayRite
	EvEnemyPlaysRite
	EvYouDraw
	EvSpireLoss
	EvEnemySpireLoss
	EvEndOfCombat
)

var eventNames = [...]string{
	"arrive", "leave", "dies", "ally-arrive", "enemy-arrive", "ally-dies",
	"enemy-dies", "turn-start", "your-turn-start", "turn-end", "your-turn-end",
	"attacks", "blocks", "blocked", "unblocked", "damaged", "deals-damage",
	"you-play-rite", "enemy-plays-rite", "you-draw", "spire-loss",
	"enemy-spire-loss", "end-of-combat",
}

func (e Event) String() string { return eventNames[e] }

// Ability is one numbered ability of a card.
type Ability struct {
	Index   int // 1-based, per SPEC 5.3
	Kind    AbilityKind
	Event   Event // AbOn only
	Targets []TargetSpec
	Cost    []CostItem // AbAct only
	Effects []*Effect  // AbResolve, AbOn, AbAct
	Statics []*Static  // AbAura

	targetsNode *sexpr.Node
	costNode    *sexpr.Node
	effectNodes []sexpr.Node // for effects or statics, in order
}

// Card is one entry of a database.
type Card struct {
	ID        string
	Name      string
	Type      Type
	Cost      int
	Edge      int // printed edge (0 unless a unit)
	Core      int // printed core (0 unless a unit)
	Tags      []string
	Keywords  []KW // printed keywords, in file order
	Text      string
	Abilities []*Ability // Abilities[i].Index == i+1

	keywordMask uint32
}

// HasPrinted reports whether the card prints keyword k.
func (c *Card) HasPrinted(k Keyword) bool { return c.keywordMask&(1<<uint(k)) != 0 }

// HasTag reports whether the card has the given tag.
func (c *Card) HasTag(tag string) bool {
	for _, t := range c.Tags {
		if t == tag {
			return true
		}
	}
	return false
}

// Ability returns the 1-based numbered ability, or nil when out of range.
func (c *Card) Ability(i int) *Ability {
	if i < 1 || i > len(c.Abilities) {
		return nil
	}
	return c.Abilities[i-1]
}

// Database is an immutable collection of cards.
type Database struct {
	byID  map[string]*Card
	order []*Card
}

// Get returns the card with the given id.
func (d *Database) Get(id string) (*Card, bool) {
	c, ok := d.byID[id]
	return c, ok
}

// Cards returns the cards in file order.
func (d *Database) Cards() []*Card { return d.order }

// Len returns the number of cards.
func (d *Database) Len() int { return len(d.order) }

func itoa(n int) string {
	return sexpr.Node{Kind: sexpr.Int, Num: int64(n)}.String()
}
