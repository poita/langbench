package jq

// typeRank gives the position of v's type in jq's total order:
// null < false < true < numbers < strings < arrays < objects.
func typeRank(v Value) int {
	switch x := v.(type) {
	case nil:
		return 0
	case bool:
		if x {
			return 2
		}
		return 1
	case float64:
		return 3
	case string:
		return 4
	case []Value:
		return 5
	case *Object:
		return 6
	}
	return 7
}

// Compare orders two values by jq's total order and returns -1, 0 or 1.
func Compare(a, b Value) int {
	ra, rb := typeRank(a), typeRank(b)
	if ra != rb {
		if ra < rb {
			return -1
		}
		return 1
	}
	switch x := a.(type) {
	case float64:
		y := b.(float64)
		switch {
		case x < y:
			return -1
		case x > y:
			return 1
		}
		return 0
	case string:
		y := b.(string)
		switch {
		case x < y:
			return -1
		case x > y:
			return 1
		}
		return 0
	case []Value:
		y := b.([]Value)
		n := min(len(x), len(y))
		for i := 0; i < n; i++ {
			if c := Compare(x[i], y[i]); c != 0 {
				return c
			}
		}
		switch {
		case len(x) < len(y):
			return -1
		case len(x) > len(y):
			return 1
		}
		return 0
	case *Object:
		return compareObjects(x, b.(*Object))
	}
	return 0
}

func compareObjects(x, y *Object) int {
	ox, oy := x.sortedOrder(), y.sortedOrder()
	n := min(len(ox), len(oy))
	for i := 0; i < n; i++ {
		kx, ky := x.keys[ox[i]], y.keys[oy[i]]
		if kx != ky {
			if kx < ky {
				return -1
			}
			return 1
		}
	}
	if len(ox) != len(oy) {
		if len(ox) < len(oy) {
			return -1
		}
		return 1
	}
	for i := range ox {
		if c := Compare(x.vals[ox[i]], y.vals[oy[i]]); c != 0 {
			return c
		}
	}
	return 0
}

// Equal reports whether a and b compare equal under Compare. Object key order
// is irrelevant.
func Equal(a, b Value) bool { return Compare(a, b) == 0 }
