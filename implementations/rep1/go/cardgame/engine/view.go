package engine

import (
	"fmt"
	"io"
	"sort"
	"strings"

	"github.com/spiremark/cardgame/cards"
)

func (g *Game) decisionString() string {
	if g.over {
		return "decision - over"
	}
	return "decision " + g.decPlayer.String() + " " + g.decKind.String()
}

func (g *Game) kwList(o *Obj) string {
	g.ensure()
	var names []string
	for k := cards.Keyword(0); k <= cards.Swift; k++ {
		if o.kwMask&kwBit(k) == 0 {
			continue
		}
		if k == cards.Plating {
			names = append(names, fmt.Sprintf("plating:%d", o.plating))
		} else {
			names = append(names, k.String())
		}
	}
	if len(names) == 0 {
		return "-"
	}
	sort.Strings(names)
	return strings.Join(names, ",")
}

func (g *Game) flags(o *Obj) string {
	var fl []string
	if o.attacking {
		fl = append(fl, "attacking")
	}
	if o.blocked {
		fl = append(fl, "blocked")
	}
	if o.blocking {
		fl = append(fl, "blocking")
	}
	if o.doomed {
		fl = append(fl, "doomed")
	}
	for _, i := range o.once {
		fl = append(fl, fmt.Sprintf("once%d", i))
	}
	if g.settling(o) {
		fl = append(fl, "settling")
	}
	if o.tenUsed {
		fl = append(fl, "tenacity-used")
	}
	if o.ward > 0 {
		fl = append(fl, fmt.Sprintf("ward%d", o.ward))
	}
	if len(fl) == 0 {
		return "-"
	}
	sort.Strings(fl)
	return strings.Join(fl, ",")
}

func objList(os []*Obj) string {
	if len(os) == 0 {
		return "-"
	}
	parts := make([]string, len(os))
	for i, o := range os {
		parts[i] = oidS(o)
	}
	return strings.Join(parts, ",")
}

func targetsString(ts []target) string {
	parts := make([]string, 0, len(ts))
	for _, t := range ts {
		if t.removed {
			parts = append(parts, "-")
		} else {
			parts = append(parts, t.render())
		}
	}
	return strings.Join(parts, " ")
}

func (g *Game) line(w io.Writer, parts ...string) {
	var sb strings.Builder
	for i, p := range parts {
		if p == "" {
			continue
		}
		if i > 0 && sb.Len() > 0 {
			sb.WriteByte(' ')
		}
		sb.WriteString(p)
	}
	sb.WriteByte('\n')
	_, _ = io.WriteString(w, sb.String())
}

// Dump writes the STATE block of SPEC 23.1 to w.
func (g *Game) Dump(w io.Writer) {
	g.ensure()
	g.line(w, "STATE BEGIN")
	g.line(w, "turn", itoa(g.turn), "active", g.active.String(), "phase", g.phase, g.decisionString())
	if g.over {
		g.line(w, "result", g.winner, g.reason)
	}
	for p := A; p <= B; p++ {
		pl := &g.pl[p]
		g.line(w, "player", p.String(), "spire", itoa(pl.spire), "ember", itoa(pl.ember), "cap", itoa(pl.cap),
			"vault", itoa(len(pl.vault)), "hand", itoa(len(pl.hand)), "ash", itoa(len(pl.ash)), "rift", itoa(len(pl.rift)))
	}
	for p := A; p <= B; p++ {
		for i, o := range g.pl[p].hand {
			g.line(w, "hand", p.String(), itoa(i+1), oidS(o), o.Card.ID)
		}
	}
	for p := A; p <= B; p++ {
		for _, o := range g.field {
			if o.ctrl != p {
				continue
			}
			body := "-/-"
			if o.Card.Type == cards.Unit {
				body = itoa(o.edge) + "/" + itoa(o.core)
			}
			state := "ready"
			if !o.ready {
				state = "exhausted"
			}
			g.line(w, "field", p.String(), oidS(o), o.Card.ID, body, "w"+itoa(o.wounds), "c"+itoa(o.counters),
				state, g.flags(o), "kw", g.kwList(o))
		}
	}
	for p := A; p <= B; p++ {
		for i, o := range g.pl[p].ash {
			g.line(w, "ash", p.String(), itoa(i+1), oidS(o), o.Card.ID)
		}
	}
	for p := A; p <= B; p++ {
		for i, o := range g.pl[p].rift {
			g.line(w, "rift", p.String(), itoa(i+1), oidS(o), o.Card.ID)
		}
	}
	for i, e := range g.chain {
		g.line(w, "chain", itoa(i+1), "~"+itoa(e.cid), e.ctrl.String(), entryKindNames[e.kind], oidS(e.src),
			itoa(e.idx), targetsString(e.targets))
	}
	for _, r := range g.records {
		dur := "turn"
		desc := ""
		objs := r.affected
		onField := make([]*Obj, 0, len(objs))
		for _, o := range objs {
			if o.zone == ZField {
				onField = append(onField, o)
			}
		}
		objs = onField
		switch r.kind {
		case rModify:
			desc = fmt.Sprintf("modify %d %d", r.a, r.b)
		case rSetbody:
			desc = fmt.Sprintf("setbody %d %d", r.a, r.b)
		case rSwap:
			desc = "swapstats"
		case rGrant:
			desc = "grant " + r.kw.String()
		case rStrip:
			desc = "strip"
		case rControl:
			desc = "control " + r.ctrl.String()
		case rAura:
			dur = "aura"
			objs = nil
			if len(r.parts) > 0 {
				pt := &r.parts[0]
				switch pt.kind {
				case cards.StModify:
					desc = fmt.Sprintf("modify %d %d", pt.a, pt.b)
				case cards.StSetbody:
					desc = fmt.Sprintf("setbody %d %d", pt.a, pt.b)
				case cards.StSwap:
					desc = "swapstats"
				case cards.StGrant:
					desc = "grant " + pt.kw.String()
				case cards.StCheaper:
					desc = fmt.Sprintf("cheaper %d", pt.n)
				}
				if pt.active && pt.kind != cards.StCheaper {
					objs = pt.objs
				}
			}
		}
		g.line(w, "effect", itoa(r.eid), "ts"+itoa(r.ts), r.ctrl.String(), dur, desc, "on", objList(objs))
	}
	for _, d := range g.delays {
		g.line(w, "delayed", itoa(d.ts), d.ctrl.String(), d.when.String(), targetsString(d.targets))
	}
	g.line(w, "STATE END")
}

