package jq

import (
	"slices"
	"strings"

	"jq/value"
)

type builtinID uint8

const (
	bEmpty builtinID = iota
	bError0
	bError1
	bNot
	bLength
	bKeys
	bHas
	bType
	bAdd
	bSelect
	bMap
	bSort
	bSortBy
	bGroupBy
	bUnique
	bReverse
	bMin
	bMax
	bToString
	bToNumber
)

type builtinKey struct {
	name  string
	arity int
}

var builtinTable = map[builtinKey]builtinID{
	{"empty", 0}:    bEmpty,
	{"error", 0}:    bError0,
	{"error", 1}:    bError1,
	{"not", 0}:      bNot,
	{"length", 0}:   bLength,
	{"keys", 0}:     bKeys,
	{"has", 1}:      bHas,
	{"type", 0}:     bType,
	{"add", 0}:      bAdd,
	{"select", 1}:   bSelect,
	{"map", 1}:      bMap,
	{"sort", 0}:     bSort,
	{"sort_by", 1}:  bSortBy,
	{"group_by", 1}: bGroupBy,
	{"unique", 0}:   bUnique,
	{"reverse", 0}:  bReverse,
	{"min", 0}:      bMin,
	{"max", 0}:      bMax,
	{"tostring", 0}: bToString,
	{"tonumber", 0}: bToNumber,
}

func lookupBuiltin(name string, arity int) (builtinID, bool) {
	id, ok := builtinTable[builtinKey{name, arity}]
	return id, ok
}

// builtinSingle reports whether a call node always yields exactly one output
// (or an error).
func builtinSingle(n *node) bool {
	switch n.fn {
	case bNot, bLength, bKeys, bType, bAdd, bSort, bSortBy, bGroupBy, bUnique,
		bReverse, bMin, bMax, bToString, bToNumber, bMap:
		return true
	case bHas:
		return n.args[0].single
	}
	return false
}

func callBuiltin(n *node, in value.Value, e *env, out sink) error {
	switch n.fn {
	case bEmpty:
		return nil
	case bError0:
		return &Error{Value: in}
	case bError1:
		var raised error
		stop := errorf("stop")
		err := eval(n.args[0], in, e, func(v value.Value) error {
			raised = &Error{Value: v}
			return stop
		})
		if raised != nil {
			return raised
		}
		return err
	case bSelect:
		f := n.args[0]
		if f.single {
			c, err := one(f, in, e)
			if err != nil {
				return err
			}
			if c.Truthy() {
				return out(in)
			}
			return nil
		}
		return eval(f, in, e, func(c value.Value) error {
			if c.Truthy() {
				return out(in)
			}
			return nil
		})
	case bHas:
		return eval(n.args[0], in, e, func(k value.Value) error {
			r, err := has(in, k)
			if err != nil {
				return err
			}
			return out(r)
		})
	}
	v, err := callBuiltinOne(n, in, e)
	if err != nil {
		return err
	}
	return out(v)
}

