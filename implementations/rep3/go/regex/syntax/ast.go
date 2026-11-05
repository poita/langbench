// Package syntax parses the supported regular-expression dialect into a
// syntax tree and computes the static properties of that tree (nullability,
// first-character set, start anchoring) that the matcher uses to skip
// hopeless start positions.
//
// The dialect is: literals, '.', '^', '$', character classes, the escapes
// \d \D \w \W \s \S and escaped punctuation, capturing groups, alternation
// and the greedy quantifiers * + ? {n} {n,} {n,m}.
package syntax

// Kind identifies the type of a Node.
type Kind uint8

// Node kinds.
const (
	KindLiteral Kind = iota // a single byte, Node.Char
	KindAny                 // '.'
	KindClass               // class or set escape, Node.Set
	KindBOL                 // '^'
	KindEOL                 // '$'
	KindSeq                 // concatenation of Node.Subs (empty means the empty regex)
	KindAlt                 // ordered choice between Node.Subs
	KindGroup               // capturing group Node.Index around Node.Subs[0]
	KindRep                 // Node.Subs[0] repeated Min..Max times
)

// Unbounded is the Max value of a repetition with no upper bound.
const Unbounded = -1

// Node is a node of the syntax tree.
type Node struct {
	Kind  Kind
	Char  byte     // KindLiteral
	Set   *CharSet // KindClass
	Subs  []*Node  // KindSeq, KindAlt: children; KindGroup, KindRep: exactly one
	Index int      // KindGroup: 1-based group number
	Min   int      // KindRep
	Max   int      // KindRep: Unbounded or >= Min
}

// IsSingleChar reports whether the node always consumes exactly one
// character and contains no group: a literal, '.' or a class.
func (n *Node) IsSingleChar() bool {
	switch n.Kind {
	case KindLiteral, KindAny, KindClass:
		return true
	}
	return false
}

// Tree is a parsed pattern.
type Tree struct {
	Root      *Node
	NumGroups int
}
