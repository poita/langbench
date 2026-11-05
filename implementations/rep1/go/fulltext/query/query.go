// Package query lexes and parses the boolean/phrase query language.
//
// Words and quoted phrases become atoms (sequences of index terms, see
// package analysis); AND, OR, NOT (upper case) and parentheses combine them.
// NOT binds tightest, then AND, then OR; juxtaposition means AND. Parsing
// never fails: malformed input is repaired as described by Parse.
package query

import (
	"strings"

	"example.com/fulltext/analysis"
)

// Op is the kind of a Node.
type Op int

// Node kinds.
const (
	Atom Op = iota // a leaf: a phrase of Terms
	And            // intersection of Children
	Or             // union of Children
	Not            // complement of the single child
)

// Node is a vertex of a parsed query tree. A nil *Node is the empty tree,
// which matches no document.
type Node struct {
	Op       Op
	Terms    []string // Atom only: the phrase's index terms
	Children []*Node  // And, Or, Not
}

// Key returns a string identifying an atom's term tuple; equal tuples have
// equal keys.
func Key(terms []string) string { return strings.Join(terms, "\x00") }

// Parse parses query text into a tree, returning nil for the empty tree.
//
// An atom is empty (and so dropped) when its text has no tokens or is a single
// stop word. Empty operands are dropped from AND/OR lists; NOT of an empty
// operand is empty; an unclosed '(' or '"' ends at the end of the line; a ')'
// that closes nothing ends the query.
func Parse(text string) *Node {
	p := &parser{toks: lex(text)}
	return p.parseOr()
}

// PositiveAtoms returns the atoms under an even number of NOTs, in
// depth-first left-to-right order of first appearance, without duplicates.
func PositiveAtoms(root *Node) [][]string {
	var out [][]string
	seen := map[string]bool{}
	var walk func(n *Node, positive bool)
	walk = func(n *Node, positive bool) {
		if n == nil {
			return
		}
		switch n.Op {
		case Atom:
			if k := Key(n.Terms); positive && !seen[k] {
				seen[k] = true
				out = append(out, n.Terms)
			}
		case Not:
			walk(n.Children[0], !positive)
		default:
			for _, c := range n.Children {
				walk(c, positive)
			}
		}
	}
	walk(root, true)
	return out
}

// Atoms returns every distinct atom in the tree, positive or not, in
// first-appearance order.
func Atoms(root *Node) [][]string {
	var out [][]string
	seen := map[string]bool{}
	var walk func(n *Node)
	walk = func(n *Node) {
		if n == nil {
			return
		}
		if n.Op == Atom {
			if k := Key(n.Terms); !seen[k] {
				seen[k] = true
				out = append(out, n.Terms)
			}
			return
		}
		for _, c := range n.Children {
			walk(c)
		}
	}
	walk(root)
	return out
}

// IsSpace reports whether the text at s[i:] starts with one of the seven
// whitespace code points (U+0009-U+000D, U+0020, U+00A0) and returns its
// length in bytes.
func IsSpace(s string, i int) (bool, int) {
	c := s[i]
	if c == ' ' || (c >= 9 && c <= 13) {
		return true, 1
	}
	if c == 0xC2 && i+1 < len(s) && s[i+1] == 0xA0 {
		return true, 2
	}
	return false, 0
}

// TrimSpace strips leading and trailing whitespace (the seven code points
// above) from s.
func TrimSpace(s string) string {
	for len(s) > 0 {
		if ok, n := IsSpace(s, 0); ok {
			s = s[n:]
		} else {
			break
		}
	}
	for len(s) > 0 {
		if c := s[len(s)-1]; c == ' ' || (c >= 9 && c <= 13) {
			s = s[:len(s)-1]
		} else if len(s) >= 2 && c == 0xA0 && s[len(s)-2] == 0xC2 {
			s = s[:len(s)-2]
		} else {
			break
		}
	}
	return s
}

