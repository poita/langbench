// Package cards defines the typed card model of Spiremark and reads and
// validates card databases written as s-expressions.
//
// A database is parsed once into a tree of small structs whose operands are
// already converted (integers, enums, interned tag ids, resolved card
// pointers), so the engine never compares strings while a match runs.
package cards

// Type is a card type.
type Type uint8

// Card types.
const (
	Unit Type = iota
	Rite
	Relic
)

var typeNames = [...]string{"unit", "rite", "relic"}

func (t Type) String() string { return typeNames[t] }

// Keyword identifies one of the sixteen keywords.
type Keyword uint8

// Keywords.
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
	NumKeywords
)

var keywordNames = [...]string{
	"vanguard", "vigil", "riposte", "pierce", "ghostwalk", "skyhook", "venom",
	"siphon", "plating", "provoke", "spectral", "tenacity", "siegework",
	"shackled", "relentless", "swift",
}

func (k Keyword) String() string { return keywordNames[k] }

// KeywordByName looks a keyword up by its source spelling.
func KeywordByName(s string) (Keyword, bool) {
	for i, n := range keywordNames {
		if n == s {
			return Keyword(i), true
		}
	}
	return 0, false
}

// KwInst is one keyword instance; N is the value of a plating instance.
type KwInst struct {
	K Keyword
	N int
}

// String renders the instance: the keyword name, or plating:N.
func (k KwInst) String() string {
	if k.K == Plating {
		return "plating:" + itoa(int64(k.N))
	}
	return k.K.String()
}

// Cmp is a comparator.
type Cmp uint8

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

// Test applies the comparator to l and r.
func (c Cmp) Test(l, r int64) bool {
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

// Scope restricts a selector by controller or owner.
type Scope uint8

// Scopes.
const (
	Yours Scope = iota
	Theirs
	All
)

// Zone names a private zone usable in a (cards ...) selector.
type Zone uint8

// Zones.
const (
	ZoneHand Zone = iota
	ZoneAsh
	ZoneVault
	ZoneRift
)

// Event is a triggered-ability event.
type Event uint8

// Events.
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
	NumEvents
)

var eventNames = [...]string{
	"arrive", "leave", "dies", "ally-arrive", "enemy-arrive", "ally-dies",
	"enemy-dies", "turn-start", "your-turn-start", "turn-end", "your-turn-end",
	"attacks", "blocks", "blocked", "unblocked", "damaged", "deals-damage",
	"you-play-rite", "enemy-plays-rite", "you-draw", "spire-loss",
	"enemy-spire-loss", "end-of-combat",
}

func (e Event) String() string { return eventNames[e] }

// When is the timing of a delayed trigger.
type When uint8

// Delayed-trigger timings.
const (
	TurnEnd When = iota
	EndOfCombat
	YourNextTurnStart
)

var whenNames = [...]string{"turn-end", "end-of-combat", "your-next-turn-start"}

func (w When) String() string { return whenNames[w] }

// SelKind is the form of a selector.
type SelKind uint8

// Selector forms. The last four are player selectors; SelT can be either.
const (
	SelSelf SelKind = iota
	SelIt
	SelThat
	SelT
	SelUnits
	SelRelics
	SelCards
	SelRandomUnit
	SelYou
	SelFoe
	SelBoth
	SelOwnerOf
)

// Sel is an object, player or damage selector.
type Sel struct {
	Kind    SelKind
	N       int // target number for SelT (1-based)
	Scope   Scope
	Zone    Zone
	Filters []Filter
	Inner   *Sel // operand of SelOwnerOf
}

// FilterKind is the form of a filter.
type FilterKind uint8

// Filter forms.
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
	Kind  FilterKind
	Kw    Keyword
	Tag   int // interned tag id
	Type  Type
	Cmp   Cmp
	N     int64
	Inner *Filter
}

// AmtKind is the form of an amount.
type AmtKind uint8

// Amount forms.
const (
	AmtConst AmtKind = iota
	AmtCount
	AmtHand
	AmtAsh
	AmtVault
	AmtEdge
	AmtCore
	AmtWounds
)

// Amount evaluates to a signed integer.
type Amount struct {
	Kind AmtKind
	N    int64
	Sel  *Sel // object selector, or player selector for hand/ash/vault
}

// CondKind is the form of a condition.
type CondKind uint8

// Condition forms.
const (
	CondCount CondKind = iota
	CondSpire
	CondHand
	CondAsh
	CondVault
	CondEmber
	CondMyTurn
	CondAnd
	CondOr
	CondNot
)

// Cond is a boolean condition.
type Cond struct {
	Kind CondKind
	Sel  *Sel
	Cmp  Cmp
	N    int64
	Subs []*Cond
}

// EffKind is the form of an effect.
type EffKind uint8

