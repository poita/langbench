package value

import "strings"

// Compare is the jq total order over values: it returns a negative number if
// a sorts before b, zero if they are equal and a positive number otherwise.
// Types order as null < false < true < number < string < array < object.
// Strings compare by UTF-8 bytes, arrays lexicographically, and objects first
// by their sorted key lists and then by the values in sorted key order.
// Compare allocates nothing.
func Compare(a, b Value) int {
	if a.kind != b.kind {
		if a.kind < b.kind {
			return -1
		}
		return 1
	}
	switch a.kind {
	case KindNumber:
		switch {
		case a.num < b.num:
			return -1
		case a.num > b.num:
			return 1
		}
		return 0
	case KindString:
		return strings.Compare(a.Str(), b.Str())
	case KindArray:
		ea, eb := a.Elems(), b.Elems()
		n := min(len(ea), len(eb))
		for i := 0; i < n; i++ {
			if c := Compare(ea[i], eb[i]); c != 0 {
				return c
			}
		}
		return len(ea) - len(eb)
	case KindObject:
		return compareObjects(a.Object(), b.Object())
	}
	return 0
}

func compareObjects(a, b *Object) int {
	if a == b {
		return 0
	}
	oa, ob := a.SortedOrder(), b.SortedOrder()
	n := min(len(oa), len(ob))
	for i := 0; i < n; i++ {
		if c := strings.Compare(a.entries[oa[i]].Key, b.entries[ob[i]].Key); c != 0 {
			return c
		}
	}
	if len(oa) != len(ob) {
		return len(oa) - len(ob)
	}
	for i := range oa {
		if c := Compare(a.entries[oa[i]].Value, b.entries[ob[i]].Value); c != 0 {
			return c
		}
	}
	return 0
}

// Equal reports whether a and b compare equal under Compare.
func Equal(a, b Value) bool { return Compare(a, b) == 0 }
