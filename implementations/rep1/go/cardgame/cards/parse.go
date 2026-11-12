package cards

import (
	"errors"
	"fmt"
	"os"
	"regexp"

	"github.com/spiremark/cardgame/sexpr"
)

// ErrBadDatabase is wrapped by every error returned from Parse and Load that
// stems from an unreadable or invalid database.
var ErrBadDatabase = errors.New("bad database")

func bad(format string, args ...any) error {
	return fmt.Errorf("%w: %s", ErrBadDatabase, fmt.Sprintf(format, args...))
}

var cardIDRe = regexp.MustCompile(`^[A-Z]{3}-[0-9]{3}$`)

// Load reads and validates the database at path.
func Load(path string) (*Database, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, bad("%v", err)
	}
	return Parse(string(data))
}

// Parse validates src as a card database (SPEC section 5).
func Parse(src string) (*Database, error) {
	nodes, err := sexpr.ParseAll(src)
	if err != nil {
		return nil, bad("%v", err)
	}
	db := &Database{byID: map[string]*Card{}}
	for _, n := range nodes {
		c, err := parseCard(n)
		if err != nil {
			return nil, err
		}
		if _, dup := db.byID[c.ID]; dup {
			return nil, bad("duplicate card %s", c.ID)
		}
		db.byID[c.ID] = c
		db.order = append(db.order, c)
	}
	for _, c := range db.order {
		for _, ab := range c.Abilities {
			if err := checkRefs(db, ab.Effects); err != nil {
				return nil, err
			}
		}
	}
	return db, nil
}

func checkRefs(db *Database, effs []*Effect) error {
	for _, e := range effs {
		if e.Op == OpSummon || e.Op == OpConjure {
			c, ok := db.byID[e.CardID]
			if !ok {
				return bad("unknown card %s", e.CardID)
			}
			if e.Op == OpSummon && c.Type == Rite {
				return bad("summon of rite %s", e.CardID)
			}
		}
		if err := checkRefs(db, e.Body); err != nil {
			return err
		}
		if err := checkRefs(db, e.Else); err != nil {
			return err
		}
	}
	return nil
}

