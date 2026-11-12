package jq

import (
	"fmt"
	"slices"
	"unicode/utf8"
)

// simpleBuiltins are zero-argument builtins that map one value to one value.
var simpleBuiltins = map[string]func(Value) (Value, error){
	"not":      func(v Value) (Value, error) { return !Truthy(v), nil },
	"length":   biLength,
	"keys":     biKeys,
	"type":     func(v Value) (Value, error) { return TypeName(v), nil },
	"add":      biAdd,
	"sort":     biSort,
	"unique":   biUnique,
	"reverse":  biReverse,
	"min":      func(v Value) (Value, error) { return biMinMax(v, false) },
	"max":      func(v Value) (Value, error) { return biMinMax(v, true) },
	"tostring": biToString,
	"tonumber": biToNumber,
}

type funcNode struct {
	fn func(Value) (Value, error)
}

func (n *funcNode) eval(_ *env, in Value, out func(Value) error) error {
	v, err := n.fn(in)
	if err != nil {
		return err
	}
	return out(v)
}

type emptyNode struct{}

func (emptyNode) eval(*env, Value, func(Value) error) error { return nil }

type errorNode struct{ arg node } // arg may be nil

func (n *errorNode) eval(e *env, in Value, out func(Value) error) error {
	if n.arg == nil {
		return &Error{Value: in}
	}
	return n.arg.eval(e, in, func(v Value) error { return &Error{Value: v} })
}

type selectNode struct{ cond node }

func (n *selectNode) eval(e *env, in Value, out func(Value) error) error {
	return n.cond.eval(e, in, func(c Value) error {
		if Truthy(c) {
			return out(in)
		}
		return nil
	})
}

type mapNode struct{ f node }

func (n *mapNode) eval(e *env, in Value, out func(Value) error) error {
	var elems []Value
	switch x := in.(type) {
	case []Value:
		elems = x
	case *Object:
		elems = x.vals
	default:
		return errorf("cannot iterate over %s", TypeName(in))
	}
	res := make([]Value, 0, len(elems))
	for _, el := range elems {
		err := n.f.eval(e, el, func(v Value) error {
			res = append(res, v)
			return nil
		})
		if err != nil {
			return err
		}
	}
	return out(res)
}

type hasNode struct{ key node }

func (n *hasNode) eval(e *env, in Value, out func(Value) error) error {
	return n.key.eval(e, in, func(k Value) error {
		switch x := in.(type) {
		case nil:
			return out(false)
		case *Object:
			if ks, ok := k.(string); ok {
				_, found := x.Get(ks)
				return out(found)
			}
		case []Value:
			if kf, ok := k.(float64); ok {
				i := truncInt(kf)
				return out(i >= 0 && i < len(x))
			}
		}
		return errorf("cannot check whether %s has a %s key", TypeName(in), TypeName(k))
	})
}

// keyed pairs an element with its sort key.
type keyed struct {
	key Value
	val Value
}

// keyedElems evaluates [f] once per element of the array in.
func keyedElems(e *env, f node, in Value) ([]keyed, error) {
	arr, ok := in.([]Value)
	if !ok {
		return nil, errorf("cannot sort or group %s", TypeName(in))
	}
	ks := make([]keyed, len(arr))
	for i, el := range arr {
		key := []Value{}
		err := f.eval(e, el, func(v Value) error {
			key = append(key, v)
			return nil
		})
		if err != nil {
			return nil, err
		}
		ks[i] = keyed{key, el}
	}
	slices.SortStableFunc(ks, func(a, b keyed) int { return Compare(a.key, b.key) })
	return ks, nil
}

type sortByNode struct{ f node }

func (n *sortByNode) eval(e *env, in Value, out func(Value) error) error {
	ks, err := keyedElems(e, n.f, in)
	if err != nil {
		return err
	}
	res := make([]Value, len(ks))
	for i, k := range ks {
		res[i] = k.val
	}
	return out(res)
}

type groupByNode struct{ f node }

func (n *groupByNode) eval(e *env, in Value, out func(Value) error) error {
	ks, err := keyedElems(e, n.f, in)
	if err != nil {
		return err
	}
	res := []Value{}
	for i := 0; i < len(ks); {
		j := i + 1
		for j < len(ks) && Compare(ks[j].key, ks[i].key) == 0 {
			j++
		}
		g := make([]Value, j-i)
		for x := i; x < j; x++ {
			g[x-i] = ks[x].val
		}
		res = append(res, g)
		i = j
	}
	return out(res)
}

func newBuiltin(name string, args []node) (node, error) {
	bad := func() (node, error) {
		return nil, fmt.Errorf("%s/%d is not defined", name, len(args))
	}
	switch len(args) {
	case 0:
		switch name {
		case "empty":
			return emptyNode{}, nil
		case "error":
			return &errorNode{}, nil
		}
		if fn, ok := simpleBuiltins[name]; ok {
			return &funcNode{fn}, nil
		}
	case 1:
		switch name {
		case "error":
			return &errorNode{args[0]}, nil
		case "select":
			return &selectNode{args[0]}, nil
		case "map":
			return &mapNode{args[0]}, nil
		case "has":
			return &hasNode{args[0]}, nil
		case "sort_by":
			return &sortByNode{args[0]}, nil
		case "group_by":
			return &groupByNode{args[0]}, nil
		}
	}
	return bad()
}

