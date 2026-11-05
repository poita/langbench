package regex

type nodeKind uint8

const (
	nLit   nodeKind = iota // single literal byte: ch
	nAny                   // .
	nClass                 // character class: set
	nBol                   // ^
	nEol                   // $
	nSeq                   // concatenation of subs (may be empty)
	nAlt                   // ordered alternation of subs
	nGroup                 // capturing group number group around subs[0]
	nRep                   // subs[0] repeated min..max times (max < 0: unbounded)
)

// node is a syntax-tree node. Only the fields relevant to its kind are used.
type node struct {
	kind  nodeKind
	ch    byte
	set   *charset
	subs  []*node
	group int
	min   int
	max   int
}

// singleChar reports whether n consumes exactly one character and contains
// no group, so that a repetition of it can be compiled to one charloop.
func (n *node) singleChar() bool {
	return n.kind == nLit || n.kind == nAny || n.kind == nClass
}
