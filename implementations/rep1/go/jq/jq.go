// Package jq is a small, dependency-free implementation of a subset of the
// jq query language (jq 1.7 semantics).
//
// A filter is compiled once with Compile and may then be run against any
// number of input values:
//
//	q, err := jq.Compile(`.users | map(select(.age >= 30)) | length`)
//	if err != nil { ... }
//	doc, err := jq.ParseJSON(`{"users":[{"age":31},{"age":20}]}`)
//	if err != nil { ... }
//	err = q.Run(doc, func(v jq.Value) error {
//		fmt.Println(jq.Marshal(v))
//		return nil
//	})
//
// The sub-packages hold the pieces: value (data model, ordering, JSON
// parser and serialiser), syntax (lexer, parser and AST) and interp
// (compiler and evaluator).
package jq

import (
	"github.com/peter/jq/interp"
	"github.com/peter/jq/syntax"
	"github.com/peter/jq/value"
)

// Value is an immutable JSON value.
type Value = value.Value

// RuntimeError is the error returned by Run when evaluation raises an error
// (a failing operation or the error builtin).
type RuntimeError = interp.Error

// Query is a compiled filter. It is immutable and safe for concurrent use.
type Query struct {
	prog *interp.Program
}

// Compile parses and compiles a filter. It fails with a *syntax.Error for
// malformed filters, or an ordinary error for undefined variables or
// builtins.
func Compile(filter string) (*Query, error) {
	ast, err := syntax.Parse(filter)
	if err != nil {
		return nil, err
	}
	prog, err := interp.Compile(ast)
	if err != nil {
		return nil, err
	}
	return &Query{prog: prog}, nil
}

// Run evaluates the filter on input and calls emit for each output, in
// order. It stops at the first error, returning it: a *RuntimeError if the
// filter raised one, or the error returned by emit.
func (q *Query) Run(input Value, emit func(Value) error) error {
	return q.prog.Run(input, emit)
}

// All evaluates the filter on input and collects the outputs produced before
// the first error, if any.
func (q *Query) All(input Value) ([]Value, error) {
	var out []Value
	err := q.Run(input, func(v Value) error {
		out = append(out, v)
		return nil
	})
	return out, err
}

// ParseJSON parses a single JSON document.
func ParseJSON(text string) (Value, error) { return value.Parse(text) }

// Marshal returns the compact JSON text of v.
func Marshal(v Value) string { return value.JSON(v) }

// AppendJSON appends the compact JSON text of v to buf.
func AppendJSON(buf []byte, v Value) []byte { return value.AppendJSON(buf, v) }
