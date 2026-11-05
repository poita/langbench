package syntax

// Nullable reports whether n can match without consuming any character.
// Anchors are nullable; the answer is conservative-exact for the dialect.
func (n *Node) Nullable() bool {
	switch n.Kind {
	case KindLiteral, KindAny, KindClass:
		return false
	case KindBOL, KindEOL:
		return true
	case KindSeq:
		for _, s := range n.Subs {
			if !s.Nullable() {
				return false
			}
		}
		return true
	case KindAlt:
		for _, s := range n.Subs {
			if s.Nullable() {
				return true
			}
		}
		return false
	case KindGroup:
		return n.Subs[0].Nullable()
	case KindRep:
		return n.Min == 0 || n.Subs[0].Nullable()
	}
	return false
}

// AddFirst adds to set every character that can begin a non-empty match of
// n, and reports whether n is nullable. For a seq the sets of the items up to
// and including the first non-nullable one are united.
func (n *Node) AddFirst(set *CharSet) (nullable bool) {
	switch n.Kind {
	case KindLiteral:
		set.Add(n.Char)
		return false
	case KindAny:
		full := FullSet()
		set.AddSet(&full)
		return false
	case KindClass:
		set.AddSet(n.Set)
		return false
	case KindBOL, KindEOL:
		return true
	case KindSeq:
		for _, s := range n.Subs {
			if !s.AddFirst(set) {
				return false
			}
		}
		return true
	case KindAlt:
		nullable = false
		for _, s := range n.Subs {
			if s.AddFirst(set) {
				nullable = true
			}
		}
		return nullable
	case KindGroup:
		return n.Subs[0].AddFirst(set)
	case KindRep:
		bodyNullable := n.Subs[0].AddFirst(set)
		return n.Min == 0 || bodyNullable
	}
	return true
}

// Anchored reports whether every match of n must begin with '^' (and so can
// only start at position 0).
func (n *Node) Anchored() bool {
	switch n.Kind {
	case KindBOL:
		return true
	case KindSeq:
		return len(n.Subs) > 0 && n.Subs[0].Anchored()
	case KindAlt:
		for _, s := range n.Subs {
			if !s.Anchored() {
				return false
			}
		}
		return len(n.Subs) > 0
	case KindGroup:
		return n.Subs[0].Anchored()
	case KindRep:
		return n.Min >= 1 && n.Subs[0].Anchored()
	}
	return false
}
