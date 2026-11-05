// Package jq is a small implementation of a subset of the jq query language.
//
// A filter is compiled once with Compile and can then be run against any
// number of JSON documents:
//
//	prog, err := jq.Compile(`.users | map(select(.age >= 30)) | length`)
//	if err != nil { ... }
//	doc, err := jq.ParseJSON(data)
//	if err != nil { ... }
//	err = prog.Run(doc, func(v jq.Value) error {
//		fmt.Println(jq.Marshal(v))
//		return nil
//	})
//
// The package is organised as follows:
//
//   - example.com/jq/value:  the immutable value model, ordering and arithmetic
//   - example.com/jq/jsonio: the JSON parser and serialiser
//   - example.com/jq/syntax: the filter lexer, parser and syntax tree
//   - example.com/jq/interp: the push-style evaluator and the builtins
//
// This package ties them together behind a small API.
package jq

import (
	"example.com/jq/interp"
	"example.com/jq/jsonio"
	"example.com/jq/syntax"
	"example.com/jq/value"
)

// Value is a JSON value. See package value for its accessors.
type Value = value.Value

// Error is the type of errors raised while evaluating a filter (type errors,
// division by zero, error(...)).
type Error = value.Error

// Program is a compiled filter. It is immutable and safe to reuse, but a
// Program must not be run from several goroutines at once on values that
// share structure, since objects build their lookup indexes lazily.
type Program struct{ p *interp.Program }

// Compile parses a filter and checks its builtins and variables.
func Compile(filter string) (*Program, error) {
	ast, err := syntax.Parse(filter)
	if err != nil {
		return nil, err
	}
	p, err := interp.Compile(ast)
	if err != nil {
		return nil, err
	}
	return &Program{p}, nil
}

// Run evaluates the filter on input and calls emit for every output, in
// order. It stops at the first error: either an *Error raised by the filter,
// or the error returned by emit.
func (p *Program) Run(input Value, emit func(Value) error) error {
	return p.p.Run(input, emit)
}

// Query evaluates the filter and returns all outputs. On error it returns the
// outputs produced before the error together with the error.
func (p *Program) Query(input Value) ([]Value, error) {
	var out []Value
	err := p.p.Run(input, func(v Value) error {
		out = append(out, v)
		return nil
	})
	return out, err
}

// ParseJSON parses one JSON document.
func ParseJSON(data []byte) (Value, error) { return jsonio.Parse(data) }

// Marshal returns the compact JSON text of v.
func Marshal(v Value) string { return jsonio.Marshal(v) }

// AppendJSON appends the compact JSON text of v to dst.
func AppendJSON(dst []byte, v Value) []byte { return jsonio.Append(dst, v) }
