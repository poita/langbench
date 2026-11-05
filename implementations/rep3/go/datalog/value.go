package datalog

import (
	"strconv"
	"strings"
)

// Value is a constant of the language: an integer or a symbol (identifier).
// The zero Value is the symbol with the empty name; use [Int] and [Sym] to
// construct values.
type Value struct {
	isInt bool
	num   int64
	name  string
}

// Int returns the integer constant n.
func Int(n int64) Value { return Value{isInt: true, num: n} }

// Sym returns the symbolic constant with the given identifier.
func Sym(name string) Value { return Value{name: name} }

// IsInt reports whether v is an integer constant.
func (v Value) IsInt() bool { return v.isInt }

// Int returns the integer value of v, or 0 if v is a symbol.
func (v Value) Int() int64 { return v.num }

// Name returns the identifier of v, or "" if v is an integer.
func (v Value) Name() string { return v.name }

// String returns the source text of v: canonical decimal for integers, the
// identifier for symbols.
func (v Value) String() string {
	if v.isInt {
		return strconv.FormatInt(v.num, 10)
	}
	return v.name
}

// Compare orders constants: every integer precedes every symbol, integers
// compare numerically and symbols bytewise. It returns -1, 0 or +1.
func (v Value) Compare(w Value) int {
	switch {
	case v.isInt && w.isInt:
		switch {
		case v.num < w.num:
			return -1
		case v.num > w.num:
			return 1
		}
		return 0
	case v.isInt:
		return -1
	case w.isInt:
		return 1
	}
	return strings.Compare(v.name, w.name)
}

// CompareTuples orders tuples lexicographically by [Value.Compare]. A proper
// prefix sorts first.
func CompareTuples(a, b []Value) int {
	for i := 0; i < len(a) && i < len(b); i++ {
		if c := a[i].Compare(b[i]); c != 0 {
			return c
		}
	}
	switch {
	case len(a) < len(b):
		return -1
	case len(a) > len(b):
		return 1
	}
	return 0
}
