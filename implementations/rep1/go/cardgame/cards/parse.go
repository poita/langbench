package cards

import (
	"errors"
	"os"
	"strings"

	"cardgame/sexpr"
)

// ErrBadDatabase is returned for every unreadable or invalid database.
var ErrBadDatabase = errors.New("cards: bad database")

type bad struct{}

type parser struct {
	db   *DB
	deps Dep // dependency bits gathered while parsing one aura clause
}

func fail() { panic(bad{}) }

// Load reads and validates the database stored in the named file.
func Load(path string) (*DB, error) {
	src, err := os.ReadFile(path)
	if err != nil {
		return nil, ErrBadDatabase
	}
	return Parse(src)
}

// Parse validates a database held in memory. Any problem — lexical,
// grammatical or semantic — yields ErrBadDatabase.
func Parse(src []byte) (db *DB, err error) {
	nodes, perr := sexpr.Parse(src)
	if perr != nil {
		return nil, ErrBadDatabase
	}
	db = &DB{cards: map[string]*Card{}, tags: map[string]int{}}
	p := &parser{db: db}
	defer func() {
		if r := recover(); r != nil {
			if _, ok := r.(bad); !ok {
				panic(r)
			}
			db, err = nil, ErrBadDatabase
		}
	}()
	for _, n := range nodes {
		c := p.card(n)
		if db.cards[c.ID] != nil {
			fail()
		}
		db.cards[c.ID] = c
		db.order = append(db.order, c)
	}
	p.resolveCards()
	return db, nil
}

func (db *DB) tagID(name string) int {
	if id, ok := db.tags[name]; ok {
		return id
	}
	id := len(db.tags)
	db.tags[name] = id
	return id
}

// pendingRefs are summon/conjure effects checked once all cards are known.
func (p *parser) resolveCards() {
	for _, c := range p.db.order {
		for _, a := range c.Abilities {
			p.resolveEffects(a.Effects)
		}
	}
}

func (p *parser) resolveEffects(es []*Effect) {
	for _, e := range es {
		switch e.Kind {
		case EffSummon, EffConjure:
			t := p.db.cards[e.CardID]
			if t == nil || (e.Kind == EffSummon && t.Type == Rite) {
				fail()
			}
			e.Card = t
		case EffDelay, EffEach, EffRepeat:
			p.resolveEffects(e.Body)
		case EffIf:
			p.resolveEffects(e.Body)
			p.resolveEffects(e.Else)
		}
	}
}

func validCardID(s string) bool {
	if len(s) != 7 || s[3] != '-' {
		return false
	}
	for i := 0; i < 3; i++ {
		if s[i] < 'A' || s[i] > 'Z' {
			return false
		}
	}
	for i := 4; i < 7; i++ {
		if s[i] < '0' || s[i] > '9' {
			return false
		}
	}
	return true
}

// list checks that n is a list whose head is head and whose length is
// within [min, max] (counting the head), and returns its arguments.
func list(n *sexpr.Node, head string, min, max int) []*sexpr.Node {
	if n.Kind != sexpr.List || len(n.Items) == 0 || !n.Items[0].IsSym(head) {
		fail()
	}
	if len(n.Items) < min || (max >= 0 && len(n.Items) > max) {
		fail()
	}
	return n.Items[1:]
}

func intOf(n *sexpr.Node) int64 {
	if n.Kind != sexpr.Int {
		fail()
	}
	return n.Int
}

func symOf(n *sexpr.Node) string {
	if n.Kind != sexpr.Symbol {
		fail()
	}
	return n.Text
}

func strOf(n *sexpr.Node) string {
	if n.Kind != sexpr.String {
		fail()
	}
	return n.Text
}

func cmpOf(n *sexpr.Node) Cmp {
	s := symOf(n)
	for i, name := range cmpNames {
		if name == s {
			return Cmp(i)
		}
	}
	fail()
	return 0
}

func typeOf(n *sexpr.Node) Type {
	switch symOf(n) {
	case "unit":
		return Unit
	case "rite":
		return Rite
	case "relic":
		return Relic
	}
	fail()
	return 0
}

