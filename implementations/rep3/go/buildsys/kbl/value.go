package kbl

import (
	"strconv"
	"strings"
)

// Kind is the dynamic type of a KBL value. The numeric order is the order of
// types in the total order over values: bool < int < str < list.
type Kind uint8

// Value kinds.
const (
	KindBool Kind = iota
	KindInt
	KindStr
	KindList
)

func (k Kind) String() string {
	switch k {
	case KindBool:
		return "bool"
	case KindInt:
		return "int"
	case KindStr:
		return "str"
	}
	return "list"
}

// Value is a KBL value. Strings are byte strings; copying a Value copies a
// handle (Go strings and slices are immutable here), never the bytes.
type Value struct {
	Kind Kind
	I    int64 // int value, or 0/1 for bool
	S    string
	L    []Value
}

// Constructors.
func strVal(s string) Value   { return Value{Kind: KindStr, S: s} }
func intVal(i int64) Value    { return Value{Kind: KindInt, I: i} }
func listVal(l []Value) Value { return Value{Kind: KindList, L: l} }
func boolVal(b bool) Value {
	if b {
		return Value{Kind: KindBool, I: 1}
	}
	return Value{Kind: KindBool}
}

// Str, Int, Bool and List construct values for callers of the package.
func Str(s string) Value    { return strVal(s) }
func Int(i int64) Value     { return intVal(i) }
func Bool(b bool) Value     { return boolVal(b) }
func List(l ...Value) Value { return listVal(l) }

// Text renders a str, int or bool as interpolation does. ok is false for lists.
func (v Value) Text() (string, bool) {
	switch v.Kind {
	case KindStr:
		return v.S, true
	case KindInt:
		return strconv.FormatInt(v.I, 10), true
	case KindBool:
		if v.I != 0 {
			return "true", true
		}
		return "false", true
	}
	return "", false
}

// Compare orders two values by the KBL total order, returning -1, 0 or 1.
func Compare(a, b Value) int {
	if a.Kind != b.Kind {
		if a.Kind < b.Kind {
			return -1
		}
		return 1
	}
	switch a.Kind {
	case KindBool, KindInt:
		switch {
		case a.I < b.I:
			return -1
		case a.I > b.I:
			return 1
		}
		return 0
	case KindStr:
		return strings.Compare(a.S, b.S)
	}
	for i := 0; i < len(a.L) && i < len(b.L); i++ {
		if c := Compare(a.L[i], b.L[i]); c != 0 {
			return c
		}
	}
	switch {
	case len(a.L) < len(b.L):
		return -1
	case len(a.L) > len(b.L):
		return 1
	}
	return 0
}

// Equal is deep structural equality.
func Equal(a, b Value) bool {
	if a.Kind != b.Kind {
		return false
	}
	switch a.Kind {
	case KindBool, KindInt:
		return a.I == b.I
	case KindStr:
		return a.S == b.S
	}
	if len(a.L) != len(b.L) {
		return false
	}
	for i := range a.L {
		if !Equal(a.L[i], b.L[i]) {
			return false
		}
	}
	return true
}
