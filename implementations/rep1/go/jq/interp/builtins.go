package interp

import (
	"math"
	"slices"
	"unicode/utf8"

	"github.com/peter/jq/value"
)

type builtinID uint8

const (
	biEmpty builtinID = iota
	biError0
	biError1
	biNot
	biLength
	biKeys
	biHas
	biType
	biAdd
	biSelect
	biMap
	biSort
	biSortBy
	biGroupBy
	biUnique
	biReverse
	biMin
	biMax
	biToString
	biToNumber
)

type builtinKey struct {
	name  string
	arity int
}

var builtinTable = map[builtinKey]builtinID{
	{"empty", 0}:    biEmpty,
	{"error", 0}:    biError0,
	{"error", 1}:    biError1,
	{"not", 0}:      biNot,
	{"length", 0}:   biLength,
	{"keys", 0}:     biKeys,
	{"has", 1}:      biHas,
	{"type", 0}:     biType,
	{"add", 0}:      biAdd,
	{"select", 1}:   biSelect,
	{"map", 1}:      biMap,
	{"sort", 0}:     biSort,
	{"sort_by", 1}:  biSortBy,
	{"group_by", 1}: biGroupBy,
	{"unique", 0}:   biUnique,
	{"reverse", 0}:  biReverse,
	{"min", 0}:      biMin,
	{"max", 0}:      biMax,
	{"tostring", 0}: biToString,
	{"tonumber", 0}: biToNumber,
}

func lookupBuiltin(name string, arity int) (builtinID, bool) {
	id, ok := builtinTable[builtinKey{name, arity}]
	return id, ok
}

func evalCall(n *node, v value.Value, e *env, out sink) error {
	switch n.bi {
	case biEmpty:
		return nil
	case biError0:
		return &Error{Value: v}
	case biError1:
		return eval(n.args[0], v, e, func(x value.Value) error { return &Error{Value: x} })
	case biNot:
		return out(value.Bool(!v.Truthy()))
	case biType:
		return out(value.String(v.TypeName()))
	case biHas:
		return eval(n.args[0], v, e, func(k value.Value) error {
			r, err := has(v, k)
			if err != nil {
				return err
			}
			return out(r)
		})
	case biSelect:
		return eval(n.args[0], v, e, func(c value.Value) error {
			if c.Truthy() {
				return out(v)
			}
			return nil
		})
	case biMap:
		elems, err := iterValues(v)
		if err != nil {
			return err
		}
		res := make([]value.Value, 0, len(elems))
		for _, x := range elems {
			err := eval(n.args[0], x, e, func(y value.Value) error {
				res = append(res, y)
				return nil
			})
			if err != nil {
				return err
			}
		}
		return out(value.Array(res))
	case biSortBy, biGroupBy:
		return sortOrGroupBy(n, v, e, out)
	}
	r, err := callPure(n.bi, v)
	if err != nil {
		return err
	}
	return out(r)
}

// iterValues returns the values of an array or object, like .[].
func iterValues(v value.Value) ([]value.Value, error) {
	switch v.Kind() {
	case value.KindArray:
		return v.Elems(), nil
	case value.KindObject:
		es := v.Object().Entries()
		out := make([]value.Value, len(es))
		for i, en := range es {
			out[i] = en.Value
		}
		return out, nil
	}
	return nil, errorf("Cannot iterate over %s", describe(v))
}

// callPure evaluates the builtins that take no filter arguments and produce
// exactly one output.
func callPure(id builtinID, v value.Value) (value.Value, error) {
	switch id {
	case biLength:
		switch v.Kind() {
		case value.KindNull:
			return value.Number(0), nil
		case value.KindNumber:
			return value.Number(math.Abs(v.Float())), nil
		case value.KindString:
			return value.Number(float64(utf8.RuneCountInString(v.Str()))), nil
		case value.KindArray:
			return value.Number(float64(len(v.Elems()))), nil
		case value.KindObject:
			return value.Number(float64(v.Object().Len())), nil
		}
		return value.Null, errorf("%s has no length", describe(v))
	case biKeys:
		switch v.Kind() {
		case value.KindObject:
			keys := v.Object().SortedKeys()
			out := make([]value.Value, len(keys))
			for i, k := range keys {
				out[i] = value.String(k)
			}
			return value.Array(out), nil
		case value.KindArray:
			out := make([]value.Value, len(v.Elems()))
			for i := range out {
				out[i] = value.Number(float64(i))
			}
			return value.Array(out), nil
		}
		return value.Null, errorf("%s has no keys", describe(v))
	case biAdd:
		return addAll(v)
	case biSort:
		elems, err := needArray(v, "sorted")
		if err != nil {
			return value.Null, err
		}
		return value.Array(sortedCopy(elems)), nil
	case biUnique:
		elems, err := needArray(v, "sorted")
		if err != nil {
			return value.Null, err
		}
		sorted := sortedCopy(elems)
		out := sorted[:0]
		for i, x := range sorted {
			if i == 0 || !value.Equal(x, out[len(out)-1]) {
				out = append(out, x)
			}
		}
		return value.Array(out), nil
	case biReverse:
		if v.IsNull() {
			return value.Array([]value.Value{}), nil
		}
		if v.Kind() != value.KindArray {
			return value.Null, errorf("Cannot reverse %s", describe(v))
		}
		src := v.Elems()
		out := make([]value.Value, len(src))
		for i, x := range src {
			out[len(src)-1-i] = x
		}
		return value.Array(out), nil
	case biMin, biMax:
		elems, err := needArray(v, "iterated over")
		if err != nil {
			return value.Null, err
		}
		if len(elems) == 0 {
			return value.Null, nil
		}
		best := elems[0]
		for _, x := range elems[1:] {
			c := value.Compare(x, best)
			if (id == biMin && c < 0) || (id == biMax && c >= 0) {
				best = x
			}
		}
		return best, nil
	case biToString:
		if v.Kind() == value.KindString {
			return v, nil
		}
		return value.String(value.JSON(v)), nil
	case biToNumber:
		switch v.Kind() {
		case value.KindNumber:
			return v, nil
		case value.KindString:
			f, err := value.ParseNumber(v.Str())
			if err != nil {
				return value.Null, errorf("Cannot parse %s as a number", describe(v))
			}
			return value.Number(f), nil
		}
		return value.Null, errorf("%s cannot be parsed as a number", describe(v))
	}
	panic("interp: unhandled builtin")
}