func scopeOf(n *sexpr.Node) Scope {
	switch symOf(n) {
	case "yours":
		return Yours
	case "theirs":
		return Theirs
	case "all":
		return All
	}
	fail()
	return 0
}

func keywordOf(n *sexpr.Node) Keyword {
	k, ok := KeywordByName(symOf(n))
	if !ok {
		fail()
	}
	return k
}

// kwspec parses <keyword> or (plating <int>).
func kwspec(n *sexpr.Node) KwInst {
	if n.Kind == sexpr.List {
		a := list(n, "plating", 2, 2)
		return KwInst{K: Plating, N: int(intOf(a[0]))}
	}
	k := keywordOf(n)
	if k == Plating {
		fail()
	}
	return KwInst{K: k}
}

// ---------------------------------------------------------------- cards ---

func (p *parser) card(n *sexpr.Node) *Card {
	if n.Kind != sexpr.List || len(n.Items) < 2 || !n.Items[0].IsSym("card") {
		fail()
	}
	idn := n.Items[1]
	if idn.Kind != sexpr.Symbol || !validCardID(idn.Text) {
		fail()
	}
	c := &Card{ID: idn.Text}
	var haveName, haveType, haveCost, haveBody, haveTags, haveKw, haveText bool
	var resolve *Ability
	var ons, acts, auras []*Ability
	for _, cl := range n.Items[2:] {
		if cl.Kind != sexpr.List || len(cl.Items) == 0 {
			fail()
		}
		switch cl.Items[0].Text {
		case "name":
			a := list(cl, "name", 2, 2)
			if haveName {
				fail()
			}
			haveName, c.Name = true, strOf(a[0])
		case "type":
			a := list(cl, "type", 2, 2)
			if haveType {
				fail()
			}
			haveType, c.Type = true, typeOf(a[0])
		case "cost":
			a := list(cl, "cost", 2, 2)
			if haveCost {
				fail()
			}
			haveCost, c.Cost = true, intOf(a[0])
			if c.Cost < 0 {
				fail()
			}
		case "body":
			a := list(cl, "body", 3, 3)
			if haveBody {
				fail()
			}
			haveBody, c.Edge, c.Core = true, intOf(a[0]), intOf(a[1])
			if c.Edge < 0 || c.Core < 0 {
				fail()
			}
		case "tags":
			a := list(cl, "tags", 1, -1)
			if haveTags {
				fail()
			}
			haveTags = true
			for _, t := range a {
				s := symOf(t)
				c.Tags = append(c.Tags, s)
				c.TagIDs = append(c.TagIDs, p.db.tagID(s))
			}
		case "keywords":
			a := list(cl, "keywords", 1, -1)
			if haveKw {
				fail()
			}
			haveKw = true
			for _, k := range a {
				ki := kwspec(k)
				c.Keywords = append(c.Keywords, ki)
				c.KwMask |= 1 << ki.K
			}
		case "text":
			a := list(cl, "text", 2, 2)
			if haveText {
				fail()
			}
			haveText, c.Text = true, strOf(a[0])
		case "resolve":
			if resolve != nil {
				fail()
			}
			resolve = p.ability(cl, AbResolve)
		case "on":
			ons = append(ons, p.ability(cl, AbOn))
		case "act":
			acts = append(acts, p.ability(cl, AbAct))
		case "aura":
			auras = append(auras, p.auraAbility(cl))
		default:
			fail()
		}
	}
	if !haveName || !haveType || !haveCost {
		fail()
	}
	if (c.Type == Unit) != haveBody {
		fail()
	}
	if (c.Type == Rite) != (resolve != nil) {
		fail()
	}
	for _, k := range c.Keywords {
		switch {
		case k.K == Swift:
			if c.Type != Rite {
				fail()
			}
		default:
			if c.Type != Unit {
				fail()
			}
		}
	}
	if resolve != nil {
		c.Abilities = append(c.Abilities, resolve)
	}
	c.Abilities = append(c.Abilities, ons...)
	c.Abilities = append(c.Abilities, acts...)
	c.Abilities = append(c.Abilities, auras...)
	for i, a := range c.Abilities {
		if a.Kind == AbOn {
			c.ByEvent[a.Event] = append(c.ByEvent[a.Event], i+1)
		}
	}
	return c
}

