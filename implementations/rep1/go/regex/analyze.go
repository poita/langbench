package regex

// Static analysis of the syntax tree used to skip hopeless start positions.

// canBeEmpty reports whether n can match without consuming a character.
func canBeEmpty(n *node) bool {
	switch n.kind {
	case nLit, nAny, nClass:
		return false
	case nBol, nEol:
		return true
	case nSeq:
		for _, s := range n.subs {
			if !canBeEmpty(s) {
				return false
			}
		}
		return true
	case nAlt:
		for _, s := range n.subs {
			if canBeEmpty(s) {
				return true
			}
		}
		return false
	case nGroup:
		return canBeEmpty(n.subs[0])
	case nRep:
		return n.min == 0 || canBeEmpty(n.subs[0])
	}
	return true
}

// firstSet adds to set every character a non-empty match of n can start
// with (it may add more than necessary, never less) and returns whether n
// is nullable.
func firstSet(n *node, set *charset) bool {
	switch n.kind {
	case nLit:
		set.add(n.ch)
		return false
	case nAny:
		for i := range set {
			set[i] = true
		}
		return false
	case nClass:
		set.union(n.set)
		return false
	case nBol, nEol:
		return true
	case nSeq:
		for _, s := range n.subs {
			if !firstSet(s, set) {
				return false
			}
		}
		return true
	case nAlt:
		nullable := false
		for _, s := range n.subs {
			if firstSet(s, set) {
				nullable = true
			}
		}
		return nullable
	case nGroup:
		return firstSet(n.subs[0], set)
	case nRep:
		if n.max == 0 {
			return true
		}
		nl := firstSet(n.subs[0], set)
		return nl || n.min == 0
	}
	return true
}

// anchoredAtStart reports whether every match of n must begin with ^.
func anchoredAtStart(n *node) bool {
	switch n.kind {
	case nBol:
		return true
	case nSeq:
		return len(n.subs) > 0 && anchoredAtStart(n.subs[0])
	case nAlt:
		for _, s := range n.subs {
			if !anchoredAtStart(s) {
				return false
			}
		}
		return true
	case nGroup:
		return anchoredAtStart(n.subs[0])
	case nRep:
		return n.min >= 1 && anchoredAtStart(n.subs[0])
	}
	return false
}