func parseCard(n sexpr.Node) (*Card, error) {
	name, args, ok := n.Head()
	if !ok || name != "card" {
		return nil, bad("top-level form is not a card")
	}
	if len(args) < 1 || args[0].Kind != sexpr.Symbol || !cardIDRe.MatchString(args[0].Text) {
		return nil, bad("bad card id")
	}
	c := &Card{ID: args[0].Text}
	var seenName, seenType, seenCost, seenBody, seenTags, seenKW, seenText, seenResolve bool
	var resolve *Ability
	var ons, acts, auras []*Ability
	for _, cl := range args[1:] {
		h, a, ok := cl.Head()
		if !ok {
			return nil, bad("%s: malformed clause", c.ID)
		}
		switch h {
		case "name":
			if seenName || len(a) != 1 || a[0].Kind != sexpr.String {
				return nil, bad("%s: bad name", c.ID)
			}
			seenName, c.Name = true, a[0].Text
		case "type":
			if seenType || len(a) != 1 || a[0].Kind != sexpr.Symbol {
				return nil, bad("%s: bad type", c.ID)
			}
			switch a[0].Text {
			case "unit":
				c.Type = Unit
			case "rite":
				c.Type = Rite
			case "relic":
				c.Type = Relic
			default:
				return nil, bad("%s: unknown type", c.ID)
			}
			seenType = true
		case "cost":
			if seenCost || len(a) != 1 || a[0].Kind != sexpr.Int || a[0].Num < 0 {
				return nil, bad("%s: bad cost", c.ID)
			}
			seenCost, c.Cost = true, int(a[0].Num)
		case "body":
			if seenBody || len(a) != 2 || a[0].Kind != sexpr.Int || a[1].Kind != sexpr.Int ||
				a[0].Num < 0 || a[1].Num < 0 {
				return nil, bad("%s: bad body", c.ID)
			}
			seenBody, c.Edge, c.Core = true, int(a[0].Num), int(a[1].Num)
		case "tags":
			if seenTags {
				return nil, bad("%s: tags twice", c.ID)
			}
			seenTags = true
			for _, t := range a {
				if t.Kind != sexpr.Symbol {
					return nil, bad("%s: tag is not a symbol", c.ID)
				}
				c.Tags = append(c.Tags, t.Text)
			}
		case "keywords":
			if seenKW {
				return nil, bad("%s: keywords twice", c.ID)
			}
			seenKW = true
			for _, k := range a {
				kw, err := parseKwSpec(k)
				if err != nil {
					return nil, bad("%s: %v", c.ID, err)
				}
				c.Keywords = append(c.Keywords, kw)
				c.keywordMask |= 1 << uint(kw.K)
			}
		case "text":
			if seenText || len(a) != 1 || a[0].Kind != sexpr.String {
				return nil, bad("%s: bad text", c.ID)
			}
			seenText, c.Text = true, a[0].Text
		case "resolve":
			if seenResolve {
				return nil, bad("%s: resolve twice", c.ID)
			}
			seenResolve = true
			ab, err := parseAbility(AbResolve, 0, a)
			if err != nil {
				return nil, bad("%s: %v", c.ID, err)
			}
			resolve = ab
		case "on":
			if len(a) < 1 || a[0].Kind != sexpr.Symbol {
				return nil, bad("%s: bad on clause", c.ID)
			}
			ev := -1
			for i, en := range eventNames {
				if en == a[0].Text {
					ev = i
				}
			}
			if ev < 0 {
				return nil, bad("%s: unknown event %s", c.ID, a[0].Text)
			}
			ab, err := parseAbility(AbOn, Event(ev), a[1:])
			if err != nil {
				return nil, bad("%s: %v", c.ID, err)
			}
			ons = append(ons, ab)
		case "act":
			ab, err := parseAbility(AbAct, 0, a)
			if err != nil {
				return nil, bad("%s: %v", c.ID, err)
			}
			acts = append(acts, ab)
		case "aura":
			ab, err := parseAura(a)
			if err != nil {
				return nil, bad("%s: %v", c.ID, err)
			}
			auras = append(auras, ab)
		default:
			return nil, bad("%s: unknown clause %s", c.ID, h)
		}
	}
	if !seenName || !seenType || !seenCost {
		return nil, bad("%s: missing name, type or cost", c.ID)
	}
	if (c.Type == Unit) != seenBody {
		return nil, bad("%s: body is required exactly on units", c.ID)
	}
	if (c.Type == Rite) != seenResolve {
		return nil, bad("%s: resolve is required exactly on rites", c.ID)
	}
	for _, kw := range c.Keywords {
		switch {
		case kw.K == Swift && c.Type != Rite:
			return nil, bad("%s: swift only on rites", c.ID)
		case kw.K != Swift && c.Type != Unit:
			return nil, bad("%s: keyword %s only on units", c.ID, kw.K)
		}
	}
	if resolve != nil {
		c.Abilities = append(c.Abilities, resolve)
	}
	c.Abilities = append(c.Abilities, ons...)
	c.Abilities = append(c.Abilities, acts...)
	c.Abilities = append(c.Abilities, auras...)
	for i, ab := range c.Abilities {
		ab.Index = i + 1
	}
	return c, nil
}

func parseKwSpec(n sexpr.Node) (KW, error) {
	if n.Kind == sexpr.Symbol {
		k, ok := KeywordByName(n.Text)
		if !ok || k == Plating {
			return KW{}, fmt.Errorf("bad keyword %q", n.Text)
		}
		return KW{K: k}, nil
	}
	h, a, ok := n.Head()
	if ok && h == "plating" && len(a) == 1 && a[0].Kind == sexpr.Int {
		return KW{K: Plating, N: int(a[0].Num)}, nil
	}
	return KW{}, fmt.Errorf("bad keyword spec %s", n)
}

func parseAbility(kind AbilityKind, ev Event, parts []sexpr.Node) (*Ability, error) {
	ab := &Ability{Kind: kind, Event: ev}
	seenCost, seenTargets, seenEffect := false, false, false
	for i := range parts {
		p := parts[i]
		h, a, ok := p.Head()
		if ok && h == "cost" {
			if kind != AbAct || seenCost || seenEffect {
				return nil, errors.New("misplaced cost clause")
			}
			seenCost = true
			for _, ci := range a {
				item, err := parseCostItem(ci)
				if err != nil {
					return nil, err
				}
				ab.Cost = append(ab.Cost, item)
			}
			pc := p
			ab.costNode = &pc
			continue
		}
		if ok && h == "targets" {
			if seenTargets || seenEffect {
				return nil, errors.New("misplaced targets clause")
			}
			seenTargets = true
			if len(a) == 0 {
				return nil, errors.New("empty targets clause")
			}
			for _, t := range a {
				ts, err := parseTargetSpec(t)
				if err != nil {
					return nil, err
				}
				ab.Targets = append(ab.Targets, ts)
			}
			pt := p
			ab.targetsNode = &pt
			continue
		}
		e, err := parseEffect(p)
		if err != nil {
			return nil, err
		}
		seenEffect = true
		ab.Effects = append(ab.Effects, e)
		ab.effectNodes = append(ab.effectNodes, p)
	}
	if kind == AbAct && !seenCost {
		return nil, errors.New("act without cost")
	}
	if len(ab.Effects) == 0 {
		return nil, errors.New("ability without effects")
	}
	return ab, nil
}