// ability parses a resolve, on or act clause.
func (p *parser) ability(cl *sexpr.Node, kind AbilityKind) *Ability {
	a := &Ability{Kind: kind, TargetsText: "-"}
	items := cl.Items[1:]
	if kind == AbOn {
		if len(items) == 0 {
			fail()
		}
		a.Event = eventOf(items[0])
		items = items[1:]
	}
	var haveCost, haveTargets bool
	var effects []string
	i := 0
	for ; i < len(items); i++ {
		it := items[i]
		h := it.Head()
		if h == "cost" {
			if kind != AbAct || haveCost {
				fail()
			}
			haveCost = true
			a.Cost = costItems(it)
			a.CostText = it.String()
		} else if h == "targets" {
			if haveTargets {
				fail()
			}
			haveTargets = true
			a.Targets = targetSpecs(p, it)
			a.TargetsText = it.String()
		} else {
			break
		}
	}
	if kind == AbAct && !haveCost {
		fail()
	}
	rest := items[i:]
	if len(rest) == 0 {
		fail()
	}
	for _, e := range rest {
		a.Effects = append(a.Effects, p.effect(e))
		effects = append(effects, e.String())
	}
	a.BodyText = strings.Join(effects, " ")
	return a
}

func eventOf(n *sexpr.Node) Event {
	s := symOf(n)
	for i, name := range eventNames {
		if name == s {
			return Event(i)
		}
	}
	fail()
	return 0
}

func costItems(n *sexpr.Node) []CostItem {
	var out []CostItem
	for _, it := range list(n, "cost", 1, -1) {
		if it.Kind != sexpr.List || len(it.Items) == 0 {
			fail()
		}
		switch it.Items[0].Text {
		case "ember":
			out = append(out, CostItem{CostEmber, intOf(list(it, "ember", 2, 2)[0])})
		case "spire":
			out = append(out, CostItem{CostSpire, intOf(list(it, "spire", 2, 2)[0])})
		case "discard":
			out = append(out, CostItem{CostDiscard, intOf(list(it, "discard", 2, 2)[0])})
		case "counters":
			out = append(out, CostItem{CostCounters, intOf(list(it, "counters", 2, 2)[0])})
		case "exhaust":
			list(it, "exhaust", 1, 1)
			out = append(out, CostItem{Kind: CostExhaust})
		case "sacself":
			list(it, "sacself", 1, 1)
			out = append(out, CostItem{Kind: CostSacself})
		case "once":
			list(it, "once", 1, 1)
			out = append(out, CostItem{Kind: CostOnce})
		default:
			fail()
		}
	}
	return out
}

func targetSpecs(p *parser, n *sexpr.Node) []TargetSpec {
	args := list(n, "targets", 2, -1)
	var out []TargetSpec
	for _, t := range args {
		if t.Kind != sexpr.List || len(t.Items) == 0 {
			fail()
		}
		switch t.Items[0].Text {
		case "unit":
			out = append(out, TargetSpec{TSUnit, p.filters(t.Items[1:])})
		case "relic":
			out = append(out, TargetSpec{TSRelic, p.filters(t.Items[1:])})
		case "any":
			out = append(out, TargetSpec{TSAny, p.filters(t.Items[1:])})
		case "ashcard":
			out = append(out, TargetSpec{TSAshcard, p.filters(t.Items[1:])})
		case "player":
			list(t, "player", 1, 1)
			out = append(out, TargetSpec{Kind: TSPlayer})
		case "chained":
			list(t, "chained", 1, 1)
			out = append(out, TargetSpec{Kind: TSChained})
		default:
			fail()
		}
	}
	return out
}