// Effect forms.
const (
	EffDamage EffKind = iota
	EffDestroy
	EffSacrifice
	EffExile
	EffBounce
	EffDraw
	EffDiscard
	EffMill
	EffSpire
	EffEmber
	EffCap
	EffModify
	EffSetbody
	EffSwapstats
	EffGrant
	EffStrip
	EffControl
	EffCounters
	EffReady
	EffExhaust
	EffDoom
	EffWard
	EffShield
	EffSummon
	EffConjure
	EffReanimate
	EffRecall
	EffNegate
	EffDig
	EffDelay
	EffIf
	EffEach
	EffRepeat
	EffNothing
)

// Effect is one node of an effect tree.
type Effect struct {
	Kind    EffKind
	A, B    Amount
	Sel     *Sel
	Card    *Card // summon / conjure
	CardID  string
	Kw      KwInst
	When    When
	Cond    *Cond
	Body    []*Effect // delay / each / repeat body, or the "then" list of if
	Else    []*Effect
	HasElse bool
	DigK    int64
	Filters []Filter // dig filters
}

// StaticKind is the form of an aura static.
type StaticKind uint8

// Static forms.
const (
	StModify StaticKind = iota
	StSetbody
	StSwap
	StGrant
	StCheaper
	StWhen
)

// CardFilter is a filter on the printed characteristics of a card.
type CardFilter struct {
	Kind FilterKind // FType, FTag or FCost
	Type Type
	Tag  int
	Cmp  Cmp
	N    int64
}

// Static is one continuous-effect form inside an aura clause.
type Static struct {
	Kind    StaticKind
	A, B    Amount
	Sel     *Sel
	Kw      KwInst
	Cheaper int64
	CardF   []CardFilter
	Cond    *Cond
	Subs    []*Static
}

// Leaf is a non-"when" static together with the conditions of the "when"
// statements that enclose it.
type Leaf struct {
	S     *Static
	Conds []*Cond
	Deps  Dep
}

// Dep is a bit set of game-state categories that an aura leaf reads.
type Dep uint32

// Dependency bits.
const (
	DepWounds Dep = 1 << iota
	DepReady
	DepCombat
	DepTurn
	DepSpire
	DepEmber
	DepZones
)

// TSKind is the form of a target specification.
type TSKind uint8

// Target specification forms.
const (
	TSUnit TSKind = iota
	TSRelic
	TSAny
	TSPlayer
	TSChained
	TSAshcard
)

// TargetSpec describes one target of an ability.
type TargetSpec struct {
	Kind    TSKind
	Filters []Filter
}

// CostKind is the form of an activation cost item.
type CostKind uint8

// Cost item forms.
const (
	CostEmber CostKind = iota
	CostSpire
	CostDiscard
	CostExhaust
	CostSacself
	CostCounters
	CostOnce
)

// CostItem is one activation cost item.
type CostItem struct {
	Kind CostKind
	N    int64
}

// AbilityKind is the clause an ability came from.
type AbilityKind uint8

// Ability kinds, in ability-number order.
const (
	AbResolve AbilityKind = iota
	AbOn
	AbAct
	AbAura
)

// Ability is one numbered ability of a card.
type Ability struct {
	Kind    AbilityKind
	Event   Event
	Targets []TargetSpec
	Cost    []CostItem
	Effects []*Effect
	Leaves  []Leaf

	// Canonical renderings used by the CARD directive.
	TargetsText string // "-" when absent
	CostText    string
	BodyText    string // effects or statics, space separated
}

// Card is one card definition.
type Card struct {
	ID        string
	Name      string
	Text      string
	Type      Type
	Cost      int64
	Edge      int64
	Core      int64
	Tags      []string // file order
	TagIDs    []int
	Keywords  []KwInst // printed keywords, file order
	KwMask    uint32
	Abilities []*Ability // ability n is Abilities[n-1]

	// ByEvent[e] lists the 1-based numbers of the "on e" abilities.
	ByEvent [NumEvents][]int
}

// HasTag reports whether the card's tags include the interned tag id.
func (c *Card) HasTag(id int) bool {
	for _, t := range c.TagIDs {
		if t == id {
			return true
		}
	}
	return false
}

// HasKeyword reports whether the printed keywords include k.
func (c *Card) HasKeyword(k Keyword) bool { return c.KwMask&(1<<k) != 0 }

// DB is a validated card database.
type DB struct {
	cards map[string]*Card
	order []*Card
	tags  map[string]int
}

// Card returns the card with the given id, or nil.
func (db *DB) Card(id string) *Card { return db.cards[id] }

// Cards returns every card in file order.
func (db *DB) Cards() []*Card { return db.order }

func itoa(v int64) string {
	if v == 0 {
		return "0"
	}
	var b [20]byte
	i := len(b)
	neg := v < 0
	u := uint64(v)
	if neg {
		u = -u
	}
	for u > 0 {
		i--
		b[i] = byte('0' + u%10)
		u /= 10
	}
	if neg {
		i--
		b[i] = '-'
	}
	return string(b[i:])
}