// Vault writes the VAULT block of SPEC 23.3 to w.
func (g *Game) Vault(w io.Writer) {
	g.line(w, "VAULT BEGIN")
	for p := A; p <= B; p++ {
		for i, o := range g.pl[p].vault {
			g.line(w, "vault", p.String(), itoa(i+1), oidS(o), o.Card.ID)
		}
	}
	g.line(w, "VAULT END")
}

// LegalActions returns the lines between LEGAL BEGIN and LEGAL END.
func (g *Game) LegalActions() []string {
	if g.over {
		return nil
	}
	g.ensure()
	var out []string
	switch g.decKind {
	case DecPriority:
		p := g.decPlayer
		out = append(out, "PASS")
		for i, o := range g.pl[p].hand {
			if !g.playTiming(p, o) || g.pl[p].ember < g.playCost(p, o.Card) {
				continue
			}
			tuples := g.targetTuples(resolveSpecs(o.Card), &ctx{ctrl: p, src: o}, nil)
			for _, tu := range tuples {
				s := "PLAY " + itoa(i+1) + " " + o.Card.ID
				for _, t := range tu {
					s += " " + t.render()
				}
				out = append(out, s)
			}
		}
		var mine []*Obj
		for _, o := range g.field {
			if o.ctrl == p {
				mine = append(mine, o)
			}
		}
		sort.Slice(mine, func(i, j int) bool { return mine[i].OID < mine[j].OID })
		for _, o := range mine {
			if g.strippedOf(o) {
				continue
			}
			for _, ab := range o.Card.Abilities {
				if ab.Kind != cards.AbAct || !g.allCostsPayable(p, o, ab) {
					continue
				}
				for _, tu := range g.targetTuples(ab.Targets, &ctx{ctrl: p, src: o}, nil) {
					s := "ACT " + oidS(o) + " " + itoa(ab.Index)
					for _, t := range tu {
						s += " " + t.render()
					}
					out = append(out, s)
				}
			}
		}
	case DecAttackers:
		var can []*Obj
		for _, o := range g.field {
			if g.canAttack(o) {
				can = append(can, o)
			}
		}
		sort.Slice(can, func(i, j int) bool { return can[i].OID < can[j].OID })
		for _, o := range can {
			out = append(out, "CANATTACK "+oidS(o))
		}
		for _, o := range can {
			if g.hasKW(o, cards.Relentless) {
				out = append(out, "MUSTATTACK "+oidS(o))
			}
		}
	case DecBlockers:
		byOID := append([]*Obj(nil), g.field...)
		sort.Slice(byOID, func(i, j int) bool { return byOID[i].OID < byOID[j].OID })
		for _, b := range byOID {
			for _, a := range byOID {
				if g.canBlock(b, a) {
					out = append(out, "CANBLOCK "+oidS(b)+" "+oidS(a))
				}
			}
		}
		for _, a := range byOID {
			if a.attacking && g.hasKW(a, cards.Provoke) {
				out = append(out, "MUSTBLOCK "+oidS(a))
			}
		}
	}
	return out
}

// Legal writes the LEGAL block of SPEC 23.2 to w.
func (g *Game) Legal(w io.Writer) {
	if g.over {
		g.line(w, "LEGAL BEGIN - over")
	} else {
		g.line(w, "LEGAL BEGIN", g.decPlayer.String(), g.decKind.String())
	}
	for _, l := range g.LegalActions() {
		g.line(w, l)
	}
	g.line(w, "LEGAL END")
}