func biLength(v Value) (Value, error) {
	switch x := v.(type) {
	case nil:
		return 0.0, nil
	case float64:
		if x < 0 {
			return -x, nil
		}
		return x, nil
	case string:
		return float64(utf8.RuneCountInString(x)), nil
	case []Value:
		return float64(len(x)), nil
	case *Object:
		return float64(x.Len()), nil
	}
	return nil, errorf("%s has no length", TypeName(v))
}

func biKeys(v Value) (Value, error) {
	switch x := v.(type) {
	case *Object:
		ks := x.SortedKeys()
		res := make([]Value, len(ks))
		for i, k := range ks {
			res[i] = k
		}
		return res, nil
	case []Value:
		res := make([]Value, len(x))
		for i := range x {
			res[i] = float64(i)
		}
		return res, nil
	}
	return nil, errorf("%s has no keys", TypeName(v))
}

// biAdd sums the elements of an array (or values of an object) in linear
// time, matching reduce .[] as $x (null; . + $x).
func biAdd(v Value) (Value, error) {
	var elems []Value
	switch x := v.(type) {
	case []Value:
		elems = x
	case *Object:
		elems = x.vals
	default:
		return nil, errorf("cannot iterate over %s", TypeName(v))
	}
	var acc Value
	i := 0
	for ; i < len(elems); i++ { // skip leading nulls
		if elems[i] != nil {
			acc = elems[i]
			i++
			break
		}
	}
	switch first := acc.(type) {
	case string:
		buf := []byte(first)
		for ; i < len(elems); i++ {
			switch s := elems[i].(type) {
			case nil:
			case string:
				buf = append(buf, s...)
			default:
				return nil, errorf("string and %s cannot be added", TypeName(s))
			}
		}
		return string(buf), nil
	case []Value:
		res := slices.Clone(first)
		for ; i < len(elems); i++ {
			switch s := elems[i].(type) {
			case nil:
			case []Value:
				res = append(res, s...)
			default:
				return nil, errorf("array and %s cannot be added", TypeName(s))
			}
		}
		return res, nil
	case *Object:
		var res *Object
		for ; i < len(elems); i++ {
			switch s := elems[i].(type) {
			case nil:
			case *Object:
				if res == nil {
					res = first.Copy(s.Len())
				}
				for j, k := range s.keys {
					res.Set(k, s.vals[j])
				}
			default:
				return nil, errorf("object and %s cannot be added", TypeName(s))
			}
		}
		if res == nil {
			return first, nil
		}
		return res, nil
	}
	for ; i < len(elems); i++ {
		var err error
		if acc, err = opAdd(acc, elems[i]); err != nil {
			return nil, err
		}
	}
	return acc, nil
}

func biSort(v Value) (Value, error) {
	arr, ok := v.([]Value)
	if !ok {
		return nil, errorf("%s cannot be sorted, as it is not an array", TypeName(v))
	}
	res := slices.Clone(arr)
	slices.SortStableFunc(res, Compare)
	return res, nil
}

func biUnique(v Value) (Value, error) {
	s, err := biSort(v)
	if err != nil {
		return nil, err
	}
	arr := s.([]Value)
	res := arr[:0]
	for i, e := range arr {
		if i == 0 || Compare(e, res[len(res)-1]) != 0 {
			res = append(res, e)
		}
	}
	return res, nil
}

func biReverse(v Value) (Value, error) {
	switch x := v.(type) {
	case nil:
		return []Value{}, nil
	case []Value:
		res := slices.Clone(x)
		slices.Reverse(res)
		return res, nil
	}
	return nil, errorf("cannot reverse %s", TypeName(v))
}

func biMinMax(v Value, wantMax bool) (Value, error) {
	arr, ok := v.([]Value)
	if !ok {
		return nil, errorf("%s cannot be iterated for min/max", TypeName(v))
	}
	if len(arr) == 0 {
		return nil, nil
	}
	best := arr[0]
	for _, e := range arr[1:] {
		c := Compare(e, best)
		if (wantMax && c >= 0) || (!wantMax && c < 0) {
			best = e
		}
	}
	return best, nil
}

func biToString(v Value) (Value, error) {
	if s, ok := v.(string); ok {
		return s, nil
	}
	return string(Marshal(v)), nil
}

func biToNumber(v Value) (Value, error) {
	switch x := v.(type) {
	case float64:
		return x, nil
	case string:
		if f, ok := parseNumberText(x); ok {
			return f, nil
		}
	}
	return nil, errorf("cannot convert %s to number", TypeName(v))
}