func needArray(v value.Value, what string) ([]value.Value, error) {
	if v.Kind() != value.KindArray {
		return nil, errorf("%s cannot be %s, as it is not an array", describe(v), what)
	}
	return v.Elems(), nil
}

func has(v, k value.Value) (value.Value, error) {
	switch {
	case v.Kind() == value.KindObject && k.Kind() == value.KindString:
		return value.Bool(v.Object().Has(k.Str())), nil
	case v.Kind() == value.KindArray && k.Kind() == value.KindNumber:
		i := math.Trunc(k.Float())
		return value.Bool(i >= 0 && i < float64(len(v.Elems()))), nil
	case v.IsNull():
		return value.False, nil
	}
	return value.Null, errorf("Cannot check whether %s has a %s key", v.TypeName(), k.TypeName())
}

// stableOrder returns the permutation that sorts keys[i] ascending, ties
// broken by original position (so the sort is stable). It sorts indices with
// an O(n log n) comparison sort rather than moving elements.
func stableOrder(keys []value.Value) []int32 {
	idx := make([]int32, len(keys))
	for i := range idx {
		idx[i] = int32(i)
	}
	slices.SortFunc(idx, func(a, b int32) int {
		if c := value.Compare(keys[a], keys[b]); c != 0 {
			return c
		}
		return int(a) - int(b)
	})
	return idx
}

func sortedCopy(elems []value.Value) []value.Value {
	idx := stableOrder(elems)
	out := make([]value.Value, len(elems))
	for i, p := range idx {
		out[i] = elems[p]
	}
	return out
}

// sortOrGroupBy implements sort_by(f) and group_by(f): the key [f] is
// computed exactly once per element, then indices are sorted by key.
func sortOrGroupBy(n *node, v value.Value, e *env, out sink) error {
	elems, err := needArray(v, "sorted")
	if err != nil {
		return err
	}
	keys := make([]value.Value, len(elems))
	for i, x := range elems {
		ks := []value.Value{}
		err := eval(n.args[0], x, e, func(k value.Value) error {
			ks = append(ks, k)
			return nil
		})
		if err != nil {
			return err
		}
		keys[i] = value.Array(ks)
	}
	idx := stableOrder(keys)
	if n.bi == biSortBy {
		res := make([]value.Value, len(elems))
		for i, p := range idx {
			res[i] = elems[p]
		}
		return out(value.Array(res))
	}
	groups := []value.Value{}
	for lo := 0; lo < len(idx); {
		hi := lo + 1
		for hi < len(idx) && value.Equal(keys[idx[hi]], keys[idx[lo]]) {
			hi++
		}
		g := make([]value.Value, hi-lo)
		for i := lo; i < hi; i++ {
			g[i-lo] = elems[idx[i]]
		}
		groups = append(groups, value.Array(g))
		lo = hi
	}
	return out(value.Array(groups))
}

// addAll folds the elements of an array (or values of an object) with +,
// using one private builder so the whole fold is linear.
func addAll(v value.Value) (value.Value, error) {
	elems, err := iterValues(v)
	if err != nil {
		return value.Null, err
	}
	var (
		kind  = value.KindNull
		sum   float64
		str   []byte
		arr   []value.Value
		obj   *value.ObjectBuilder
		first value.Value
	)
	for _, x := range elems {
		if x.IsNull() {
			continue
		}
		if kind == value.KindNull {
			kind, first = x.Kind(), x
			switch kind {
			case value.KindNumber:
				sum = x.Float()
			case value.KindString:
				str = append(str, x.Str()...)
			case value.KindArray:
				arr = append(arr, x.Elems()...)
			case value.KindObject:
				obj = x.Object().Builder(0)
			default:
				// booleans cannot be added to anything but null
			}
			continue
		}
		if x.Kind() != kind || kind == value.KindFalse || kind == value.KindTrue {
			return value.Null, opError(accumulated(kind, sum, str, arr, obj, first), x, "added")
		}
		switch kind {
		case value.KindNumber:
			sum += x.Float()
		case value.KindString:
			str = append(str, x.Str()...)
		case value.KindArray:
			arr = append(arr, x.Elems()...)
		case value.KindObject:
			for _, en := range x.Object().Entries() {
				obj.Set(en.Key, en.Value)
			}
		}
	}
	switch kind {
	case value.KindNumber:
		return value.Number(sum), nil
	case value.KindString:
		return value.String(string(str)), nil
	case value.KindArray:
		if arr == nil {
			arr = []value.Value{}
		}
		return value.Array(arr), nil
	case value.KindObject:
		return obj.Build(), nil
	}
	return first, nil // null, or a lone boolean
}

// accumulated reconstructs the running sum for an error message.
func accumulated(kind value.Kind, sum float64, str []byte, arr []value.Value,
	obj *value.ObjectBuilder, first value.Value) value.Value {
	switch kind {
	case value.KindNumber:
		return value.Number(sum)
	case value.KindString:
		return value.String(string(str))
	case value.KindArray:
		return value.Array(arr)
	}
	return first
}
