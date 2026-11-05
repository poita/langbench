package cards

import (
	"sort"
	"strconv"
	"strings"
)

// Describe returns the lines of the CARD inspection block for c, without the
// BEGIN and END framing lines.
func (c *Card) Describe() []string {
	lines := []string{
		"name " + c.Name,
		"type " + c.Type.String(),
		"cost " + strconv.FormatInt(c.Cost, 10),
	}
	if c.Type == Unit {
		lines = append(lines, "body "+strconv.FormatInt(c.Edge, 10)+"/"+strconv.FormatInt(c.Core, 10))
	}
	tags := "-"
	if len(c.Tags) > 0 {
		tags = strings.Join(c.Tags, ",")
	}
	lines = append(lines, "tags "+tags)
	kws := "-"
	if len(c.Keywords) > 0 {
		names := make([]string, len(c.Keywords))
		for i, k := range c.Keywords {
			names[i] = k.String()
		}
		sort.Strings(names)
		kws = strings.Join(names, ",")
	}
	lines = append(lines, "keywords "+kws)
	for i, a := range c.Abilities {
		var sb strings.Builder
		sb.WriteString("ability ")
		sb.WriteString(strconv.Itoa(i + 1))
		sb.WriteByte(' ')
		switch a.Kind {
		case AbResolve:
			sb.WriteString("resolve " + a.TargetsText + " " + a.BodyText)
		case AbOn:
			sb.WriteString("on " + a.Event.String() + " " + a.TargetsText + " " + a.BodyText)
		case AbAct:
			sb.WriteString("act " + a.CostText + " " + a.TargetsText + " " + a.BodyText)
		case AbAura:
			sb.WriteString("aura " + a.BodyText)
		}
		lines = append(lines, sb.String())
	}
	return lines
}
