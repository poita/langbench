package jq

import "jq/value"

type nodeKind uint8

const (
	nIdentity nodeKind = iota
	nLiteral
	nVar
	nField   // a.name            (a: target)
	nIndex   // a[b]
	nIterate // a[]
	nSlice   // a[b:c]
	nTry     // a?  (as try)
	nPipe    // a | b
	nComma   // a , b
	nBinary  // a op b
	nAnd
	nOr
	nNeg
	nArray  // [a]  (a may be nil)
	nObject // {entries}
	nIf     // if a then b else c end (c never nil)
	nBind   // a as $name | b
	nReduce // reduce a as $name (b; c)
	nCall   // builtin(args...)
)

type binOp uint8

const (
	opAdd binOp = iota
	opSub
	opMul
	opDiv
	opMod
	opEq
	opNe
	opLt
	opLe
	opGt
	opGe
)

// node is a syntax tree node. Which fields are used depends on kind.
type node struct {
	kind    nodeKind
	op      binOp
	opt     bool // path suffixes: tolerate errors of this one operation
	single  bool // statically known to yield exactly one output (or error)
	a, b, c *node
	val     value.Value // nLiteral
	name    string      // nField, nVar, nBind, nReduce
	fn      builtinID   // nCall
	args    []*node     // nCall
	entries []objEntry  // nObject
	litKeys bool        // nObject: all keys are distinct literals
}

type objEntry struct {
	key *node
	val *node
}
