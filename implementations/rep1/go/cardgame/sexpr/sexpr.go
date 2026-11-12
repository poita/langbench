// Package sexpr reads and prints the small s-expression dialect used by
// Spiremark card databases.
//
// The lexical rules are deliberately tiny: whitespace separates tokens, ';'
// starts a comment that runs to the end of the line, strings are delimited by
// double quotes and have no escapes (and may not contain a newline), and every
// other maximal run of characters is an atom. Atoms matching -?[0-9]+ are
// integers; everything else is a symbol.
package sexpr

import (
	"fmt"
	"strconv"
	"strings"
)

// Kind discriminates the four node shapes.
type Kind int

// Node kinds.
const (
	List Kind = iota
	Symbol
	Int
	String
)

// Node is one parsed s-expression.
type Node struct {
	Kind Kind
	Text string // symbol name or string contents
	Num  int64  // value of an Int node
	Kids []Node // elements of a List node
}

// IsSym reports whether n is the symbol s.
func (n Node) IsSym(s string) bool { return n.Kind == Symbol && n.Text == s }

// Head returns the leading symbol of a list and the remaining elements. ok is
// false when n is not a non-empty list starting with a symbol.
func (n Node) Head() (name string, args []Node, ok bool) {
	if n.Kind != List || len(n.Kids) == 0 || n.Kids[0].Kind != Symbol {
		return "", nil, false
	}
	return n.Kids[0].Text, n.Kids[1:], true
}

// String prints n in canonical form: lists as "(a b c)", symbols verbatim,
// integers in minimal decimal and strings in double quotes.
func (n Node) String() string {
	var sb strings.Builder
	n.write(&sb)
	return sb.String()
}

func (n Node) write(sb *strings.Builder) {
	switch n.Kind {
	case List:
		sb.WriteByte('(')
		for i, k := range n.Kids {
			if i > 0 {
				sb.WriteByte(' ')
			}
			k.write(sb)
		}
		sb.WriteByte(')')
	case Symbol:
		sb.WriteString(n.Text)
	case Int:
		sb.WriteString(strconv.FormatInt(n.Num, 10))
	case String:
		sb.WriteByte('"')
		sb.WriteString(n.Text)
		sb.WriteByte('"')
	}
}

// SyntaxError describes a lexical or structural problem.
type SyntaxError struct {
	Line int
	Msg  string
}

func (e *SyntaxError) Error() string { return fmt.Sprintf("line %d: %s", e.Line, e.Msg) }

func isSpace(c byte) bool {
	return c == ' ' || c == '\t' || c == '\r' || c == '\n' || c == '\f' || c == '\v'
}

func isAtomByte(c byte) bool {
	return !isSpace(c) && c != '(' && c != ')' && c != ';' && c != '"'
}

func isIntAtom(s string) bool {
	if strings.HasPrefix(s, "-") {
		s = s[1:]
	}
	if s == "" {
		return false
	}
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return false
		}
	}
	return true
}

// ParseAll parses src into its sequence of top-level nodes. Any top-level
// element is accepted here (callers decide whether atoms are allowed).
func ParseAll(src string) ([]Node, error) {
	var stack [][]Node
	var cur []Node
	line := 1
	i := 0
	for i < len(src) {
		c := src[i]
		switch {
		case c == '\n':
			line++
			i++
		case isSpace(c):
			i++
		case c == ';':
			for i < len(src) && src[i] != '\n' {
				i++
			}
		case c == '(':
			stack = append(stack, cur)
			cur = nil
			i++
		case c == ')':
			if len(stack) == 0 {
				return nil, &SyntaxError{line, "unbalanced ')'"}
			}
			list := Node{Kind: List, Kids: cur}
			cur = append(stack[len(stack)-1], list)
			stack = stack[:len(stack)-1]
			i++
		case c == '"':
			j := i + 1
			for j < len(src) && src[j] != '"' && src[j] != '\n' {
				j++
			}
			if j >= len(src) || src[j] != '"' {
				return nil, &SyntaxError{line, "unterminated string"}
			}
			cur = append(cur, Node{Kind: String, Text: src[i+1 : j]})
			i = j + 1
		default:
			j := i
			for j < len(src) && isAtomByte(src[j]) {
				j++
			}
			atom := src[i:j]
			if isIntAtom(atom) {
				v, err := strconv.ParseInt(atom, 10, 64)
				if err != nil {
					return nil, &SyntaxError{line, "integer out of range: " + atom}
				}
				cur = append(cur, Node{Kind: Int, Num: v})
			} else {
				cur = append(cur, Node{Kind: Symbol, Text: atom})
			}
			i = j
		}
	}
	if len(stack) != 0 {
		return nil, &SyntaxError{line, "unbalanced '('"}
	}
	return cur, nil
}
