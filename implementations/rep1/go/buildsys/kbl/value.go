package kbl

import (
	"strconv"
	"strings"
)

// Kind is the type of a KBL value. The numeric order is the cross-type order
// of the total order on values.
type Kind uint8

// Value kinds, in total-order order.
const (
	KBool Kind = iota
	KInt
	KStr
	KList
)

// Value is a KBL value: a bool, int, str or list. Copying a Value is O(1):
// strings and lists are immutable and share their backing storage.
type Value struct {
	K Kind
	I int64 // int value; 0 or 1 for bool
	S string
	L []Value
}

// Constructors.
func vStr(s string) Value   { return Value{K: KStr, S: s} }
func vInt(i int64) Value    { return Value{K: KInt, I: i} }
func vList(l []Value) Value { return Value{K: KList, L: l} }
func vBool(b bool) Value {
	if b {
		return Value{K: KBool, I: 1}
	}
	return Value{K: KBool}
}

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

// compare implements the total order on values.
func compare(a, b Value) int {
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
		if c := compare(a.L[i], b.L[i]); c != 0 {
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

// equal is deep structural equality.
func equal(a, b Value) bool {
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
		if !equal(a.L[i], b.L[i]) {
			return false
		}
	}
	return true
}

// key returns a canonical string such that two values have the same key iff
// they are equal; it is used for hashing in uniq.
func (v Value) key(b *strings.Builder) {
	switch v.K {
	case KBool:
		b.WriteString("b")
		b.WriteString(strconv.FormatInt(v.I, 10))
	case KInt:
		b.WriteString("i")
		b.WriteString(strconv.FormatInt(v.I, 10))
	case KStr:
		b.WriteString("s")
		b.WriteString(strconv.Itoa(len(v.S)))
		b.WriteByte(':')
		b.WriteString(v.S)
	default:
		b.WriteString("l")
		b.WriteString(strconv.Itoa(len(v.L)))
		b.WriteByte('[')
		for _, e := range v.L {
			e.key(b)
		}
		b.WriteByte(']')
	}
}

// scope is a mutable mapping of names to values with a parent pointer.
type scope struct {
	vars   map[string]Value
	parent *scope
}

func newScope(parent *scope) *scope {
	return &scope{vars: make(map[string]Value), parent: parent}
}

func (s *scope) lookup(name string) (Value, bool) {
	for sc := s; sc != nil; sc = sc.parent {
		if v, ok := sc.vars[name]; ok {
			return v, true
		}
	}
	return Value{}, false
}

// assign replaces the binding in the innermost scope that has one.
func (s *scope) assign(name string, v Value) bool {
	for sc := s; sc != nil; sc = sc.parent {
		if _, ok := sc.vars[name]; ok {
			sc.vars[name] = v
			return true
		}
	}
	return false
}
