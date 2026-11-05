package value

import "strings"

// Compare orders two values with jq's total order and returns -1, 0 or 1.
//
// Values of different kinds order as null < false < true < numbers < strings
// < arrays < objects. Numbers compare numerically, strings by bytes, arrays
// element by element (a proper prefix sorts first), and objects first by their
// sorted key lists and then by the values in sorted key order.
func Compare(a, b Value) int {
	if a.k != b.k {
		if a.k < b.k {
			return -1
		}
		return 1
	}
	switch a.k {
	case KindNumber:
		x, y := a.Float(), b.Float()
		switch {
		case x < y:
			return -1
		case x > y:
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
		return cmpInt(len(ea), len(eb))
	case KindObject:
		return compareObjects(a.Obj(), b.Obj())
	}
	return 0
}

func cmpInt(a, b int) int {
	switch {
	case a < b:
		return -1
	case a > b:
		return 1
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
	if c := cmpInt(len(oa), len(ob)); c != 0 {
		return c
	}
	for i := range oa {
		if c := Compare(a.entries[oa[i]].Val, b.entries[ob[i]].Val); c != 0 {
			return c
		}
	}
	return 0
}

// Equal reports whether a and b compare equal under Compare.
func Equal(a, b Value) bool { return Compare(a, b) == 0 }