func (p *parser) auraAbility(cl *sexpr.Node) *Ability {
	a := &Ability{Kind: AbAura, TargetsText: "-"}
	args := list(cl, "aura", 2, -1)
	p.deps = 0
	var texts []string
	var statics []*Static
	for _, s := range args {
		statics = append(statics, p.static(s))
		texts = append(texts, s.String())
	}
	for _, s := range statics {
		flatten(s, nil, p.deps, &a.Leaves)
	}
	a.BodyText = strings.Join(texts, " ")
	return a
}

func flatten(s *Static, conds []*Cond, deps Dep, out *[]Leaf) {
	if s.Kind != StWhen {
		cs := append([]*Cond(nil), conds...)
		*out = append(*out, Leaf{S: s, Conds: cs, Deps: deps})
		return
	}
	nc := append(append([]*Cond(nil), conds...), s.Cond)
	for _, sub := range s.Subs {
		flatten(sub, nc, deps, out)
	}
}

func (p *parser) static(n *sexpr.Node) *Static {
	if n.Kind != sexpr.List || len(n.Items) == 0 {
		fail()
	}
	switch n.Items[0].Text {
	case "modify":
		a := list(n, "modify", 4, 4)
		return &Static{Kind: StModify, A: p.amount(a[0]), B: p.amount(a[1]), Sel: p.objSel(a[2])}
	case "setbody":
		a := list(n, "setbody", 4, 4)
		return &Static{Kind: StSetbody, A: p.amount(a[0]), B: p.amount(a[1]), Sel: p.objSel(a[2])}
	case "swapstats":
		a := list(n, "swapstats", 2, 2)
		return &Static{Kind: StSwap, Sel: p.objSel(a[0])}
	case "grant":
		a := list(n, "grant", 3, 3)
		return &Static{Kind: StGrant, Kw: kwspec(a[0]), Sel: p.objSel(a[1])}
	case "cheaper":
		a := list(n, "cheaper", 2, -1)
		s := &Static{Kind: StCheaper, Cheaper: intOf(a[0])}
		for _, f := range a[1:] {
			s.CardF = append(s.CardF, cardFilter(p, f))
		}
		return s
	case "when":
		a := list(n, "when", 2, -1)
		s := &Static{Kind: StWhen, Cond: p.cond(a[0])}
		for _, sub := range a[1:] {
			s.Subs = append(s.Subs, p.static(sub))
		}
		return s
	}
	fail()
	return nil
}

func cardFilter(p *parser, n *sexpr.Node) CardFilter {
	if n.Kind != sexpr.List || len(n.Items) == 0 {
		fail()
	}
	switch n.Items[0].Text {
	case "type":
		a := list(n, "type", 2, 2)
		return CardFilter{Kind: FType, Type: typeOf(a[0])}
	case "tag":
		a := list(n, "tag", 2, 2)
		return CardFilter{Kind: FTag, Tag: p.db.tagID(symOf(a[0]))}
	case "cost":
		a := list(n, "cost", 3, 3)
		return CardFilter{Kind: FCost, Cmp: cmpOf(a[0]), N: intOf(a[1])}
	}
	fail()
	return CardFilter{}
}

// -------------------------------------------------------------- selectors ---

func (p *parser) filters(ns []*sexpr.Node) []Filter {
	var out []Filter
	for _, n := range ns {
		out = append(out, p.filter(n))
	}
	return out
}

