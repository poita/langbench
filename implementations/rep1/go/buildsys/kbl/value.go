package kbl

import (
	"strconv"
	"strings"
)

func itoa(n int) string { return strconv.Itoa(n) }

// Kind is the dynamic type of a Value.
type Kind uint8

// Value kinds, in the order of the total order across types.
const (
	KBool Kind = iota
	KInt
	KStr
	KList
)

// TypeName returns the KBL type token ("bool", "int", "str" or "list").
func (k Kind) TypeName() string {
	return [...]string{"bool", "int", "str", "list"}[k]
}

// Value is a KBL value. Strings and lists are immutable and shared by handle,
// so copying a Value is O(1).
type Value struct {
	K Kind
	I int64 // int value, or 0/1 for bool
	S string
	L []Value
}

// Constructors.
func vStr(s string) Value   { return Value{K: KStr, S: s} }
func vInt(n int64) Value    { return Value{K: KInt, I: n} }
func vList(l []Value) Value { return Value{K: KList, L: l} }
func vBool(b bool) Value {
	if b {
		return Value{K: KBool, I: 1}
	}
	return Value{K: KBool}
}

// Str, Int, Bool and List are exported constructors for embedding the
// interpreter's values in tests and tools.
func Str(s string) Value   { return vStr(s) }
func Int(n int64) Value    { return vInt(n) }
func Bool(b bool) Value    { return vBool(b) }
func List(l []Value) Value { return vList(l) }

// Compare orders two values by the KBL total order: bool < int < str < list;
// lists compare element-wise. It returns -1, 0 or +1.
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
	n := len(a.L)
	if len(b.L) < n {
		n = len(b.L)
	}
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

// Equal is deep structural equality; values of different types are never equal.
func Equal(a, b Value) bool { return Compare(a, b) == 0 }

// appendKey appends an injective encoding of v, usable as a map key.
func appendKey(dst []byte, v Value) []byte {
	switch v.K {
	case KBool, KInt:
		dst = append(dst, byte('b'+v.K))
		dst = strconv.AppendInt(dst, v.I, 10)
		dst = append(dst, ';')
	case KStr:
		dst = append(dst, 's')
		dst = strconv.AppendInt(dst, int64(len(v.S)), 10)
		dst = append(dst, ':')
		dst = append(dst, v.S...)
	default:
		dst = append(dst, 'l')
		dst = strconv.AppendInt(dst, int64(len(v.L)), 10)
		dst = append(dst, '[')
		for _, e := range v.L {
			dst = appendKey(dst, e)
		}
		dst = append(dst, ']')
	}
	return dst
}

// scope is a mutable name->value mapping with a parent link.
type scope struct {
	vars   map[string]Value
	parent *scope
}

func newScope(parent *scope) *scope {
	return &scope{vars: make(map[string]Value, 4), parent: parent}
}

func (s *scope) lookup(name string) (Value, bool) {
	for ; s != nil; s = s.parent {
		if v, ok := s.vars[name]; ok {
			return v, true
		}
	}
	return Value{}, false
}
