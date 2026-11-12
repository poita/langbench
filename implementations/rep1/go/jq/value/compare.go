package value

import "strings"

// Compare orders two values by jq's total order and returns -1, 0 or +1.
//
// Types order as null < false < true < numbers < strings < arrays < objects.
// Numbers compare numerically, strings by code point, arrays element by
// element (a proper prefix sorts first), and objects first by their sorted key
// lists and then by the values in sorted key order.
func Compare(a, b Value) int {
	ka, kb := KindOf(a), KindOf(b)
	if ka != kb {
		if ka < kb {
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
		return strings.Compare(x, b.(string))
	case []Value:
		y := b.([]Value)
		n := min(len(x), len(y))
		for i := 0; i < n; i++ {
			if c := Compare(x[i], y[i]); c != 0 {
				return c
			}
		}
		return cmpInt(len(x), len(y))
	case *Object:
		return compareObjects(x, b.(*Object))
	}
	return 0 // null, false, true: equal kinds are equal values
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
	ox, oy := x.order(), y.order()
	n := min(len(ox), len(oy))
	for i := 0; i < n; i++ {
		if c := strings.Compare(x.keys[ox[i]], y.keys[oy[i]]); c != 0 {
			return c
		}
	}
	if c := cmpInt(len(ox), len(oy)); c != 0 {
		return c
	}
	for i := range ox {
		if c := Compare(x.vals[ox[i]], y.vals[oy[i]]); c != 0 {
			return c
		}
	}
	return 0
}

// Equal reports whether a and b compare equal under Compare.
func Equal(a, b Value) bool { return Compare(a, b) == 0 }

// SortedOrder returns the permutation that sorts keys in ascending order using
// a stable merge sort: the result lists indexes into keys so that equal keys
// keep their original relative order. It performs O(n log n) comparisons.
func SortedOrder(keys []Value) []int {
	n := len(keys)
	perm := make([]int, n)
	for i := range perm {
		perm[i] = i
	}
	if n < 2 {
		return perm
	}
	buf := make([]int, n)
	mergeSort(keys, perm, buf)
	return perm
}

const insertionMax = 8

func mergeSort(keys []Value, perm, buf []int) {
	n := len(perm)
	if n <= insertionMax {
		for i := 1; i < n; i++ {
			p := perm[i]
			j := i
			for j > 0 && Compare(keys[perm[j-1]], keys[p]) > 0 {
				perm[j] = perm[j-1]
				j--
			}
			perm[j] = p
		}
		return
	}
	mid := n / 2
	mergeSort(keys, perm[:mid], buf[:mid])
	mergeSort(keys, perm[mid:], buf[mid:])
	if Compare(keys[perm[mid-1]], keys[perm[mid]]) <= 0 {
		return
	}
	copy(buf[:mid], perm[:mid])
	i, j, k := 0, mid, 0
	for i < mid && j < n {
		if Compare(keys[perm[j]], keys[buf[i]]) < 0 {
			perm[k] = perm[j]
			j++
		} else {
			perm[k] = buf[i]
			i++
		}
		k++
	}
	for i < mid {
		perm[k] = buf[i]
		i++
		k++
	}
}

// Sort returns a new slice with the elements of vs in ascending order
// (stable).
func Sort(vs []Value) []Value {
	perm := SortedOrder(vs)
	out := make([]Value, len(vs))
	for i, p := range perm {
		out[i] = vs[p]
	}
	return out
}