func (p *parser) filter(n *sexpr.Node) Filter {
	if n.Kind != sexpr.List || len(n.Items) == 0 {
		fail()
	}
	switch n.Items[0].Text {
	case "kw":
		a := list(n, "kw", 2, 2)
		return Filter{Kind: FKw, Kw: keywordOf(a[0])}
	case "no-kw":
		a := list(n, "no-kw", 2, 2)
		return Filter{Kind: FNoKw, Kw: keywordOf(a[0])}
	case "tag":
		a := list(n, "tag", 2, 2)
		return Filter{Kind: FTag, Tag: p.db.tagID(symOf(a[0]))}
	case "type":
		a := list(n, "type", 2, 2)
		return Filter{Kind: FType, Type: typeOf(a[0])}
	case "cost", "edge", "core":
		kind := map[string]FilterKind{"cost": FCost, "edge": FEdge, "core": FCore}[n.Items[0].Text]
		a := list(n, n.Items[0].Text, 3, 3)
		return Filter{Kind: kind, Cmp: cmpOf(a[0]), N: intOf(a[1])}
	case "wounded":
		list(n, "wounded", 1, 1)
		p.deps |= DepWounds
		return Filter{Kind: FWounded}
	case "ready":
		list(n, "ready", 1, 1)
		p.deps |= DepReady
		return Filter{Kind: FReady}
	case "exhausted":
		list(n, "exhausted", 1, 1)
		p.deps |= DepReady
		return Filter{Kind: FExhausted}
	case "settling":
		list(n, "settling", 1, 1)
		p.deps |= DepTurn
		return Filter{Kind: FSettling}
	case "attacking":
		list(n, "attacking", 1, 1)
		p.deps |= DepCombat
		return Filter{Kind: FAttacking}
	case "blocking":
		list(n, "blocking", 1, 1)
		p.deps |= DepCombat
		return Filter{Kind: FBlocking}
	case "mine":
		list(n, "mine", 1, 1)
		return Filter{Kind: FMine}
	case "enemy":
		list(n, "enemy", 1, 1)
		return Filter{Kind: FEnemy}
	case "other":
		list(n, "other", 1, 1)
		return Filter{Kind: FOther}
	case "not":
		a := list(n, "not", 2, 2)
		inner := p.filter(a[0])
		return Filter{Kind: FNot, Inner: &inner}
	}
	fail()
	return Filter{}
}

func (p *parser) objSel(n *sexpr.Node) *Sel {
	if n.Kind == sexpr.Symbol {
		switch n.Text {
		case "self":
			return &Sel{Kind: SelSelf}
		case "it":
			return &Sel{Kind: SelIt}
		case "that":
			return &Sel{Kind: SelThat}
		}
		fail()
	}
	if n.Kind != sexpr.List || len(n.Items) == 0 {
		fail()
	}
	switch n.Items[0].Text {
	case "t":
		return p.tSel(n)
	case "units":
		a := list(n, "units", 2, -1)
		return &Sel{Kind: SelUnits, Scope: scopeOf(a[0]), Filters: p.filters(a[1:])}
	case "relics":
		a := list(n, "relics", 2, -1)
		return &Sel{Kind: SelRelics, Scope: scopeOf(a[0]), Filters: p.filters(a[1:])}
	case "random-unit":
		a := list(n, "random-unit", 2, -1)
		return &Sel{Kind: SelRandomUnit, Scope: scopeOf(a[0]), Filters: p.filters(a[1:])}
	case "cards":
		a := list(n, "cards", 3, -1)
		var z Zone
		switch symOf(a[0]) {
		case "hand":
			z = ZoneHand
		case "ash":
			z = ZoneAsh
		case "vault":
			z = ZoneVault
		case "rift":
			z = ZoneRift
		default:
			fail()
		}
		p.deps |= DepZones
		return &Sel{Kind: SelCards, Zone: z, Scope: scopeOf(a[1]), Filters: p.filters(a[2:])}
	}
	fail()
	return nil
}

func (p *parser) tSel(n *sexpr.Node) *Sel {
	a := list(n, "t", 2, 2)
	v := intOf(a[0])
	if v < 1 || v > 1<<20 {
		fail()
	}
	return &Sel{Kind: SelT, N: int(v)}
}

func (p *parser) playerSel(n *sexpr.Node) *Sel {
	if n.Kind == sexpr.Symbol {
		switch n.Text {
		case "you":
			return &Sel{Kind: SelYou}
		case "foe":
			return &Sel{Kind: SelFoe}
		case "both":
			return &Sel{Kind: SelBoth}
		}
		fail()
	}
	if n.Kind != sexpr.List || len(n.Items) == 0 {
		fail()
	}
	switch n.Items[0].Text {
	case "t":
		return p.tSel(n)
	case "owner-of":
		a := list(n, "owner-of", 2, 2)
		return &Sel{Kind: SelOwnerOf, Inner: p.objSel(a[0])}
	}
	fail()
	return nil
}

