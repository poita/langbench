// Package syntax parses the regular-expression dialect understood by regexbt
// into a syntax tree.
//
// The dialect is a small Perl-flavoured subset: literals, '.', '^', '$',
// character classes, the escapes \d \D \w \W \s \S, capturing groups,
// alternation and the greedy quantifiers * + ? {n} {n,} {n,m}.
package syntax

// Kind identifies the type of a Node.
type Kind uint8

// Node kinds.
const (
	KindEmpty     Kind = iota // matches the empty string
	KindLiteral               // a single byte, Node.Char
	KindAny                   // '.', any single byte
	KindClass                 // a character class, Node.Set
	KindBol                   // '^', start of subject
	KindEol                   // '$', end of subject
	KindConcat                // Subs matched in sequence
	KindAlternate             // Subs tried left to right
	KindGroup                 // capturing group Node.Group wrapping Subs[0]
	KindRepeat                // Subs[0] repeated Min..Max times (Max < 0: unbounded)
)

// Node is a node of the syntax tree.
type Node struct {
	Kind  Kind
	Char  byte    // KindLiteral
	Set   CharSet // KindClass (already negated for [^...] and \D etc.)
	Subs  []*Node // children (see Kind)
	Group int     // KindGroup: 1-based group number
	Min   int     // KindRepeat: minimum iterations
	Max   int     // KindRepeat: maximum iterations, or -1 for unbounded
}

// Unbounded is the Max value of a Repeat node without an upper limit.
const Unbounded = -1
