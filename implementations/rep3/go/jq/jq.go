package jq

import (
	"jq/value"
)

// Query is a compiled filter. It is immutable and safe to run repeatedly.
type Query struct {
	root *node
}

// Compile parses a filter.
func Compile(src string) (*Query, error) {
	n, err := parseFilter(src)
	if err != nil {
		return nil, err
	}
	return &Query{root: n}, nil
}

// Run evaluates the filter on input and calls emit for every output, in
// order. Evaluation stops at the first error: either a runtime error of the
// filter (of type *Error), which is returned after all earlier outputs have
// been emitted, or an error returned by emit, which is returned unchanged.
func (q *Query) Run(input value.Value, emit func(value.Value) error) error {
	return eval(q.root, input, nil, emit)
}

// Collect runs the filter and returns all outputs produced before the first
// error, together with that error (nil if evaluation completed).
func (q *Query) Collect(input value.Value) ([]value.Value, error) {
	var out []value.Value
	err := q.Run(input, func(v value.Value) error {
		out = append(out, v)
		return nil
	})
	return out, err
}