func parseAura(parts []sexpr.Node) (*Ability, error) {
	if len(parts) == 0 {
		return nil, errors.New("empty aura")
	}
	ab := &Ability{Kind: AbAura}
	for _, p := range parts {
		s, err := parseStatic(p)
		if err != nil {
			return nil, err
		}
		ab.Statics = append(ab.Statics, s)
		ab.effectNodes = append(ab.effectNodes, p)
	}
	return ab, nil
}

func parseCostItem(n sexpr.Node) (CostItem, error) {
	h, a, ok := n.Head()
	if !ok {
		return CostItem{}, fmt.Errorf("bad cost item %s", n)
	}
	intArg := func(k CostKind) (CostItem, error) {
		if len(a) != 1 || a[0].Kind != sexpr.Int {
			return CostItem{}, fmt.Errorf("bad cost item %s", n)
		}
		return CostItem{Kind: k, N: int(a[0].Num)}, nil
	}
	noArg := func(k CostKind) (CostItem, error) {
		if len(a) != 0 {
			return CostItem{}, fmt.Errorf("bad cost item %s", n)
		}
		return CostItem{Kind: k}, nil
	}
	switch h {
	case "ember":
		return intArg(CostEmber)
	case "spire":
		return intArg(CostSpire)
	case "discard":
		return intArg(CostDiscard)
	case "counters":
		return intArg(CostCounters)
	case "exhaust":
		return noArg(CostExhaust)
	case "sacself":
		return noArg(CostSacself)
	case "once":
		return noArg(CostOnce)
	}
	return CostItem{}, fmt.Errorf("bad cost item %s", n)
}

func parseTargetSpec(n sexpr.Node) (TargetSpec, error) {
	h, a, ok := n.Head()
	if !ok {
		return TargetSpec{}, fmt.Errorf("bad target spec %s", n)
	}
	var kind TSKind
	filtered := true
	switch h {
	case "unit":
		kind = TSUnit
	case "relic":
		kind = TSRelic
	case "any":
		kind = TSAny
	case "ashcard":
		kind = TSAshcard
	case "player":
		kind, filtered = TSPlayer, false
	case "chained":
		kind, filtered = TSChained, false
	default:
		return TargetSpec{}, fmt.Errorf("bad target spec %s", n)
	}
	ts := TargetSpec{Kind: kind}
	if !filtered {
		if len(a) != 0 {
			return TargetSpec{}, fmt.Errorf("bad target spec %s", n)
		}
		return ts, nil
	}
	fs, err := parseFilters(a)
	if err != nil {
		return TargetSpec{}, err
	}
	ts.Filters = fs
	return ts, nil
}

func parseCmp(n sexpr.Node) (Cmp, error) {
	if n.Kind == sexpr.Symbol {
		for i, s := range cmpNames {
			if s == n.Text {
				return Cmp(i), nil
			}
		}
	}
	return 0, fmt.Errorf("bad comparator %s", n)
}

func parseFilters(ns []sexpr.Node) ([]Filter, error) {
	var out []Filter
	for _, n := range ns {
		f, err := parseFilter(n)
		if err != nil {
			return nil, err
		}
		out = append(out, f)
	}
	return out, nil
}