// dmgSel parses the second argument of damage.
func (p *parser) dmgSel(n *sexpr.Node) *Sel {
	if n.Kind == sexpr.Symbol && (n.Text == "you" || n.Text == "foe" || n.Text == "both") {
		return p.playerSel(n)
	}
	if n.Head() == "owner-of" {
		return p.playerSel(n)
	}
	return p.objSel(n)
}

func (p *parser) amount(n *sexpr.Node) Amount {
	if n.Kind == sexpr.Int {
		return Amount{Kind: AmtConst, N: n.Int}
	}
	if n.Kind != sexpr.List || len(n.Items) == 0 {
		fail()
	}
	switch n.Items[0].Text {
	case "count":
		a := list(n, "count", 2, 2)
		return Amount{Kind: AmtCount, Sel: p.objSel(a[0])}
	case "hand":
		a := list(n, "hand", 2, 2)
		p.deps |= DepZones
		return Amount{Kind: AmtHand, Sel: p.playerSel(a[0])}
	case "ash":
		a := list(n, "ash", 2, 2)
		p.deps |= DepZones
		return Amount{Kind: AmtAsh, Sel: p.playerSel(a[0])}
	case "vault":
		a := list(n, "vault", 2, 2)
		p.deps |= DepZones
		return Amount{Kind: AmtVault, Sel: p.playerSel(a[0])}
	case "edge":
		a := list(n, "edge", 2, 2)
		return Amount{Kind: AmtEdge, Sel: p.objSel(a[0])}
	case "core":
		a := list(n, "core", 2, 2)
		return Amount{Kind: AmtCore, Sel: p.objSel(a[0])}
	case "wounds":
		a := list(n, "wounds", 2, 2)
		p.deps |= DepWounds
		return Amount{Kind: AmtWounds, Sel: p.objSel(a[0])}
	}
	fail()
	return Amount{}
}

func (p *parser) cond(n *sexpr.Node) *Cond {
	if n.Kind != sexpr.List || len(n.Items) == 0 {
		fail()
	}
	switch h := n.Items[0].Text; h {
	case "count":
		a := list(n, h, 4, 4)
		return &Cond{Kind: CondCount, Sel: p.objSel(a[0]), Cmp: cmpOf(a[1]), N: intOf(a[2])}
	case "spire", "hand", "ash", "vault", "ember":
		a := list(n, h, 4, 4)
		kind := map[string]CondKind{"spire": CondSpire, "hand": CondHand, "ash": CondAsh,
			"vault": CondVault, "ember": CondEmber}[h]
		p.deps |= map[string]Dep{"spire": DepSpire, "hand": DepZones, "ash": DepZones,
			"vault": DepZones, "ember": DepEmber}[h]
		return &Cond{Kind: kind, Sel: p.playerSel(a[0]), Cmp: cmpOf(a[1]), N: intOf(a[2])}
	case "myturn":
		list(n, h, 1, 1)
		p.deps |= DepTurn
		return &Cond{Kind: CondMyTurn}
	case "and", "or":
		a := list(n, h, 1, -1)
		c := &Cond{Kind: CondAnd}
		if h == "or" {
			c.Kind = CondOr
		}
		for _, s := range a {
			c.Subs = append(c.Subs, p.cond(s))
		}
		return c
	case "not":
		a := list(n, h, 2, 2)
		return &Cond{Kind: CondNot, Subs: []*Cond{p.cond(a[0])}}
	}
	fail()
	return nil
}

// ---------------------------------------------------------------- effects ---

func (p *parser) effects(ns []*sexpr.Node) []*Effect {
	out := make([]*Effect, 0, len(ns))
	for _, n := range ns {
		out = append(out, p.effect(n))
	}
	return out
}

// effectList parses a parenthesised list of effects.
func (p *parser) effectList(n *sexpr.Node) []*Effect {
	if n.Kind != sexpr.List {
		fail()
	}
	return p.effects(n.Items)
}

