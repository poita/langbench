package cards

import (
	"sort"
	"strings"
)

// Block renders the CARD inspection block for c (SPEC 23.4), one line per
// element, each terminated by a newline.
func (c *Card) Block() string {
	var sb strings.Builder
	sb.WriteString("CARD BEGIN " + c.ID + "\n")
	sb.WriteString("name " + c.Name + "\n")
	sb.WriteString("type " + c.Type.String() + "\n")
	sb.WriteString("cost " + itoa(c.Cost) + "\n")
	if c.Type == Unit {
		sb.WriteString("body " + itoa(c.Edge) + "/" + itoa(c.Core) + "\n")
	}
	sb.WriteString("tags " + orDash(c.Tags) + "\n")
	var kws []string
	for _, k := range c.Keywords {
		kws = append(kws, k.String())
	}
	sort.Strings(kws)
	sb.WriteString("keywords " + orDash(kws) + "\n")
	for _, ab := range c.Abilities {
		sb.WriteString("ability " + itoa(ab.Index) + " " + ab.Render() + "\n")
	}
	sb.WriteString("CARD END\n")
	return sb.String()
}

// UnknownBlock is the CARD block printed for an id the database lacks.
func UnknownBlock(id string) string {
	return "CARD BEGIN " + id + "\nunknown\nCARD END\n"
}

func orDash(xs []string) string {
	if len(xs) == 0 {
		return "-"
	}
	return strings.Join(xs, ",")
}

// Render prints the ability as it appears after "ability <n> " in a CARD
// block.
func (a *Ability) Render() string {
	tspec := "-"
	if a.targetsNode != nil {
		tspec = a.targetsNode.String()
	}
	var parts []string
	for _, n := range a.effectNodes {
		parts = append(parts, n.String())
	}
	body := strings.Join(parts, " ")
	switch a.Kind {
	case AbResolve:
		return "resolve " + tspec + " " + body
	case AbOn:
		return "on " + a.Event.String() + " " + tspec + " " + body
	case AbAct:
		return "act " + a.costNode.String() + " " + tspec + " " + body
	}
	return "aura " + body
}