func parseFilter(n sexpr.Node) (Filter, error) {
	h, a, ok := n.Head()
	if !ok {
		return Filter{}, fmt.Errorf("bad filter %s", n)
	}
	errf := func() (Filter, error) { return Filter{}, fmt.Errorf("bad filter %s", n) }
	switch h {
	case "kw", "no-kw":
		if len(a) != 1 || a[0].Kind != sexpr.Symbol {
			return errf()
		}
		k, ok := KeywordByName(a[0].Text)
		if !ok {
			return errf()
		}
		kind := FKw
		if h == "no-kw" {
			kind = FNoKw
		}
		return Filter{Kind: kind, KW: k}, nil
	case "tag":
		if len(a) != 1 || a[0].Kind != sexpr.Symbol {
			return errf()
		}
		return Filter{Kind: FTag, Tag: a[0].Text}, nil
	case "type":
		if len(a) != 1 || a[0].Kind != sexpr.Symbol {
			return errf()
		}
		for i, s := range typeNames {
			if s == a[0].Text {
				return Filter{Kind: FType, Type: Type(i)}, nil
			}
		}
		return errf()
	case "cost", "edge", "core":
		if len(a) != 2 || a[1].Kind != sexpr.Int {
			return errf()
		}
		c, err := parseCmp(a[0])
		if err != nil {
			return Filter{}, err
		}
		kind := map[string]FilterKind{"cost": FCost, "edge": FEdge, "core": FCore}[h]
		return Filter{Kind: kind, Cmp: c, N: int(a[1].Num)}, nil
	case "wounded", "ready", "exhausted", "settling", "attacking", "blocking", "mine", "enemy", "other":
		if len(a) != 0 {
			return errf()
		}
		kind := map[string]FilterKind{
			"wounded": FWounded, "ready": FReady, "exhausted": FExhausted,
			"settling": FSettling, "attacking": FAttacking, "blocking": FBlocking,
			"mine": FMine, "enemy": FEnemy, "other": FOther,
		}[h]
		return Filter{Kind: kind}, nil
	case "not":
		if len(a) != 1 {
			return errf()
		}
		inner, err := parseFilter(a[0])
		if err != nil {
			return Filter{}, err
		}
		return Filter{Kind: FNot, Not: &inner}, nil
	}
	return errf()
}

func parseTargetRef(a []sexpr.Node) (int, bool) {
	if len(a) == 1 && a[0].Kind == sexpr.Int && a[0].Num >= 1 && a[0].Num <= 1<<30 {
		return int(a[0].Num), true
	}
	return 0, false
}

func parseScope(n sexpr.Node) (Scope, error) {
	if n.Kind == sexpr.Symbol {
		switch n.Text {
		case "yours":
			return Yours, nil
		case "theirs":
			return Theirs, nil
		case "all":
			return All, nil
		}
	}
	return 0, fmt.Errorf("bad scope %s", n)
}

func parseSelector(n sexpr.Node) (*Selector, error) {
	if n.Kind == sexpr.Symbol {
		switch n.Text {
		case "self":
			return &Selector{Kind: SelSelf}, nil
		case "it":
			return &Selector{Kind: SelIt}, nil
		case "that":
			return &Selector{Kind: SelThat}, nil
		}
		return nil, fmt.Errorf("bad selector %s", n)
	}
	h, a, ok := n.Head()
	if !ok {
		return nil, fmt.Errorf("bad selector %s", n)
	}
	switch h {
	case "t":
		t, ok := parseTargetRef(a)
		if !ok {
			return nil, fmt.Errorf("bad selector %s", n)
		}
		return &Selector{Kind: SelTarget, N: t}, nil
	case "units", "relics", "random-unit":
		if len(a) < 1 {
			return nil, fmt.Errorf("bad selector %s", n)
		}
		sc, err := parseScope(a[0])
		if err != nil {
			return nil, err
		}
		fs, err := parseFilters(a[1:])
		if err != nil {
			return nil, err
		}
		kind := map[string]SelKind{"units": SelUnits, "relics": SelRelics, "random-unit": SelRandomUnit}[h]
		return &Selector{Kind: kind, Scope: sc, Filters: fs}, nil
	case "cards":
		if len(a) < 2 || a[0].Kind != sexpr.Symbol {
			return nil, fmt.Errorf("bad selector %s", n)
		}
		z := -1
		for i, s := range []string{"hand", "ash", "vault", "rift"} {
			if s == a[0].Text {
				z = i
			}
		}
		if z < 0 {
			return nil, fmt.Errorf("bad zone in %s", n)
		}
		sc, err := parseScope(a[1])
		if err != nil {
			return nil, err
		}
		fs, err := parseFilters(a[2:])
		if err != nil {
			return nil, err
		}
		return &Selector{Kind: SelCards, Zone: CardZone(z), Scope: sc, Filters: fs}, nil
	}
	return nil, fmt.Errorf("bad selector %s", n)
}

