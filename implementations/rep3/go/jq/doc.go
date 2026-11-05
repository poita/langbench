// Package jq implements an interpreter for a subset of the jq filter
// language (semantics of jq 1.7, compact output).
//
// A filter is compiled once with Compile and can then be run against any
// number of input values:
//
//	q, err := jq.Compile(`.users | map(select(.age >= 30)) | length`)
//	if err != nil { ... }
//	doc, _ := value.ParseString(`{"users":[{"age":31},{"age":20}]}`)
//	err = q.Run(doc, func(v value.Value) error {
//		fmt.Println(value.JSON(v))
//		return nil
//	})
//
// The implementation is a push-style tree-walking interpreter: every node is
// evaluated by calling a sink once per output, in stream order, so nested
// generators are nested loops of callbacks. Values (package value) are
// immutable and shared by reference.
//
// The package is organised as follows:
//
//   - lexer.go:    tokeniser for the filter text
//   - ast.go:      the syntax tree
//   - parser.go:   recursive-descent parser
//   - eval.go:     the evaluator (streams, paths, try, reduce, ...)
//   - ops.go:      arithmetic, indexing and slicing on values
//   - builtins.go: builtin functions (length, sort_by, add, ...)
//   - jq.go:       the public API
package jq
