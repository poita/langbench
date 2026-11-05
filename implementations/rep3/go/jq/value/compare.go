package value

import "strings"

// Compare orders two values with jq's total order: by type first
// (null < false < true < numbers < strings < arrays < objects), then within a
// type: numbers numerically, strings by code points, arrays element-wise,
// objects by their sorted key lists and then by the values in sorted key
// order. It returns -1, 0 or +1.
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
		x, y := a.Items(), b.Items()
		n := min(len(x), len(y))
		for i := 0; i < n; i++ {
			if c := Compare(x[i], y[i]); c != 0 {
				return c
			}
		}
		return cmpInt(len(x), len(y))
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

func compareObjects(x, y *Object) int {
	if x == y {
		return 0
	}
	px, py := x.sortedOrder(), y.sortedOrder()
	n := min(len(px), len(py))
	for i := 0; i < n; i++ {
		if c := strings.Compare(x.keys[px[i]], y.keys[py[i]]); c != 0 {
			return c
		}
	}
	if c := cmpInt(len(px), len(py)); c != 0 {
		return c
	}
	for i := range px {
		if c := Compare(x.vals[px[i]], y.vals[py[i]]); c != 0 {
			return c
		}
	}
	return 0
}

// Equal reports whether a and b compare equal under Compare.
func Equal(a, b Value) bool { return Compare(a, b) == 0 }