func parsePlayerSel(n sexpr.Node) (*PlayerSel, error) {
	if n.Kind == sexpr.Symbol {
		switch n.Text {
		case "you":
			return &PlayerSel{Kind: PYou}, nil
		case "foe":
			return &PlayerSel{Kind: PFoe}, nil
		case "both":
			return &PlayerSel{Kind: PBoth}, nil
		}
		return nil, fmt.Errorf("bad player selector %s", n)
	}
	h, a, ok := n.Head()
	if !ok {
		return nil, fmt.Errorf("bad player selector %s", n)
	}
	switch h {
	case "t":
		t, ok := parseTargetRef(a)
		if !ok {
			return nil, fmt.Errorf("bad player selector %s", n)
		}
		return &PlayerSel{Kind: PTarget, N: t}, nil
	case "owner-of":
		if len(a) != 1 {
			return nil, fmt.Errorf("bad player selector %s", n)
		}
		s, err := parseSelector(a[0])
		if err != nil {
			return nil, err
		}
		return &PlayerSel{Kind: POwnerOf, Sel: s}, nil
	}
	return nil, fmt.Errorf("bad player selector %s", n)
}

func parseDSel(n sexpr.Node) (*DSel, error) {
	isPlayer := false
	if n.Kind == sexpr.Symbol {
		isPlayer = n.Text == "you" || n.Text == "foe" || n.Text == "both"
	} else if h, _, ok := n.Head(); ok {
		isPlayer = h == "owner-of"
	}
	if isPlayer {
		p, err := parsePlayerSel(n)
		if err != nil {
			return nil, err
		}
		return &DSel{Player: p}, nil
	}
	s, err := parseSelector(n)
	if err != nil {
		return nil, err
	}
	return &DSel{Obj: s}, nil
}

func parseAmount(n sexpr.Node) (*Amount, error) {
	if n.Kind == sexpr.Int {
		return &Amount{Kind: AConst, N: int(n.Num)}, nil
	}
	h, a, ok := n.Head()
	if !ok || len(a) != 1 {
		return nil, fmt.Errorf("bad amount %s", n)
	}
	switch h {
	case "count", "edge", "core", "wounds":
		s, err := parseSelector(a[0])
		if err != nil {
			return nil, err
		}
		kind := map[string]AmtKind{"count": ACount, "edge": AEdge, "core": ACore, "wounds": AWounds}[h]
		return &Amount{Kind: kind, Sel: s}, nil
	case "hand", "ash", "vault":
		p, err := parsePlayerSel(a[0])
		if err != nil {
			return nil, err
		}
		kind := map[string]AmtKind{"hand": AHand, "ash": AAsh, "vault": AVault}[h]
		return &Amount{Kind: kind, PSel: p}, nil
	}
	return nil, fmt.Errorf("bad amount %s", n)
}

func parseCond(n sexpr.Node) (*Cond, error) {
	h, a, ok := n.Head()
	if !ok {
		return nil, fmt.Errorf("bad condition %s", n)
	}
	errf := func() (*Cond, error) { return nil, fmt.Errorf("bad condition %s", n) }
	switch h {
	case "myturn":
		if len(a) != 0 {
			return errf()
		}
		return &Cond{Kind: CMyTurn}, nil
	case "and", "or":
		c := &Cond{Kind: CAnd}
		if h == "or" {
			c.Kind = COr
		}
		for _, s := range a {
			sub, err := parseCond(s)
			if err != nil {
				return nil, err
			}
			c.Subs = append(c.Subs, sub)
		}
		return c, nil
	case "not":
		if len(a) != 1 {
			return errf()
		}
		sub, err := parseCond(a[0])
		if err != nil {
			return nil, err
		}
		return &Cond{Kind: CNot, Subs: []*Cond{sub}}, nil
	case "count", "spire", "hand", "ash", "vault", "ember":
		if len(a) != 3 || a[2].Kind != sexpr.Int {
			return errf()
		}
		cmp, err := parseCmp(a[1])
		if err != nil {
			return nil, err
		}
		c := &Cond{Cmp: cmp, N: int(a[2].Num)}
		if h == "count" {
			c.Kind = CCount
			c.Sel, err = parseSelector(a[0])
		} else {
			c.Kind = map[string]CondKind{"spire": CSpire, "hand": CHand, "ash": CAsh, "vault": CVault, "ember": CEmber}[h]
			c.PSel, err = parsePlayerSel(a[0])
		}
		if err != nil {
			return nil, err
		}
		return c, nil
	}
	return errf()
}

