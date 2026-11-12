package match

import (
	"strings"

	"github.com/spiremark/cardgame/engine"
)

func parseObjRef(s string) (uint64, bool) {
	if !strings.HasPrefix(s, "#") {
		return 0, false
	}
	return parseUint(s[1:])
}

func parseTarget(s string) (engine.TargetRef, bool) {
	switch {
	case s == "A":
		return engine.TargetRef{Kind: engine.RefPlayer, Player: engine.A}, true
	case s == "B":
		return engine.TargetRef{Kind: engine.RefPlayer, Player: engine.B}, true
	case strings.HasPrefix(s, "#"):
		v, ok := parseUint(s[1:])
		return engine.TargetRef{Kind: engine.RefObject, ID: v}, ok
	case strings.HasPrefix(s, "~"):
		v, ok := parseUint(s[1:])
		return engine.TargetRef{Kind: engine.RefEntry, ID: v}, ok
	}
	return engine.TargetRef{}, false
}

// ParseAction parses a script action line already split into words
// (SPEC 4.2). ok is false when the line is not a well-formed action.
func ParseAction(words []string) (act engine.Action, ok bool) {
	if len(words) < 2 {
		return act, false
	}
	switch words[0] {
	case "A":
		act.Player = engine.A
	case "B":
		act.Player = engine.B
	default:
		return act, false
	}
	args := words[2:]
	switch words[1] {
	case "PASS", "CONCEDE":
		if len(args) != 0 {
			return act, false
		}
		act.Kind = engine.ActPass
		if words[1] == "CONCEDE" {
			act.Kind = engine.ActConcede
		}
		return act, true
	case "PLAY":
		if len(args) < 1 {
			return act, false
		}
		pos, ok := parseUint(args[0])
		if !ok {
			return act, false
		}
		act.Kind, act.Pos = engine.ActPlay, pos
		for _, t := range args[1:] {
			ref, ok := parseTarget(t)
			if !ok {
				return act, false
			}
			act.Targets = append(act.Targets, ref)
		}
		return act, true
	case "ACT":
		if len(args) < 2 {
			return act, false
		}
		obj, ok1 := parseObjRef(args[0])
		idx, ok2 := parseUint(args[1])
		if !ok1 || !ok2 {
			return act, false
		}
		act.Kind, act.Object, act.Index = engine.ActAct, obj, idx
		for _, t := range args[2:] {
			ref, ok := parseTarget(t)
			if !ok {
				return act, false
			}
			act.Targets = append(act.Targets, ref)
		}
		return act, true
	case "ATTACK":
		act.Kind = engine.ActAttack
		for _, t := range args {
			id, ok := parseObjRef(t)
			if !ok {
				return act, false
			}
			act.Attackers = append(act.Attackers, id)
		}
		return act, true
	case "BLOCK":
		act.Kind = engine.ActBlock
		for _, t := range args {
			i := strings.IndexByte(t, ':')
			if i < 0 {
				return act, false
			}
			b, ok1 := parseObjRef(t[:i])
			a, ok2 := parseObjRef(t[i+1:])
			if !ok1 || !ok2 {
				return act, false
			}
			act.Blocks = append(act.Blocks, engine.BlockPair{Blocker: b, Attacker: a})
		}
		return act, true
	}
	return act, false
}