// callBuiltinOne runs the single-output builtins.
func callBuiltinOne(n *node, in value.Value, e *env) (value.Value, error) {
	switch n.fn {
	case bHas:
		k, err := one(n.args[0], in, e)
		if err != nil {
			return value.Null, err
		}
		return has(in, k)
	case bNot:
		return value.Bool(!in.Truthy()), nil
	case bLength:
		switch in.Kind() {
		case value.KindNull:
			return value.Number(0), nil
		case value.KindNumber:
			f := in.Float()
			if f < 0 {
				f = -f
			}
			return value.Number(f), nil
		case value.KindString:
			return value.Number(float64(runeCount(in.Str()))), nil
		case value.KindArray:
			return value.Number(float64(len(in.Items()))), nil
		case value.KindObject:
			return value.Number(float64(in.Obj().Len())), nil
		}
		return value.Null, errorf("boolean (%s) has no length", short(in))
	case bKeys:
		switch in.Kind() {
		case value.KindObject:
			ks := in.Obj().SortedKeys()
			out := make([]value.Value, len(ks))
			for i, k := range ks {
				out[i] = value.String(k)
			}
			return value.Array(out), nil
		case value.KindArray:
			out := make([]value.Value, len(in.Items()))
			for i := range out {
				out[i] = value.Number(float64(i))
			}
			return value.Array(out), nil
		}
		return value.Null, errorf("%s (%s) has no keys", in.TypeName(), short(in))
	case bType:
		return value.String(in.TypeName()), nil
	case bAdd:
		return addAll(in)
	case bMap:
		if !in.IsArray() && !in.IsObject() {
			return value.Null, errorf("Cannot iterate over %s", in.TypeName())
		}
		items := make([]value.Value, 0, 8)
		f := n.args[0]
		if in.IsArray() {
			src := in.Items()
			items = make([]value.Value, 0, len(src))
		}
		collect := func(v value.Value) error {
			items = append(items, v)
			return nil
		}
		_, err := iterate(in, func(el value.Value) error {
			if f.single {
				r, err := one(f, el, e)
				if err != nil {
					return err
				}
				items = append(items, r)
				return nil
			}
			return eval(f, el, e, collect)
		})
		if err != nil {
			return value.Null, err
		}
		return value.Array(items), nil
	case bSort:
		if !in.IsArray() {
			return value.Null, errorf("%s (%s) cannot be sorted, as it is not an array", in.TypeName(), short(in))
		}
		items := in.Items()
		order := sortedOrder(items)
		out := make([]value.Value, len(items))
		for i, j := range order {
			out[i] = items[j]
		}
		return value.Array(out), nil
	case bSortBy, bGroupBy:
		if !in.IsArray() {
			return value.Null, errorf("Cannot index %s with number", in.TypeName())
		}
		items := in.Items()
		keys, err := computeKeys(n.args[0], items, e)
		if err != nil {
			return value.Null, err
		}
		order := sortedOrder(keys)
		if n.fn == bSortBy {
			out := make([]value.Value, len(items))
			for i, j := range order {
				out[i] = items[j]
			}
			return value.Array(out), nil
		}
		groups := make([]value.Value, 0, 8)
		start := 0
		for i := 1; i <= len(order); i++ {
			if i == len(order) || value.Compare(keys[order[i]], keys[order[i-1]]) != 0 {
				if i > start {
					g := make([]value.Value, i-start)
					for j := start; j < i; j++ {
						g[j-start] = items[order[j]]
					}
					groups = append(groups, value.Array(g))
				}
				start = i
			}
		}
		return value.Array(groups), nil
	case bUnique:
		if !in.IsArray() {
			return value.Null, errorf("%s (%s) cannot be sorted, as it is not an array", in.TypeName(), short(in))
		}
		items := in.Items()
		order := sortedOrder(items)
		out := make([]value.Value, 0, len(items))
		for i, j := range order {
			if i == 0 || value.Compare(items[j], out[len(out)-1]) != 0 {
				out = append(out, items[j])
			}
		}
		return value.Array(out), nil
	case bReverse:
		switch in.Kind() {
		case value.KindNull:
			return value.Array([]value.Value{}), nil
		case value.KindArray:
			src := in.Items()
			out := make([]value.Value, len(src))
			for i, v := range src {
				out[len(src)-1-i] = v
			}
			return value.Array(out), nil
		}
		return value.Null, errorf("Cannot reverse %s", in.TypeName())
	case bMin, bMax:
		if !in.IsArray() {
			return value.Null, errorf("%s (%s) cannot be iterated over", in.TypeName(), short(in))
		}
		items := in.Items()
		if len(items) == 0 {
			return value.Null, nil
		}
		best := items[0]
		for _, v := range items[1:] {
			c := value.Compare(v, best)
			if (n.fn == bMin && c < 0) || (n.fn == bMax && c >= 0) {
				best = v
			}
		}
		return best, nil
	case bToString:
		if in.IsString() {
			return in, nil
		}
		return value.String(value.JSON(in)), nil
	case bToNumber:
		switch in.Kind() {
		case value.KindNumber:
			return in, nil
		case value.KindString:
			if f, ok := value.ParseNumber(in.Str()); ok {
				return value.Number(f), nil
			}
		}
		return value.Null, errorf("Cannot parse %s as number", short(in))
	}
	return value.Null, errorf("internal error: builtin %d", n.fn)
}

