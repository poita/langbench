package regexvm

// nodeKind identifies the type of a syntax tree node.
type nodeKind uint8

const (
	nLit   nodeKind = iota // a single literal byte
	nAny                   // .
	nClass                 // a character class or set escape
	nBol                   // ^
	nEol                   // $
	nSeq                   // concatenation of subs
	nAlt                   // ordered choice between subs
	nGroup                 // capturing group around subs[0]
	nRep                   // subs[0] repeated min..max times (max < 0: unbounded)
)

// charSet is a membership table over all byte values.
type charSet [256]bool

// node is a syntax tree node. Which fields are meaningful depends on kind.
type node struct {
	kind  nodeKind
	ch    byte     // nLit
	set   *charSet // nClass
	subs  []*node  // nSeq, nAlt: children; nGroup, nRep: the single body
	group int      // nGroup: 1-based group number
	min   int      // nRep
	max   int      // nRep: -1 means unbounded
}

// singleChar reports whether the node always consumes exactly one character
// and contains no group.
func (n *node) singleChar() bool {
	return n.kind == nLit || n.kind == nAny || n.kind == nClass
}

// nullable reports whether the node can match without consuming a character.
func (n *node) nullable() bool {
	switch n.kind {
	case nLit, nAny, nClass:
		return false
	case nBol, nEol:
		return true
	case nSeq:
		for _, s := range n.subs {
			if !s.nullable() {
				return false
			}
		}
		return true
	case nAlt:
		for _, s := range n.subs {
			if s.nullable() {
				return true
			}
		}
		return false
	case nGroup:
		return n.subs[0].nullable()
	case nRep:
		return n.min == 0 || n.subs[0].nullable()
	}
	return true
}

// anchored reports whether every match of the node must begin with ^.
func (n *node) anchored() bool {
	switch n.kind {
	case nBol:
		return true
	case nSeq:
		return len(n.subs) > 0 && n.subs[0].anchored()
	case nAlt:
		for _, s := range n.subs {
			if !s.anchored() {
				return false
			}
		}
		return len(n.subs) > 0
	case nGroup:
		return n.subs[0].anchored()
	case nRep:
		return n.min >= 1 && n.subs[0].anchored()
	}
	return false
}

// first adds to set every byte that can begin a non-empty match of the node
// and reports whether the node is nullable. The set is a conservative
// over-approximation.
func (n *node) first(set *charSet) (nullable bool) {
	switch n.kind {
	case nLit:
		set[n.ch] = true
		return false
	case nAny:
		for i := range set {
			set[i] = true
		}
		return false
	case nClass:
		for i, in := range n.set {
			if in {
				set[i] = true
			}
		}
		return false
	case nBol, nEol:
		return true
	case nSeq:
		for _, s := range n.subs {
			if !s.first(set) {
				return false
			}
		}
		return true
	case nAlt:
		nl := false
		for _, s := range n.subs {
			if s.first(set) {
				nl = true
			}
		}
		return nl
	case nGroup:
		return n.subs[0].first(set)
	case nRep:
		if n.max == 0 {
			return true
		}
		nl := n.subs[0].first(set)
		return nl || n.min == 0
	}
	return true
}
