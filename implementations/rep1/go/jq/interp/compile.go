// Package interp compiles jq filter ASTs and evaluates them with a
// tree-walking interpreter in push style: evaluating a node against an input
// calls a sink function once per output, in stream order.
package interp

import (
	"fmt"

	"github.com/peter/jq/syntax"
	"github.com/peter/jq/value"
)

// node is a compiled filter node: the syntax tree with variables resolved to
// environment depths and builtin calls resolved to builtin ids.
type node struct {
	op       syntax.Op
	a, b, c  *node
	val      value.Value
	bin      syntax.BinOp
	bi       builtinID
	args     []*node
	entries  []objEntry
	optional bool
	slot     int // variable: number of environment hops from the innermost binding

	// literalKeys is true for an object construction whose keys are all
	// distinct literals, so combinations can be copied straight from slots.
	literalKeys bool
	// constKey is the literal string of an index with a literal key.
	constKey    string
	hasConstKey bool
}

type objEntry struct {
	key, val *node
	litKey   string
	isLit    bool
}

// Program is a compiled filter. It is immutable and may be run concurrently.
type Program struct {
	root *node
}

// Compile resolves variables and builtin calls in ast.
func Compile(ast *syntax.Node) (*Program, error) {
	c := &compiler{}
	root, err := c.compile(ast)
	if err != nil {
		return nil, err
	}
	return &Program{root: root}, nil
}

type compiler struct {
	scope []string // names of the variables in scope, innermost last
}

func (c *compiler) compile(n *syntax.Node) (*node, error) {
	if n == nil {
		return nil, nil
	}
	out := &node{op: n.Op, val: n.Val, bin: n.Bin, optional: n.Optional}
	var err error
	sub := func(s *syntax.Node) *node {
		if err != nil {
			return nil
		}
		var r *node
		r, err = c.compile(s)
		return r
	}
	switch n.Op {
	case syntax.OpVar:
		for i := len(c.scope) - 1; i >= 0; i-- {
			if c.scope[i] == n.Name {
				out.slot = len(c.scope) - 1 - i
				return out, nil
			}
		}
		return nil, fmt.Errorf("$%s is not defined", n.Name)
	case syntax.OpAs:
		out.a = sub(n.A)
		c.scope = append(c.scope, n.Name)
		out.b = sub(n.B)
		c.scope = c.scope[:len(c.scope)-1]
	case syntax.OpReduce:
		out.a = sub(n.A)
		out.b = sub(n.B)
		c.scope = append(c.scope, n.Name)
		out.c = sub(n.C)
		c.scope = c.scope[:len(c.scope)-1]
	case syntax.OpObject:
		out.literalKeys = true
		seen := map[string]bool{}
		for _, e := range n.Entries {
			oe := objEntry{key: sub(e.Key), val: sub(e.Value)}
			if err != nil {
				return nil, err
			}
			if e.Key.Op == syntax.OpLiteral && e.Key.Val.Kind() == value.KindString {
				oe.isLit, oe.litKey = true, e.Key.Val.Str()
				if seen[oe.litKey] {
					out.literalKeys = false
				}
				seen[oe.litKey] = true
			} else {
				out.literalKeys = false
			}
			out.entries = append(out.entries, oe)
		}
	case syntax.OpCall:
		b, ok := lookupBuiltin(n.Name, len(n.Args))
		if !ok {
			return nil, fmt.Errorf("%s/%d is not defined", n.Name, len(n.Args))
		}
		out.bi = b
		for _, a := range n.Args {
			out.args = append(out.args, sub(a))
		}
	case syntax.OpIndex:
		out.a = sub(n.A)
		out.b = sub(n.B)
		if n.B.Op == syntax.OpLiteral && n.B.Val.Kind() == value.KindString {
			out.hasConstKey, out.constKey = true, n.B.Val.Str()
		}
	default:
		out.a, out.b, out.c = sub(n.A), sub(n.B), sub(n.C)
	}
	if err != nil {
		return nil, err
	}
	return out, nil
}
