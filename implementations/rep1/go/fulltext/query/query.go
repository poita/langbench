// Package query parses the boolean/phrase query language into a tree.
//
// The grammar is
//
//	query := or
//	or    := and ( "OR" and )*
//	and   := ( "AND" | not )*
//	not   := "NOT"* primary
//	primary := "(" or ")" | atom
//
// NOT binds tightest, then AND, then OR; juxtaposition means AND. Parsing never
// fails: malformed input is recovered from by dropping what cannot be used, and
// a query that yields nothing parses to the empty tree (a nil *Node).
package query

import (
	"strings"
	"unicode/utf8"

	"fulltext/analysis"
)

// Kind is the type of a [Node].
type Kind int

const (
	// Atom is a leaf: a sequence of terms that must occur adjacently.
	Atom Kind = iota
	// And is the intersection of its children.
	And
	// Or is the union of its children.
	Or
	// Not is the complement of its single child.
	Not
)

// Node is a node of the parse tree. The empty tree is the nil *Node.
type Node struct {
	Kind Kind
	// Terms is set for Atom nodes: the analysed terms, in order.
	Terms []string
	// Children holds the operands of And and Or (at least two) and the single
	// operand of Not.
	Children []*Node
}

// Key returns a string that is equal for two atoms exactly when their term
// tuples are equal.
func (n *Node) Key() string { return strings.Join(n.Terms, "\x00") }

// String renders the tree in a fully parenthesised form, for debugging and
// tests. The empty tree renders as "<empty>".
func (n *Node) String() string {
	if n == nil {
		return "<empty>"
	}
	switch n.Kind {
	case Atom:
		return "(" + strings.Join(n.Terms, " ") + ")"
	case Not:
		return "NOT " + n.Children[0].String()
	}
	op := " AND "
	if n.Kind == Or {
		op = " OR "
	}
	parts := make([]string, len(n.Children))
	for i, c := range n.Children {
		parts[i] = c.String()
	}
	return "[" + strings.Join(parts, op) + "]"
}

// PositiveAtoms returns the atoms that sit below an even number of NOT nodes,
// in depth-first left-to-right order of first appearance, duplicates dropped.
func (n *Node) PositiveAtoms() []*Node {
	var out []*Node
	seen := map[string]bool{}
	var walk func(n *Node, positive bool)
	walk = func(n *Node, positive bool) {
		if n == nil {
			return
		}
		switch n.Kind {
		case Atom:
			if positive && !seen[n.Key()] {
				seen[n.Key()] = true
				out = append(out, n)
			}
		case Not:
			walk(n.Children[0], !positive)
		default:
			for _, c := range n.Children {
				walk(c, positive)
			}
		}
	}
	walk(n, true)
	return out
}

// Atoms returns every distinct atom of the tree (positive or not), in order of
// first appearance.
func (n *Node) Atoms() []*Node {
	var out []*Node
	seen := map[string]bool{}
	var walk func(n *Node)
	walk = func(n *Node) {
		if n == nil {
			return
		}
		if n.Kind == Atom {
			if !seen[n.Key()] {
				seen[n.Key()] = true
				out = append(out, n)
			}
			return
		}
		for _, c := range n.Children {
			walk(c)
		}
	}
	walk(n)
	return out
}

type tokKind int

const (
	tEOF tokKind = iota
	tLParen
	tRParen
	tAnd
	tOr
	tNot
	tAtom
)

type token struct {
	kind tokKind
	atom *Node // for tAtom; nil when the atom is empty
}

// Parse parses query text, analysing atoms with a. It returns nil for the
// empty tree.
func Parse(text string, a *analysis.Analyzer) *Node {
	p := &parser{toks: lex(text, a)}
	return p.parseOr() // tokens left over (stray ")") are discarded
}

func lex(text string, a *analysis.Analyzer) []token {
	var toks []token
	for i := 0; i < len(text); {
		c := text[i]
		switch {
		case c == '(':
			toks = append(toks, token{kind: tLParen})
			i++
		case c == ')':
			toks = append(toks, token{kind: tRParen})
			i++
		case c == '"':
			j := strings.IndexByte(text[i+1:], '"')
			var body string
			if j < 0 {
				body, i = text[i+1:], len(text)
			} else {
				body, i = text[i+1:i+1+j], i+j+2
			}
			toks = append(toks, token{kind: tAtom, atom: makeAtom(body, a)})
		default:
			if r, sz := decodeRune(text, i); analysis.IsSpace(r) {
				i += sz
				continue
			}
			j := i
			for j < len(text) {
				r, sz := decodeRune(text, j)
				if analysis.IsSpace(r) || r == '(' || r == ')' || r == '"' {
					break
				}
				j += sz
			}
			switch w := text[i:j]; w {
			case "AND":
				toks = append(toks, token{kind: tAnd})
			case "OR":
				toks = append(toks, token{kind: tOr})
			case "NOT":
				toks = append(toks, token{kind: tNot})
			default:
				toks = append(toks, token{kind: tAtom, atom: makeAtom(w, a)})
			}
			i = j
		}
	}
	return toks
}

func decodeRune(s string, i int) (rune, int) {
	return utf8.DecodeRuneInString(s[i:])
}

// makeAtom analyses a phrase body. It returns nil (empty) for zero terms and
// for a single stop word.
func makeAtom(body string, a *analysis.Analyzer) *Node {
	toks := a.Analyze(body)
	switch {
	case len(toks) == 0:
		return nil
	case len(toks) == 1 && analysis.IsStopWord(toks[0].Text):
		return nil
	}
	terms := make([]string, len(toks))
	for i, t := range toks {
		terms[i] = t.Term
	}
	return &Node{Kind: Atom, Terms: terms}
}

type parser struct {
	toks []token
	pos  int
}

func (p *parser) peek() tokKind {
	if p.pos >= len(p.toks) {
		return tEOF
	}
	return p.toks[p.pos].kind
}

// combine builds the node for the non-empty results of an and/or list.
func combine(kind Kind, items []*Node) *Node {
	switch len(items) {
	case 0:
		return nil
	case 1:
		return items[0]
	}
	return &Node{Kind: kind, Children: items}
}

func (p *parser) parseOr() *Node {
	var items []*Node
	if n := p.parseAnd(); n != nil {
		items = append(items, n)
	}
	for p.peek() == tOr {
		p.pos++
		if n := p.parseAnd(); n != nil {
			items = append(items, n)
		}
	}
	return combine(Or, items)
}

func (p *parser) parseAnd() *Node {
	var items []*Node
	for {
		switch p.peek() {
		case tEOF, tRParen, tOr:
			return combine(And, items)
		case tAnd:
			p.pos++
			continue
		}
		if n := p.parseNot(); n != nil {
			items = append(items, n)
		}
	}
}

func (p *parser) parseNot() *Node {
	nots := 0
	for p.peek() == tNot {
		p.pos++
		nots++
	}
	n := p.parsePrimary()
	if n == nil {
		return nil
	}
	for ; nots > 0; nots-- {
		n = &Node{Kind: Not, Children: []*Node{n}}
	}
	return n
}

func (p *parser) parsePrimary() *Node {
	switch p.peek() {
	case tEOF, tRParen:
		return nil
	case tLParen:
		p.pos++
		n := p.parseOr()
		if p.peek() == tRParen {
			p.pos++
		}
		return n
	case tAtom:
		n := p.toks[p.pos].atom
		p.pos++
		return n
	}
	p.pos++ // any other token is consumed and yields nothing
	return nil
}
