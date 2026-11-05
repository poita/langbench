// Package sexpr reads and prints the small s-expression dialect used by
// Spiremark card databases.
//
// The dialect has four kinds of value: lists, symbols, integers and strings.
// Comments start with ';' and run to the end of the line. Strings are
// delimited by double quotes, may not contain a newline and have no escapes.
package sexpr

import (
	"errors"
	"strconv"
	"strings"
)

// Kind is the type of a Node.
type Kind uint8

// Node kinds.
const (
	List Kind = iota
	Symbol
	Int
	String
)

// Node is one parsed s-expression value.
type Node struct {
	Kind  Kind
	Text  string  // symbol name or string contents
	Int   int64   // value of an Int node
	Items []*Node // elements of a List node
}

// Errors returned by Parse.
var (
	ErrUnbalanced   = errors.New("sexpr: unbalanced parentheses")
	ErrUnterminated = errors.New("sexpr: unterminated string")
	ErrBadInteger   = errors.New("sexpr: integer out of range")
)

func isSpace(c byte) bool {
	switch c {
	case ' ', '\t', '\r', '\n', '\f', '\v':
		return true
	}
	return false
}

func isDelim(c byte) bool {
	return isSpace(c) || c == '(' || c == ')' || c == ';' || c == '"'
}

// isIntAtom reports whether s matches -?[0-9]+.
func isIntAtom(s string) bool {
	if s != "" && s[0] == '-' {
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

// Parse reads every top-level value of src.
func Parse(src []byte) ([]*Node, error) {
	var stack [][]*Node
	var top []*Node
	i := 0
	for i < len(src) {
		c := src[i]
		switch {
		case isSpace(c):
			i++
		case c == ';':
			for i < len(src) && src[i] != '\n' {
				i++
			}
		case c == '(':
			stack = append(stack, top)
			top = nil
			i++
		case c == ')':
			if len(stack) == 0 {
				return nil, ErrUnbalanced
			}
			n := &Node{Kind: List, Items: top}
			top = append(stack[len(stack)-1], n)
			stack = stack[:len(stack)-1]
			i++
		case c == '"':
			j := i + 1
			for j < len(src) && src[j] != '"' && src[j] != '\n' {
				j++
			}
			if j >= len(src) || src[j] != '"' {
				return nil, ErrUnterminated
			}
			top = append(top, &Node{Kind: String, Text: string(src[i+1 : j])})
			i = j + 1
		default:
			j := i
			for j < len(src) && !isDelim(src[j]) {
				j++
			}
			atom := string(src[i:j])
			i = j
			if isIntAtom(atom) {
				v, err := strconv.ParseInt(atom, 10, 64)
				if err != nil {
					return nil, ErrBadInteger
				}
				top = append(top, &Node{Kind: Int, Int: v, Text: atom})
			} else {
				top = append(top, &Node{Kind: Symbol, Text: atom})
			}
		}
	}
	if len(stack) != 0 {
		return nil, ErrUnbalanced
	}
	return top, nil
}

// String returns the canonical printing of n: lists as "(a b c)" with single
// spaces, strings in double quotes and integers in minimal decimal.
func (n *Node) String() string {
	var sb strings.Builder
	n.write(&sb)
	return sb.String()
}

func (n *Node) write(sb *strings.Builder) {
	switch n.Kind {
	case List:
		sb.WriteByte('(')
		for i, it := range n.Items {
			if i > 0 {
				sb.WriteByte(' ')
			}
			it.write(sb)
		}
		sb.WriteByte(')')
	case Symbol:
		sb.WriteString(n.Text)
	case Int:
		sb.WriteString(strconv.FormatInt(n.Int, 10))
	case String:
		sb.WriteByte('"')
		sb.WriteString(n.Text)
		sb.WriteByte('"')
	}
}

// Head returns the symbol at the head of a non-empty list, or "".
func (n *Node) Head() string {
	if n.Kind == List && len(n.Items) > 0 && n.Items[0].Kind == Symbol {
		return n.Items[0].Text
	}
	return ""
}

// IsSym reports whether n is the symbol s.
func (n *Node) IsSym(s string) bool { return n.Kind == Symbol && n.Text == s }