func (p *parser) effect(n *sexpr.Node) *Effect {
	if n.Kind != sexpr.List || len(n.Items) == 0 || n.Items[0].Kind != sexpr.Symbol {
		fail()
	}
	h := n.Items[0].Text
	switch h {
	case "damage":
		a := list(n, h, 3, 3)
		return &Effect{Kind: EffDamage, A: p.amount(a[0]), Sel: p.dmgSel(a[1])}
	case "destroy", "sacrifice", "exile", "bounce", "ready", "exhaust", "doom", "strip", "control",
		"reanimate", "recall", "swapstats":
		a := list(n, h, 2, 2)
		kind := map[string]EffKind{"destroy": EffDestroy, "sacrifice": EffSacrifice, "exile": EffExile,
			"bounce": EffBounce, "ready": EffReady, "exhaust": EffExhaust, "doom": EffDoom,
			"strip": EffStrip, "control": EffControl, "reanimate": EffReanimate, "recall": EffRecall,
			"swapstats": EffSwapstats}[h]
		return &Effect{Kind: kind, Sel: p.objSel(a[0])}
	case "draw", "discard", "mill", "spire", "ember", "cap", "shield":
		a := list(n, h, 3, 3)
		kind := map[string]EffKind{"draw": EffDraw, "discard": EffDiscard, "mill": EffMill,
			"spire": EffSpire, "ember": EffEmber, "cap": EffCap, "shield": EffShield}[h]
		return &Effect{Kind: kind, A: p.amount(a[0]), Sel: p.playerSel(a[1])}
	case "modify", "setbody":
		a := list(n, h, 4, 4)
		kind := EffModify
		if h == "setbody" {
			kind = EffSetbody
		}
		return &Effect{Kind: kind, A: p.amount(a[0]), B: p.amount(a[1]), Sel: p.objSel(a[2])}
	case "grant":
		a := list(n, h, 3, 3)
		return &Effect{Kind: EffGrant, Kw: kwspec(a[0]), Sel: p.objSel(a[1])}
	case "counters", "ward":
		a := list(n, h, 3, 3)
		kind := EffCounters
		if h == "ward" {
			kind = EffWard
		}
		return &Effect{Kind: kind, A: p.amount(a[0]), Sel: p.objSel(a[1])}
	case "summon", "conjure":
		a := list(n, h, 4, 4)
		id := symOf(a[0])
		if !validCardID(id) {
			fail()
		}
		kind := EffSummon
		if h == "conjure" {
			kind = EffConjure
		}
		return &Effect{Kind: kind, CardID: id, A: p.amount(a[1]), Sel: p.playerSel(a[2])}
	case "negate":
		a := list(n, h, 2, 2)
		if a[0].Head() != "t" {
			fail()
		}
		return &Effect{Kind: EffNegate, Sel: p.tSel(a[0])}
	case "dig":
		a := list(n, h, 4, 4)
		if a[1].Kind != sexpr.List {
			fail()
		}
		return &Effect{Kind: EffDig, DigK: intOf(a[0]), Filters: p.filters(a[1].Items), Sel: p.playerSel(a[2])}
	case "delay":
		a := list(n, h, 2, -1)
		var w When
		switch symOf(a[0]) {
		case "turn-end":
			w = TurnEnd
		case "end-of-combat":
			w = EndOfCombat
		case "your-next-turn-start":
			w = YourNextTurnStart
		default:
			fail()
		}
		return &Effect{Kind: EffDelay, When: w, Body: p.effects(a[1:])}
	case "if":
		a := list(n, h, 3, 4)
		e := &Effect{Kind: EffIf, Cond: p.cond(a[0]), Body: p.effectList(a[1])}
		if len(a) == 3 {
			e.HasElse = true
			e.Else = p.effectList(a[2])
		}
		return e
	case "each":
		a := list(n, h, 2, -1)
		return &Effect{Kind: EffEach, Sel: p.objSel(a[0]), Body: p.effects(a[1:])}
	case "repeat":
		a := list(n, h, 2, -1)
		return &Effect{Kind: EffRepeat, A: p.amount(a[0]), Body: p.effects(a[1:])}
	case "nothing":
		list(n, h, 1, 1)
		return &Effect{Kind: EffNothing}
	}
	fail()
	return nil
}
