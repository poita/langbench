package engine

import (
	"sort"
	"strconv"
	"strings"

	"cardgame/cards"
)

func (g *Game) decisionText() string {
	if g.over || g.dec == DecNone {
		return "- over"
	}
	return g.waiter.String() + " " + decisionNames[g.dec]
}

func kwList(o *Obj) string {
	var parts []string
	for k := cards.Keyword(0); k < cards.NumKeywords; k++ {
		if !o.hasKw(k) {
			continue
		}
		if k == cards.Plating {
			parts = append(parts, "plating:"+strconv.Itoa(o.Plating))
		} else {
			parts = append(parts, k.String())
		}
	}
	if len(parts) == 0 {
		return "-"
	}
	sort.Strings(parts)
	return strings.Join(parts, ",")
}

func (g *Game) writeDump() {
	g.derive()
	l := &g.out
	l.line("STATE BEGIN")
	l.line("turn " + strconv.Itoa(g.turn) + " active " + g.active.String() + " phase " +
		stepPhaseNames[g.step] + " decision " + g.decisionText())
	if g.over {
		l.line("result " + g.winner + " " + g.resReason)
	}
	for p := Player(0); p < 2; p++ {
		ps := &g.pl[p]
		l.line("player " + p.String() + " spire " + strconv.Itoa(ps.Spire) + " ember " + strconv.Itoa(ps.Ember) +
			" cap " + strconv.Itoa(ps.Cap) + " vault " + strconv.Itoa(len(ps.Vault)) + " hand " +
			strconv.Itoa(len(ps.Hand)) + " ash " + strconv.Itoa(len(ps.Ash)) + " rift " + strconv.Itoa(len(ps.Rift)))
	}
	zoneLines := func(name string, get func(*playerState) []int) {
		for p := Player(0); p < 2; p++ {
			for i, id := range get(&g.pl[p]) {
				l.line(name + " " + p.String() + " " + strconv.Itoa(i+1) + " #" + strconv.Itoa(id) + " " + g.objs[id].Card.ID)
			}
		}
	}
	zoneLines("hand", func(ps *playerState) []int { return ps.Hand })
	for p := Player(0); p < 2; p++ {
		for _, id := range g.field {
			o := g.objs[id]
			if o.CurCtrl != p {
				continue
			}
			g.writeFieldLine(id)
		}
	}
	zoneLines("ash", func(ps *playerState) []int { return ps.Ash })
	zoneLines("rift", func(ps *playerState) []int { return ps.Rift })
	for i, en := range g.chain {
		var sb strings.Builder
		sb.WriteString("chain " + strconv.Itoa(i+1) + " ~" + strconv.Itoa(en.Cid) + " " + en.Ctrl.String() + " " +
			entryKindNames[en.Kind] + " #" + strconv.Itoa(en.Source) + " " + strconv.Itoa(en.Index))
		for _, t := range en.Targets {
			sb.WriteByte(' ')
			sb.WriteString(renderTarget(t, true))
		}
		l.line(sb.String())
	}
	for _, r := range g.records {
		l.line(g.effectLine(r))
	}
	ds := append([]*Delayed(nil), g.delayed...)
	sort.SliceStable(ds, func(i, j int) bool { return ds[i].TS < ds[j].TS })
	for _, d := range ds {
		var sb strings.Builder
		sb.WriteString("delayed " + strconv.Itoa(d.TS) + " " + d.Ctrl.String() + " " + d.When.String())
		for _, t := range d.Targets {
			sb.WriteByte(' ')
			sb.WriteString(renderTarget(t, false))
		}
		l.line(sb.String())
	}
	l.line("STATE END")
}

func renderTarget(t Target, showRemoved bool) string {
	if t.Removed && showRemoved {
		return "-"
	}
	switch t.Kind {
	case TPlayer:
		return Player(t.ID).String()
	case TObject:
		return "#" + strconv.Itoa(t.ID)
	}
	return "~" + strconv.Itoa(t.ID)
}

func (g *Game) writeFieldLine(id int) {
	o := g.objs[id]
	var sb strings.Builder
	sb.WriteString("field " + o.CurCtrl.String() + " #" + strconv.Itoa(id) + " " + o.Card.ID + " ")
	if o.Card.Type == cards.Relic {
		sb.WriteString("-/-")
	} else {
		sb.WriteString(strconv.Itoa(o.Edge) + "/" + strconv.Itoa(o.Core))
	}
	sb.WriteString(" w" + strconv.Itoa(o.Wounds) + " c" + strconv.Itoa(o.Counters))
	if o.Exhausted {
		sb.WriteString(" exhausted ")
	} else {
		sb.WriteString(" ready ")
	}
	var flags []string
	add := func(cond bool, s string) {
		if cond {
			flags = append(flags, s)
		}
	}
	add(o.Attacking, "attacking")
	add(o.Blocked, "blocked")
	add(o.Blocking, "blocking")
	add(o.Doomed, "doomed")
	for _, idx := range o.Once {
		flags = append(flags, "once"+strconv.Itoa(idx))
	}
	add(o.Since >= g.turn, "settling")
	add(o.TenacityUsed, "tenacity-used")
	add(o.Ward > 0, "ward"+strconv.Itoa(o.Ward))
	if len(flags) == 0 {
		sb.WriteString("-")
	} else {
		sort.Strings(flags)
		sb.WriteString(strings.Join(flags, ","))
	}
	sb.WriteString(" kw " + kwList(o))
	g.out.line(sb.String())
}

