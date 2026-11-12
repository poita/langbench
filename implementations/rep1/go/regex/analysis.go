package regexbt

import "example.com/regexbt/syntax"

// firstSet computes the set of bytes that can be the first byte consumed by
// a match of n, and whether n can match without consuming anything (anchors
// count as possibly-empty, which keeps the result a safe over-approximation).
func firstSet(n *syntax.Node) (set syntax.CharSet, nullable bool) {
	switch n.Kind {
	case syntax.KindLiteral:
		set.Add(n.Char)
	case syntax.KindAny:
		set = syntax.FullSet()
	case syntax.KindClass:
		set = n.Set
	case syntax.KindConcat:
		nullable = true
		for _, s := range n.Subs {
			fs, fn := firstSet(s)
			set.Union(&fs)
			if !fn {
				nullable = false
				break
			}
		}
	case syntax.KindAlternate:
		for _, s := range n.Subs {
			fs, fn := firstSet(s)
			set.Union(&fs)
			nullable = nullable || fn
		}
	case syntax.KindGroup:
		return firstSet(n.Subs[0])
	case syntax.KindRepeat:
		if n.Max == 0 {
			return set, true
		}
		set, nullable = firstSet(n.Subs[0])
		nullable = nullable || n.Min == 0
	default: // empty, '^', '$'
		nullable = true
	}
	return set, nullable
}

// startsWithBol reports whether every match of n must begin by passing a '^'
// assertion, so that n can only ever match at position 0.
func startsWithBol(n *syntax.Node) bool {
	switch n.Kind {
	case syntax.KindBol:
		return true
	case syntax.KindConcat:
		return len(n.Subs) > 0 && startsWithBol(n.Subs[0])
	case syntax.KindAlternate:
		for _, s := range n.Subs {
			if !startsWithBol(s) {
				return false
			}
		}
		return true
	case syntax.KindGroup:
		return startsWithBol(n.Subs[0])
	case syntax.KindRepeat:
		return n.Min > 0 && startsWithBol(n.Subs[0])
	}
	return false
}
