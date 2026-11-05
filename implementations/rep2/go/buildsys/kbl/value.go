package kbl

import (
	"bytes"
	"strconv"
	"strings"
)

// Kind is the dynamic type of a Value. The numeric order of the kinds is the
// cross-type order of the specification: bool < int < str < list.
type Kind uint8

// Value kinds.
const (
	KBool Kind = iota
	KInt
	KStr
	KList
)

// String returns the type token used in error messages.
func (k Kind) String() string {
	switch k {
	case KBool:
		return "bool"
	case KInt:
		return "int"
	case KStr:
		return "str"
	}
	return "list"
}

// Value is a KBL value. Strings and lists are immutable and shared by
// handle, so copying a Value is O(1).
type Value struct {
	K Kind
	I int64 // KInt value, or 0/1 for KBool
	S string
	L []Value
}

// Constructors.
func boolVal(b bool) Value {
	if b {
		return Value{K: KBool, I: 1}
	}
	return Value{K: KBool}
}
func intVal(i int64) Value    { return Value{K: KInt, I: i} }
func strVal(s string) Value   { return Value{K: KStr, S: s} }
func listVal(l []Value) Value { return Value{K: KList, L: l} }

// Compare implements the total order of the specification.
func Compare(a, b Value) int {
	if a.K != b.K {
		if a.K < b.K {
			return -1
		}
		return 1
	}
	switch a.K {
	case KBool, KInt:
		switch {
		case a.I < b.I:
			return -1
		case a.I > b.I:
			return 1
		}
		return 0
	case KStr:
		return strings.Compare(a.S, b.S)
	}
	n := min(len(a.L), len(b.L))
	for i := 0; i < n; i++ {
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
	if a.K != b.K {
		return false
	}
	switch a.K {
	case KBool, KInt:
		return a.I == b.I
	case KStr:
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

// key appends an injective encoding of v, usable as a map key for
// deduplication.
func (v Value) key(b *bytes.Buffer) {
	switch v.K {
	case KBool, KInt:
		b.WriteByte('i')
		b.WriteString(strconv.FormatInt(v.I, 10))
		b.WriteByte(';')
		if v.K == KBool {
			b.WriteByte('b')
		}
	case KStr:
		b.WriteByte('s')
		b.WriteString(strconv.Itoa(len(v.S)))
		b.WriteByte(':')
		b.WriteString(v.S)
	default:
		b.WriteByte('l')
		b.WriteString(strconv.Itoa(len(v.L)))
		b.WriteByte(':')
		for _, e := range v.L {
			e.key(b)
		}
	}
}

// Text returns the interpolation text of a bool, int or str value.
func (v Value) text() string {
	switch v.K {
	case KStr:
		return v.S
	case KInt:
		return strconv.FormatInt(v.I, 10)
	case KBool:
		if v.I != 0 {
			return "true"
		}
		return "false"
	}
	return ""
}
