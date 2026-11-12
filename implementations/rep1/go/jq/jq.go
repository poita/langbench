// Package jq is an interpreter for a subset of the jq query language, written
// from scratch with no dependencies beyond the Go standard library.
//
// Typical use is to compile a filter once and run it on parsed JSON values:
//
//	q, err := jq.Compile(`.users | map(select(.age >= 30)) | sort_by(.age)`)
//	if err != nil { ... }
//	doc, err := jq.ParseJSON(data)
//	if err != nil { ... }
//	err = q.Run(doc, func(v jq.Value) error {
//		fmt.Println(string(jq.Marshal(v)))
//		return nil
//	})
//
// The packages underneath are usable on their own: package value holds the
// JSON data model, decoder, encoder and ordering; package syntax the filter
// parser; and package interp the evaluator.
package jq

import (
	"errors"
	"iter"

	"example.com/jq/interp"
	"example.com/jq/syntax"
	"example.com/jq/value"
)

// Value is a JSON value: nil, bool, float64, string, []Value or *Object. See
// package value for details. Values are immutable and may be shared freely.
type Value = value.Value

// Object is an immutable insertion-ordered JSON object.
type Object = value.Object

// Error types returned by this package.
type (
	// SyntaxError reports a malformed filter.
	SyntaxError = syntax.Error
	// RuntimeError reports an error raised while evaluating a filter.
	RuntimeError = interp.Error
	// JSONError reports malformed JSON input.
	JSONError = value.SyntaxError
)

// Query is a compiled filter. It is immutable and safe for concurrent use.
type Query struct {
	src  string
	prog *interp.Program
}

// Compile parses and compiles a filter. Syntax problems are reported as a
// *SyntaxError; unknown builtins or variables as a plain error.
func Compile(filter string) (*Query, error) {
	ast, err := syntax.Parse(filter)
	if err != nil {
		return nil, err
	}
	prog, err := interp.Compile(ast)
	if err != nil {
		return nil, err
	}
	return &Query{src: filter, prog: prog}, nil
}

// MustCompile is like Compile but panics on error.
func MustCompile(filter string) *Query {
	q, err := Compile(filter)
	if err != nil {
		panic(err)
	}
	return q
}

// String returns the filter text.
func (q *Query) String() string { return q.src }

// Run evaluates the filter on input and calls yield for each output, in
// order, as it is produced. Evaluation stops at the first error: a
// *RuntimeError raised by the filter, or any error returned by yield, which
// is returned unchanged.
func (q *Query) Run(input Value, yield func(Value) error) error {
	return q.prog.Run(input, yield)
}

// All evaluates the filter and collects its outputs. On a runtime error it
// returns the outputs produced before the error along with the error.
func (q *Query) All(input Value) ([]Value, error) {
	var out []Value
	err := q.prog.Run(input, func(v Value) error {
		out = append(out, v)
		return nil
	})
	return out, err
}

var errStop = errors.New("jq: stop")

// Iter returns the outputs as an iterator. A runtime error is delivered as the
// final (nil, err) pair.
func (q *Query) Iter(input Value) iter.Seq2[Value, error] {
	return func(yield func(Value, error) bool) {
		err := q.prog.Run(input, func(v Value) error {
			if !yield(v, nil) {
				return errStop
			}
			return nil
		})
		if err != nil && err != errStop {
			yield(nil, err)
		}
	}
}

// ParseJSON decodes one JSON document.
func ParseJSON(data []byte) (Value, error) { return value.Parse(data) }

// Marshal returns the compact JSON text of v.
func Marshal(v Value) []byte { return value.Marshal(v) }

// Compare orders two values by jq's total order.
func Compare(a, b Value) int { return value.Compare(a, b) }
