package interp

import (
	"slices"

	"example.com/jq/syntax"
	"example.com/jq/value"
)

// keyed is a sort key together with the original position of its element;
// the position makes the (unstable) pdqsort behave as a stable sort.
type keyed struct {
	key value.Value
	idx int32
}

func sortKeyed(ps []keyed) {
	slices.SortFunc(ps, func(a, b keyed) int {
		if c := value.Compare(a.key, b.key); c != 0 {
			return c
		}
		return int(a.idx - b.idx)
	})
}

// keyedElems evaluates [f] once for every element of the array in.
func keyedElems(f syntax.Node, in value.Value, ev *env) ([]keyed, error) {
	if in.Kind() != value.KindArray {
		return nil, value.NewError(in.TypeName() + " cannot be sorted, as it is not an array")
	}
	es := in.Elems()
	ps := make([]keyed, len(es))
	for i, e := range es {
		var ks []value.Value
		if err := eval(f, e, ev, func(v value.Value) error {
			ks = append(ks, v)
			return nil
		}); err != nil {
			return nil, err
		}
		ps[i] = keyed{value.Array(ks), int32(i)}
	}
	return ps, nil
}
