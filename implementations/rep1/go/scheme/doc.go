// Package scheme implements an interpreter for a small subset of Scheme.
//
// The implementation is a pre-analysing interpreter: the reader (Reader)
// turns source text into datums, each top-level form is analysed once into a
// tree of nodes, and that tree is evaluated by a trampolined evaluator so
// that tail calls run in constant host stack. Environments are chains of
// small frames looked up by name at run time. Integers are 64-bit while they
// fit and become arbitrary-precision (package bigint) on overflow.
//
// Typical use:
//
//	in := scheme.New(os.Stdout)
//	err := in.Run(`(display (+ 1 2)) (newline)`)
//
// Runtime errors (unbound variables, type errors, ...) are reported as
// *Error values; malformed programs are reported as *SyntaxError.
package scheme