func runeCount(s string) int {
	n := 0
	for i := 0; i < len(s); i++ {
		if s[i]&0xC0 != 0x80 {
			n++
		}
	}
	return n
}

func has(t, k value.Value) (value.Value, error) {
	switch {
	case t.IsObject() && k.IsString():
		return value.Bool(t.Obj().Has(k.Str())), nil
	case t.IsArray() && k.IsNumber():
		f := k.Float()
		return value.Bool(f > -1 && f < float64(len(t.Items()))), nil
	case t.IsNull():
		return value.False, nil
	}
	return value.Null, errorf("Cannot check whether %s has a %s key", t.TypeName(), k.TypeName())
}

// sortedOrder returns the indices of items in stable ascending order.
func sortedOrder(items []value.Value) []int32 {
	order := make([]int32, len(items))
	for i := range order {
		order[i] = int32(i)
	}
	slices.SortFunc(order, func(a, b int32) int {
		if c := value.Compare(items[a], items[b]); c != 0 {
			return c
		}
		return int(a - b)
	})
	return order
}

// computeKeys evaluates the key [f] once for every element.
func computeKeys(f *node, items []value.Value, e *env) ([]value.Value, error) {
	keys := make([]value.Value, len(items))
	for i, it := range items {
		if f.single {
			// [f] compares exactly like its single output.
			k, err := one(f, it, e)
			if err != nil {
				return nil, err
			}
			keys[i] = k
			continue
		}
		var ks []value.Value
		err := eval(f, it, e, func(v value.Value) error {
			ks = append(ks, v)
			return nil
		})
		if err != nil {
			return nil, err
		}
		keys[i] = value.Array(ks)
	}
	return keys, nil
}

// addAll implements add: a left fold of + starting from null, done with
// private builders so it is linear in the total size.
func addAll(in value.Value) (value.Value, error) {
	if !in.IsArray() && !in.IsObject() {
		return value.Null, errorf("Cannot iterate over %s", in.TypeName())
	}
	var (
		acc    value.Value // current value when mode == modeOther
		mode   int
		sum    float64
		sb     strings.Builder
		arr    []value.Value
		obj    *value.Object
		failed error
	)
	const (
		modeNull = iota
		modeNum
		modeStr
		modeArr
		modeObj
		modeOther
	)
	step := func(x value.Value) error {
		if x.IsNull() {
			return nil
		}
		switch mode {
		case modeNull:
			switch x.Kind() {
			case value.KindNumber:
				mode, sum = modeNum, x.Float()
			case value.KindString:
				mode = modeStr
				sb.WriteString(x.Str())
			case value.KindArray:
				mode = modeArr
				arr = append(arr, x.Items()...)
			case value.KindObject:
				mode = modeObj
				obj = x.Obj().Copy(0)
			default:
				mode, acc = modeOther, x
			}
			return nil
		case modeNum:
			if x.IsNumber() {
				sum += x.Float()
				return nil
			}
			return errorf("number (%s) and %s (%s) cannot be added", short(value.Number(sum)), x.TypeName(), short(x))
		case modeStr:
			if x.IsString() {
				sb.WriteString(x.Str())
				return nil
			}
			return errorf("string and %s (%s) cannot be added", x.TypeName(), short(x))
		case modeArr:
			if x.IsArray() {
				arr = append(arr, x.Items()...)
				return nil
			}
			return errorf("array and %s (%s) cannot be added", x.TypeName(), short(x))
		case modeObj:
			if x.IsObject() {
				xo := x.Obj()
				for i, n := 0, xo.Len(); i < n; i++ {
					obj.Set(xo.KeyAt(i), xo.ValueAt(i))
				}
				return nil
			}
			return errorf("object and %s (%s) cannot be added", x.TypeName(), short(x))
		}
		_, err := addValues(acc, x)
		return err
	}
	_, failed = iterate(in, step)
	if failed != nil {
		return value.Null, failed
	}
	switch mode {
	case modeNum:
		return value.Number(sum), nil
	case modeStr:
		return value.String(sb.String()), nil
	case modeArr:
		if arr == nil {
			arr = []value.Value{}
		}
		return value.Array(arr), nil
	case modeObj:
		return value.ObjectValue(obj), nil
	case modeOther:
		return acc, nil
	}
	return value.Null, nil
}