func (g *Game) effectLine(r *Record) string {
	e := &r.Effs[0]
	var desc string
	switch e.Kind {
	case RModify:
		desc = "modify " + strconv.Itoa(e.A) + " " + strconv.Itoa(e.B)
	case RSetbody:
		desc = "setbody " + strconv.Itoa(e.A) + " " + strconv.Itoa(e.B)
	case RSwap:
		desc = "swapstats"
	case RGrant:
		desc = "grant " + e.Kw.String()
	case RStrip:
		desc = "strip"
	case RControl:
		desc = "control " + r.Ctrl.String()
	case RCheaper:
		desc = "cheaper " + strconv.Itoa(e.Cheaper)
	}
	dur := "turn"
	if r.Aura {
		dur = "aura"
	}
	var objs []string
	if e.Kind != RCheaper && (!r.Aura || e.Active) {
		for _, id := range e.Affected {
			if g.objs[id].Zone == ZField {
				objs = append(objs, "#"+strconv.Itoa(id))
			}
		}
	}
	on := "-"
	if len(objs) > 0 {
		on = strings.Join(objs, ",")
	}
	return "effect " + strconv.Itoa(r.Eid) + " ts" + strconv.Itoa(r.TS) + " " + r.Ctrl.String() + " " +
		dur + " " + desc + " on " + on
}

func (g *Game) writeVault() {
	g.out.line("VAULT BEGIN")
	for p := Player(0); p < 2; p++ {
		for i, id := range g.pl[p].Vault {
			g.out.line("vault " + p.String() + " " + strconv.Itoa(i+1) + " #" + strconv.Itoa(id) + " " + g.objs[id].Card.ID)
		}
	}
	g.out.line("VAULT END")
}

func (g *Game) writeCard(id string) {
	g.out.line("CARD BEGIN " + id)
	c := g.db.Card(id)
	if c == nil {
		g.out.line("unknown")
	} else {
		for _, ln := range c.Describe() {
			g.out.line(ln)
		}
	}
	g.out.line("CARD END")
}

// writeLegal prints the LEGAL block (SPEC 21, 23.2).
func (g *Game) writeLegal() {
	if g.over || g.dec == DecNone {
		g.out.line("LEGAL BEGIN - over")
		g.out.line("LEGAL END")
		return
	}
	g.out.line("LEGAL BEGIN " + g.waiter.String() + " " + decisionNames[g.dec])
	switch g.dec {
	case DecPriority:
		g.legalPriority(g.waiter)
	case DecAttackers:
		ids := g.unitsByOid()
		for _, id := range ids {
			if g.canAttack(id) {
				g.out.line("CANATTACK #" + strconv.Itoa(id))
			}
		}
		for _, id := range ids {
			if g.canAttack(id) && g.objs[id].hasKw(cards.Relentless) {
				g.out.line("MUSTATTACK #" + strconv.Itoa(id))
			}
		}
	case DecBlockers:
		ids := g.unitsByOid()
		for _, b := range ids {
			for _, a := range ids {
				if g.canBlock(b, a) {
					g.out.line("CANBLOCK #" + strconv.Itoa(b) + " #" + strconv.Itoa(a))
				}
			}
		}
		for _, a := range ids {
			if o := g.objs[a]; o.Attacking && o.hasKw(cards.Provoke) {
				g.out.line("MUSTBLOCK #" + strconv.Itoa(a))
			}
		}
	}
	g.out.line("LEGAL END")
}

func tupleText(ts []Target) string {
	var sb strings.Builder
	for _, t := range ts {
		sb.WriteByte(' ')
		sb.WriteString(renderTarget(t, false))
	}
	return sb.String()
}

func (g *Game) legalPriority(p Player) {
	g.out.line("PASS")
	for i, oid := range g.pl[p].Hand {
		card := g.objs[oid].Card
		if !g.canPlayNow(p, card) || g.pl[p].Ember < g.playCost(p, card) {
			continue
		}
		var specs []cards.TargetSpec
		if card.Type == cards.Rite {
			specs = card.Abilities[0].Targets
		}
		for _, tu := range g.tuples(specs, &ctx{ctrl: p, source: oid}) {
			g.out.line("PLAY " + strconv.Itoa(i+1) + " " + card.ID + tupleText(tu))
		}
	}
	g.derive()
	ids := append([]int(nil), g.field...)
	sort.Ints(ids)
	for _, oid := range ids {
		o := g.objs[oid]
		if o.CurCtrl != p || o.Stripped {
			continue
		}
		for i, ab := range o.Card.Abilities {
			if ab.Kind != cards.AbAct || !g.costPayable(p, oid, ab, i+1) {
				continue
			}
			for _, tu := range g.tuples(ab.Targets, &ctx{ctrl: p, source: oid}) {
				g.out.line("ACT #" + strconv.Itoa(oid) + " " + strconv.Itoa(i+1) + tupleText(tu))
			}
		}
	}
}