type tokKind int

const (
	tkLParen tokKind = iota
	tkRParen
	tkAnd
	tkOr
	tkNot
	tkAtom
)

type token struct {
	kind  tokKind
	terms []string // tkAtom: nil when the atom is empty
}

// atomOf analyses a phrase body into an atom's terms (nil if empty).
func atomOf(body string) []string {
	toks := analysis.Analyze(body)
	switch {
	case len(toks) == 0:
		return nil
	case len(toks) == 1 && analysis.IsStopWord(toks[0].Folded):
		return nil
	}
	terms := make([]string, len(toks))
	for i, t := range toks {
		terms[i] = t.Term
	}
	return terms
}

func lex(s string) []token {
	var toks []token
	for i := 0; i < len(s); {
		if ok, n := IsSpace(s, i); ok {
			i += n
			continue
		}
		switch s[i] {
		case '(':
			toks = append(toks, token{kind: tkLParen})
			i++
		case ')':
			toks = append(toks, token{kind: tkRParen})
			i++
		case '"':
			j := strings.IndexByte(s[i+1:], '"')
			end, next := len(s), len(s)
			if j >= 0 {
				end = i + 1 + j
				next = end + 1
			}
			toks = append(toks, token{kind: tkAtom, terms: atomOf(s[i+1 : end])})
			i = next
		default:
			j := i
			for j < len(s) && s[j] != '(' && s[j] != ')' && s[j] != '"' {
				if ok, _ := IsSpace(s, j); ok {
					break
				}
				j++
			}
			switch word := s[i:j]; word {
			case "AND":
				toks = append(toks, token{kind: tkAnd})
			case "OR":
				toks = append(toks, token{kind: tkOr})
			case "NOT":
				toks = append(toks, token{kind: tkNot})
			default:
				toks = append(toks, token{kind: tkAtom, terms: atomOf(word)})
			}
			i = j
		}
	}
	return toks
}

type parser struct {
	toks []token
	pos  int
}

// peek returns the next token's kind, or -1 at end of input.
func (p *parser) peek() tokKind {
	if p.pos >= len(p.toks) {
		return -1
	}
	return p.toks[p.pos].kind
}

func combine(op Op, parts []*Node) *Node {
	switch len(parts) {
	case 0:
		return nil
	case 1:
		return parts[0]
	}
	return &Node{Op: op, Children: parts}
}

func (p *parser) parseOr() *Node {
	var parts []*Node
	if n := p.parseAnd(); n != nil {
		parts = append(parts, n)
	}
	for p.peek() == tkOr {
		p.pos++
		if n := p.parseAnd(); n != nil {
			parts = append(parts, n)
		}
	}
	return combine(Or, parts)
}

func (p *parser) parseAnd() *Node {
	var parts []*Node
	for {
		k := p.peek()
		if k == -1 || k == tkRParen || k == tkOr {
			break
		}
		if k == tkAnd {
			p.pos++
			continue
		}
		if n := p.parseNot(); n != nil {
			parts = append(parts, n)
		}
	}
	return combine(And, parts)
}

func (p *parser) parseNot() *Node {
	nots := 0
	for p.peek() == tkNot {
		p.pos++
		nots++
	}
	n := p.parsePrimary()
	if n == nil {
		return nil
	}
	for ; nots > 0; nots-- {
		n = &Node{Op: Not, Children: []*Node{n}}
	}
	return n
}

func (p *parser) parsePrimary() *Node {
	switch p.peek() {
	case -1, tkRParen:
		return nil
	case tkLParen:
		p.pos++
		n := p.parseOr()
		if p.peek() == tkRParen {
			p.pos++
		}
		return n
	case tkAtom:
		t := p.toks[p.pos]
		p.pos++
		if t.terms == nil {
			return nil
		}
		return &Node{Op: Atom, Terms: t.terms}
	}
	p.pos++
	return nil
}
