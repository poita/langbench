// Package syntax parses the regular-expression dialect understood by the
// parent package into an abstract syntax tree.
//
// The dialect is a small Perl-style subset: literals, '.', '^', '$',
// character classes, the escapes \d \D \w \W \s \S, capturing groups,
// alternation and the quantifiers * + ? {n} {n,} {n,m}.
package syntax

import (
	"fmt"
	"strings"
)

// Kind identifies the type of a Node.
type Kind uint8

// Node kinds.
const (
	Empty       Kind = iota // matches the empty string
	Literal                 // a single byte, Node.Char
	AnyChar                 // '.'
	Class                   // a character set, Node.Set
	StartAnchor             // '^': position 0 only
	EndAnchor               // '$': end of subject only
	Concat                  // Subs matched in sequence
	Alternate               // Subs tried left to right
	Group                   // capturing group Node.Index around Subs[0]
	Repeat                  // Subs[0] repeated Min..Max times (greedy)
)

// Unbounded is the Max value of a Repeat with no upper bound.
const Unbounded = -1

// Node is an element of the syntax tree.
type Node struct {
	Kind  Kind
	Char  byte    // Literal
	Set   CharSet // Class
	Subs  []*Node // Concat, Alternate: operands; Group, Repeat: one operand
	Index int     // Group: 1-based capture index
	Min   int     // Repeat: minimum iterations
	Max   int     // Repeat: maximum iterations, or Unbounded
}

// String renders the node as a pattern-like debugging string. Classes are
// shown as [..] and need not round-trip.
func (n *Node) String() string {
	var b strings.Builder
	n.write(&b)
	return b.String()
}

func (n *Node) write(b *strings.Builder) {
	switch n.Kind {
	case Empty:
	case Literal:
		fmt.Fprintf(b, "%q", n.Char)
	case AnyChar:
		b.WriteByte('.')
	case Class:
		b.WriteString("[..]")
	case StartAnchor:
		b.WriteByte('^')
	case EndAnchor:
		b.WriteByte('$')
	case Concat:
		b.WriteByte('<')
		for _, s := range n.Subs {
			s.write(b)
		}
		b.WriteByte('>')
	case Alternate:
		b.WriteByte('(')
		for i, s := range n.Subs {
			if i > 0 {
				b.WriteByte('|')
			}
			s.write(b)
		}
		b.WriteByte(')')
	case Group:
		fmt.Fprintf(b, "#%d(", n.Index)
		n.Subs[0].write(b)
		b.WriteByte(')')
	case Repeat:
		b.WriteByte('{')
		n.Subs[0].write(b)
		if n.Max == Unbounded {
			fmt.Fprintf(b, "}%d,", n.Min)
		} else {
			fmt.Fprintf(b, "}%d,%d", n.Min, n.Max)
		}
	}
}

// CanBeEmpty reports whether the node might match without consuming input.
// The answer is conservative: anchors count as empty, so "true" means
// "possibly".
func (n *Node) CanBeEmpty() bool {
	switch n.Kind {
	case Literal, AnyChar, Class:
		return false
	case Concat:
		for _, s := range n.Subs {
			if !s.CanBeEmpty() {
				return false
			}
		}
		return true
	case Alternate:
		for _, s := range n.Subs {
			if s.CanBeEmpty() {
				return true
			}
		}
		return false
	case Group:
		return n.Subs[0].CanBeEmpty()
	case Repeat:
		return n.Min == 0 || n.Subs[0].CanBeEmpty()
	}
	return true // Empty, anchors
}