func parseEffects(ns []sexpr.Node) ([]*Effect, error) {
	var out []*Effect
	for _, n := range ns {
		e, err := parseEffect(n)
		if err != nil {
			return nil, err
		}
		out = append(out, e)
	}
	return out, nil
}

func parseEffect(n sexpr.Node) (*Effect, error) {
	h, a, ok := n.Head()
	if !ok {
		return nil, fmt.Errorf("bad effect %s", n)
	}
	e := &Effect{Node: n}
	errf := func() (*Effect, error) { return nil, fmt.Errorf("bad effect %s", n) }
	var err error
	// Shapes: s = selector, p = player selector, a = amount.
	shape := func(op Op, want string) (*Effect, error) {
		if len(a) != len(want) {
			return errf()
		}
		e.Op = op
		var amts []*Amount
		for i, w := range want {
			switch w {
			case 'a':
				var am *Amount
				if am, err = parseAmount(a[i]); err != nil {
					return nil, err
				}
				amts = append(amts, am)
			case 's':
				if e.Sel, err = parseSelector(a[i]); err != nil {
					return nil, err
				}
			case 'p':
				if e.PSel, err = parsePlayerSel(a[i]); err != nil {
					return nil, err
				}
			case 'd':
				if e.DSel, err = parseDSel(a[i]); err != nil {
					return nil, err
				}
			}
		}
		if len(amts) > 0 {
			e.A1 = amts[0]
		}
		if len(amts) > 1 {
			e.A2 = amts[1]
		}
		return e, nil
	}
	switch h {
	case "damage":
		return shape(OpDamage, "ad")
	case "destroy":
		return shape(OpDestroy, "s")
	case "sacrifice":
		return shape(OpSacrifice, "s")
	case "exile":
		return shape(OpExile, "s")
	case "bounce":
		return shape(OpBounce, "s")
	case "draw":
		return shape(OpDraw, "ap")
	case "discard":
		return shape(OpDiscard, "ap")
	case "mill":
		return shape(OpMill, "ap")
	case "spire":
		return shape(OpSpire, "ap")
	case "ember":
		return shape(OpEmber, "ap")
	case "cap":
		return shape(OpCap, "ap")
	case "modify":
		return shape(OpModify, "aas")
	case "setbody":
		return shape(OpSetbody, "aas")
	case "swapstats":
		return shape(OpSwapstats, "s")
	case "strip":
		return shape(OpStrip, "s")
	case "control":
		return shape(OpControl, "s")
	case "counters":
		return shape(OpCounters, "as")
	case "ready":
		return shape(OpReady, "s")
	case "exhaust":
		return shape(OpExhaust, "s")
	case "doom":
		return shape(OpDoom, "s")
	case "ward":
		return shape(OpWard, "as")
	case "shield":
		return shape(OpShield, "ap")
	case "reanimate":
		return shape(OpReanimate, "s")
	case "recall":
		return shape(OpRecall, "s")
	case "nothing":
		if len(a) != 0 {
			return errf()
		}
		e.Op = OpNothing
		return e, nil
	case "negate":
		if len(a) != 1 {
			return errf()
		}
		if e.Sel, err = parseSelector(a[0]); err != nil {
			return nil, err
		}
		if e.Sel.Kind != SelTarget {
			return errf()
		}
		e.Op = OpNegate
		return e, nil
	case "grant":
		if len(a) != 2 {
			return errf()
		}
		if e.KW, err = parseKwSpec(a[0]); err != nil {
			return nil, err
		}
		if e.Sel, err = parseSelector(a[1]); err != nil {
			return nil, err
		}
		e.Op = OpGrant
		return e, nil
	case "summon", "conjure":
		if len(a) != 3 || a[0].Kind != sexpr.Symbol {
			return errf()
		}
		e.CardID = a[0].Text
		if e.A1, err = parseAmount(a[1]); err != nil {
			return nil, err
		}
		if e.PSel, err = parsePlayerSel(a[2]); err != nil {
			return nil, err
		}
		e.Op = OpSummon
		if h == "conjure" {
			e.Op = OpConjure
		}
		return e, nil
	case "dig":
		if len(a) != 3 || a[0].Kind != sexpr.Int || a[1].Kind != sexpr.List {
			return errf()
		}
		e.K = int(a[0].Num)
		if e.Filters, err = parseFilters(a[1].Kids); err != nil {
			return nil, err
		}
		if e.PSel, err = parsePlayerSel(a[2]); err != nil {
			return nil, err
		}
		e.Op = OpDig
		return e, nil
	case "delay":
		if len(a) < 1 || a[0].Kind != sexpr.Symbol {
			return errf()
		}
		w := -1
		for i, s := range whenNames {
			if s == a[0].Text {
				w = i
			}
		}
		if w < 0 {
			return errf()
		}
		e.Op, e.When = OpDelay, When(w)
		if e.Body, err = parseEffects(a[1:]); err != nil {
			return nil, err
		}
		return e, nil
	case "if":
		if len(a) != 2 && len(a) != 3 {
			return errf()
		}
		if e.Cond, err = parseCond(a[0]); err != nil {
			return nil, err
		}
		for i := 1; i < len(a); i++ {
			if a[i].Kind != sexpr.List {
				return errf()
			}
			list, err := parseEffects(a[i].Kids)
			if err != nil {
				return nil, err
			}
			if i == 1 {
				e.Body = list
			} else {
				e.Else, e.HasElse = list, true
			}
		}
		e.Op = OpIf
		return e, nil
	case "each":
		if len(a) < 1 {
			return errf()
		}
		if e.Sel, err = parseSelector(a[0]); err != nil {
			return nil, err
		}
		if e.Body, err = parseEffects(a[1:]); err != nil {
			return nil, err
		}
		e.Op = OpEach
		return e, nil
	case "repeat":
		if len(a) < 1 {
			return errf()
		}
		if e.A1, err = parseAmount(a[0]); err != nil {
			return nil, err
		}
		if e.Body, err = parseEffects(a[1:]); err != nil {
			return nil, err
		}
		e.Op = OpRepeat
		return e, nil
	}
	return errf()
}

