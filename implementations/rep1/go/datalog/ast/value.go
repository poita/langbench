// Package ast defines the abstract syntax of Datalog programs: constants,
// terms, atoms, literals, rules and programs.
package ast

import "strconv"

// Value is a constant: either an integer or a symbol (an identifier such as
// `alice`). Values are comparable and may be used as map keys.
type Value struct {
	isInt bool
	n     int64
	s     string
}

// Int returns the integer constant n.
func Int(n int64) Value { return Value{isInt: true, n: n} }

// Sym returns the symbolic constant s.
func Sym(s string) Value { return Value{s: s} }

// IsInt reports whether v is an integer constant.
func (v Value) IsInt() bool { return v.isInt }

// Int64 returns the integer value of v; it is 0 for symbols.
func (v Value) Int64() int64 { return v.n }

// Symbol returns the name of v; it is empty for integers.
func (v Value) Symbol() string { return v.s }

// String formats v as it is written in a program: integers in canonical
// decimal, symbols verbatim.
func (v Value) String() string {
	if v.isInt {
		return strconv.FormatInt(v.n, 10)
	}
	return v.s
}

// Compare orders constants: every integer is less than every symbol, integers
// compare numerically and symbols compare bytewise. It returns -1, 0 or +1.
func Compare(a, b Value) int {
	switch {
	case a.isInt && b.isInt:
		return cmp3(a.n < b.n, a.n > b.n)
	case a.isInt:
		return -1
	case b.isInt:
		return 1
	case a.s < b.s:
		return -1
	case a.s > b.s:
		return 1
	}
	return 0
}

func cmp3(less, greater bool) int {
	if less {
		return -1
	}
	if greater {
		return 1
	}
	return 0
}
