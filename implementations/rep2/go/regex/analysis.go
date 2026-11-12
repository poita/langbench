package regex

import "example.com/regex/syntax"

// searchInfo is computed once per pattern and lets the search loop skip start
// positions that cannot begin a match.
type searchInfo struct {
	first    syntax.CharSet // bytes that can begin a non-empty match
	nullable bool           // a match might be empty: every start must be tried
	anchored bool           // every match begins at position 0
}

func analyze(root *syntax.Node) searchInfo {
	first, nullable := firstSet(root)
	return searchInfo{first: first, nullable: nullable, anchored: anchoredAtStart(root)}
}

// firstSet returns the bytes that can start a match of n, and whether n might
// match without consuming anything (anchors are treated as matching empty).
func firstSet(n *syntax.Node) (set syntax.CharSet, nullable bool) {
	switch n.Kind {
	case syntax.Literal:
		set.Add(n.Char)
	case syntax.AnyChar:
		set = syntax.AllChars()
	case syntax.Class:
		set = n.Set
	case syntax.Concat:
		nullable = true
		for _, s := range n.Subs {
			ss, sn := firstSet(s)
			set.Union(&ss)
			if !sn {
				nullable = false
				break
			}
		}
	case syntax.Alternate:
		for _, s := range n.Subs {
			ss, sn := firstSet(s)
			set.Union(&ss)
			nullable = nullable || sn
		}
	case syntax.Group:
		return firstSet(n.Subs[0])
	case syntax.Repeat:
		if n.Max == 0 {
			return set, true
		}
		set, nullable = firstSet(n.Subs[0])
		nullable = nullable || n.Min == 0
	default: // Empty and anchors
		nullable = true
	}
	return set, nullable
}

// anchoredAtStart reports whether every match of n must begin with a '^'
// assertion, so that only start position 0 can succeed.
func anchoredAtStart(n *syntax.Node) bool {
	switch n.Kind {
	case syntax.StartAnchor:
		return true
	case syntax.Concat:
		return anchoredAtStart(n.Subs[0])
	case syntax.Alternate:
		for _, s := range n.Subs {
			if !anchoredAtStart(s) {
				return false
			}
		}
		return true
	case syntax.Group:
		return anchoredAtStart(n.Subs[0])
	case syntax.Repeat:
		return n.Min > 0 && anchoredAtStart(n.Subs[0])
	}
	return false
}