func parseStatic(n sexpr.Node) (*Static, error) {
	h, a, ok := n.Head()
	if !ok {
		return nil, fmt.Errorf("bad static %s", n)
	}
	s := &Static{Node: n}
	errf := func() (*Static, error) { return nil, fmt.Errorf("bad static %s", n) }
	var err error
	switch h {
	case "modify", "setbody":
		if len(a) != 3 {
			return errf()
		}
		if s.A1, err = parseAmount(a[0]); err != nil {
			return nil, err
		}
		if s.A2, err = parseAmount(a[1]); err != nil {
			return nil, err
		}
		if s.Sel, err = parseSelector(a[2]); err != nil {
			return nil, err
		}
		s.Kind = StModify
		if h == "setbody" {
			s.Kind = StSetbody
		}
		return s, nil
	case "swapstats":
		if len(a) != 1 {
			return errf()
		}
		if s.Sel, err = parseSelector(a[0]); err != nil {
			return nil, err
		}
		s.Kind = StSwap
		return s, nil
	case "grant":
		if len(a) != 2 {
			return errf()
		}
		if s.KW, err = parseKwSpec(a[0]); err != nil {
			return nil, err
		}
		if s.Sel, err = parseSelector(a[1]); err != nil {
			return nil, err
		}
		s.Kind = StGrant
		return s, nil
	case "cheaper":
		if len(a) < 1 || a[0].Kind != sexpr.Int {
			return errf()
		}
		s.Kind, s.N = StCheaper, int(a[0].Num)
		for _, f := range a[1:] {
			fl, err := parseFilter(f)
			if err != nil {
				return nil, err
			}
			switch fl.Kind {
			case FType, FTag, FCost:
				s.CardFilters = append(s.CardFilters, CardFilter{Kind: fl.Kind, Type: fl.Type, Tag: fl.Tag, Cmp: fl.Cmp, N: fl.N})
			default:
				return errf()
			}
		}
		return s, nil
	case "when":
		if len(a) < 1 {
			return errf()
		}
		if s.Cond, err = parseCond(a[0]); err != nil {
			return nil, err
		}
		for _, b := range a[1:] {
			sub, err := parseStatic(b)
			if err != nil {
				return nil, err
			}
			s.Body = append(s.Body, sub)
		}
		s.Kind = StWhen
		return s, nil
	}
	return errf()
}
