// Package scheme implements an interpreter for a small subset of Scheme.
//
// The pipeline is: a hand-written Reader turns source text into datums,
// a compiler converts each top-level datum once into a tree of pre-analysed
// nodes, and a single trampolined evaluator runs the tree with proper tail
// calls. Integers are arbitrary precision (fixnums with automatic promotion
// to the hand-written bignums in package bigint).
//
// Typical use:
//
//	in := scheme.New()
//	err := in.Run([]byte(`(display (* 99999999999 99999999999)) (newline)`))
//	os.Stdout.Write(in.Output())
//	if err != nil { ... } // *scheme.Error for runtime errors
//
// Run evaluates every top-level form in order, appending the printed value of
// each non-void result, and anything written by display/newline, to the
// interpreter's output buffer. Eval evaluates source and returns the value of
// the last form without printing.
package scheme
