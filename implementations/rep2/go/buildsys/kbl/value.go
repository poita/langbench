package kbl

import (
	"strconv"
	"strings"
)

// Kind is the dynamic type of a Value. The numeric order is the cross-type
// order of the total ordering: bool < int < str < list.
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

// Value is a KBL value. Strings and lists are immutable, so copying a Value is
// O(1).
type Value struct {
	K Kind
	I int64 // int value, or 0/1 for bool
	S string
	L []Value
}

// Str makes a string value.
func Str(s string) Value { return Value{K: KStr, S: s} }

// Int makes an integer value.
func Int(i int64) Value { return Value{K: KInt, I: i} }

// Bool makes a boolean value.
func Bool(b bool) Value {
	if b {
		return Value{K: KBool, I: 1}
	}
	return Value{K: KBool}
}

// List makes a list value.
func List(l []Value) Value { return Value{K: KList, L: l} }

// Compare implements the total order on values.
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

// key returns a string that is equal for two values iff they are deeply equal.
func (v Value) key(b *strings.Builder) {
	switch v.K {
	case KBool:
		b.WriteByte('b')
		b.WriteByte(byte('0' + v.I))
	case KInt:
		b.WriteByte('i')
		b.WriteString(strconv.FormatInt(v.I, 10))
		b.WriteByte(';')
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

// Text renders a str, int or bool value as interpolation does.
func (v Value) Text() string {
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
