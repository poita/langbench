package interp

import (
	"math"
	"strconv"
	"strings"
	"unicode/utf8"

	"example.com/jq/jsonio"
	"example.com/jq/syntax"
	"example.com/jq/value"
)

func evalCall(n *syntax.Call, in value.Value, ev *env, out Sink) error {
	switch n.Name {
	case "empty":
		return nil
	case "error":
		if len(n.Args) == 0 {
			return &value.Error{Msg: "error: " + jsonio.Marshal(in), Payload: in}
		}
		var payload value.Value
		got := false
		err := eval(n.Args[0], in, ev, func(v value.Value) error {
			payload, got = v, true
			return errStop
		})
		if err != nil && err != errStop {
			return err
		}
		if !got {
			return nil
		}
		return &value.Error{Msg: "error: " + jsonio.Marshal(payload), Payload: payload}
	case "not":
		return out(value.Bool(!in.Truthy()))
	case "length":
		r, err := length(in)
		if err != nil {
			return err
		}
		return out(r)
	case "keys":
		r, err := keys(in)
		if err != nil {
			return err
		}
		return out(r)
	case "has":
		return eval(n.Args[0], in, ev, func(k value.Value) error {
			r, err := has(in, k)
			if err != nil {
				return err
			}
			return out(r)
		})
	case "type":
		return out(value.String(in.TypeName()))
	case "add":
		r, err := addAll(in)
		if err != nil {
			return err
		}
		return out(r)
	case "select":
		return eval(n.Args[0], in, ev, func(c value.Value) error {
			if c.Truthy() {
				return out(in)
			}
			return nil
		})
	case "map":
		var res []value.Value
		err := value.Iterate(in, func(x value.Value) error {
			return eval(n.Args[0], x, ev, func(v value.Value) error {
				res = append(res, v)
				return nil
			})
		})
		if err != nil {
			return err
		}
		if res == nil {
			res = []value.Value{}
		}
		return out(value.Array(res))
	case "sort":
		if in.Kind() != value.KindArray {
			return value.NewError(in.TypeName() + " cannot be sorted, as it is not an array")
		}
		es := in.Elems()
		ps := make([]keyed, len(es))
		for i, e := range es {
			ps[i] = keyed{e, int32(i)}
		}
		sortKeyed(ps)
		res := make([]value.Value, len(ps))
		for i, p := range ps {
			res[i] = p.key
		}
		return out(value.Array(res))
	case "sort_by":
		ps, err := keyedElems(n.Args[0], in, ev)
		if err != nil {
			return err
		}
		sortKeyed(ps)
		es := in.Elems()
		res := make([]value.Value, len(ps))
		for i, p := range ps {
			res[i] = es[p.idx]
		}
		return out(value.Array(res))
	case "group_by":
		ps, err := keyedElems(n.Args[0], in, ev)
		if err != nil {
			return err
		}
		sortKeyed(ps)
		es := in.Elems()
		groups := []value.Value{}
		for i := 0; i < len(ps); {
			j := i + 1
			for j < len(ps) && value.Compare(ps[j].key, ps[i].key) == 0 {
				j++
			}
			g := make([]value.Value, j-i)
			for k := i; k < j; k++ {
				g[k-i] = es[ps[k].idx]
			}
			groups = append(groups, value.Array(g))
			i = j
		}
		return out(value.Array(groups))
	case "unique":
		if in.Kind() != value.KindArray {
			return value.NewError(in.TypeName() + " cannot be sorted, as it is not an array")
		}
		es := in.Elems()
		ps := make([]keyed, len(es))
		for i, e := range es {
			ps[i] = keyed{e, int32(i)}
		}
		sortKeyed(ps)
		res := make([]value.Value, 0, len(ps))
		for i, p := range ps {
			if i == 0 || value.Compare(p.key, ps[i-1].key) != 0 {
				res = append(res, p.key)
			}
		}
		return out(value.Array(res))
	case "reverse":
		switch in.Kind() {
		case value.KindNull:
			return out(value.Array([]value.Value{}))
		case value.KindArray:
			es := in.Elems()
			res := make([]value.Value, len(es))
			for i, e := range es {
				res[len(es)-1-i] = e
			}
			return out(value.Array(res))
		}
		return value.NewError("cannot reverse " + in.TypeName())
	case "min", "max":
		if in.Kind() != value.KindArray {
			return value.NewError(in.TypeName() + " cannot be iterated over")
		}
		es := in.Elems()
		if len(es) == 0 {
			return out(value.Null)
		}
		best := es[0]
		isMax := n.Name == "max"
		for _, e := range es[1:] {
			c := value.Compare(e, best)
			if (isMax && c >= 0) || (!isMax && c < 0) {
				best = e
			}
		}
		return out(best)
	case "tostring":
		if in.Kind() == value.KindString {
			return out(in)
		}
		return out(value.String(jsonio.Marshal(in)))
	case "tonumber":
		switch in.Kind() {
		case value.KindNumber:
			return out(in)
		case value.KindString:
			s := in.Str()
			if !isJSONNumber(s) {
				return value.NewError("cannot parse '" + s + "' as a number")
			}
			f, err := strconv.ParseFloat(s, 64)
			if err != nil && math.IsNaN(f) {
				return value.NewError("cannot parse '" + s + "' as a number")
			}
			return out(value.Number(f))
		}
		return value.NewError(in.TypeName() + " cannot be parsed as a number")
	}
	return value.NewError("unknown builtin " + n.Name)
}

func length(v value.Value) (value.Value, error) {
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
		return value.Number(float64(v.Obj().Len())), nil
	}
	return value.Null, value.NewError("boolean has no length")
}

func keys(v value.Value) (value.Value, error) {
	switch v.Kind() {
	case value.KindObject:
		ks := v.Obj().SortedKeys()
		res := make([]value.Value, len(ks))
		for i, k := range ks {
			res[i] = value.String(k)
		}
		return value.Array(res), nil
	case value.KindArray:
		res := make([]value.Value, len(v.Elems()))
		for i := range res {
			res[i] = value.Number(float64(i))
		}
		return value.Array(res), nil
	}
	return value.Null, value.NewError(v.TypeName() + " has no keys")
}

func has(t, k value.Value) (value.Value, error) {
	switch {
	case t.Kind() == value.KindObject && k.Kind() == value.KindString:
		return value.Bool(t.Obj().Has(k.Str())), nil
	case t.Kind() == value.KindArray && k.Kind() == value.KindNumber:
		f := math.Trunc(k.Float())
		return value.Bool(f >= 0 && f < float64(len(t.Elems()))), nil
	case t.Kind() == value.KindNull:
		return value.False, nil
	}
	return value.Null, value.NewError("cannot check whether " + t.TypeName() + " has a " + k.TypeName() + " key")
}

// addAll folds the elements of an array (or values of an object) with +,
// starting from null, using one growing builder.
func addAll(in value.Value) (value.Value, error) {
	var (
		mode  value.Kind // kind of the accumulated value; KindNull = nothing yet
		num   float64
		sb    strings.Builder
		arr   []value.Value
		obj   *value.Object
		other value.Value // accumulated boolean
	)
	rep := func() value.Value {
		switch mode {
		case value.KindNumber:
			return value.Number(num)
		case value.KindString:
			return value.String("")
		case value.KindArray:
			return value.Array(nil)
		case value.KindObject:
			return value.ObjectValue(value.NewObject(0))
		}
		return other
	}
	err := value.Iterate(in, func(x value.Value) error {
		if x.IsNull() {
			return nil
		}
		if mode == value.KindNull {
			mode = x.Kind()
			switch mode {
			case value.KindNumber:
				num = x.Float()
			case value.KindString:
				sb.WriteString(x.Str())
			case value.KindArray:
				arr = append(arr, x.Elems()...)
			case value.KindObject:
				obj = x.Obj().Clone(0)
			default:
				other = x
			}
			return nil
		}
		if x.Kind() != mode {
			_, err := value.Add(rep(), x)
			return err
		}
		switch mode {
		case value.KindNumber:
			num += x.Float()
		case value.KindString:
			sb.WriteString(x.Str())
		case value.KindArray:
			arr = append(arr, x.Elems()...)
		case value.KindObject:
			for _, e := range x.Obj().Entries() {
				obj.Set(e.Key, e.Val)
			}
		default:
			_, err := value.Add(other, x)
			return err
		}
		return nil
	})
	if err != nil {
		return value.Null, err
	}
	switch mode {
	case value.KindNumber:
		return value.Number(num), nil
	case value.KindString:
		return value.String(sb.String()), nil
	case value.KindArray:
		if arr == nil {
			arr = []value.Value{}
		}
		return value.Array(arr), nil
	case value.KindObject:
		return value.ObjectValue(obj), nil
	case value.KindNull:
		return value.Null, nil
	}
	return other, nil
}

// isJSONNumber reports whether s matches the JSON number grammar.
func isJSONNumber(s string) bool {
	i := 0
	if i < len(s) && s[i] == '-' {
		i++
	}
	digits := func() int {
		st := i
		for i < len(s) && s[i] >= '0' && s[i] <= '9' {
			i++
		}
		return i - st
	}
	if digits() == 0 {
		return false
	}
	if i < len(s) && s[i] == '.' {
		i++
		if digits() == 0 {
			return false
		}
	}
	if i < len(s) && (s[i] == 'e' || s[i] == 'E') {
		i++
		if i < len(s) && (s[i] == '+' || s[i] == '-') {
			i++
		}
		if digits() == 0 {
			return false
		}
	}
	return i == len(s)
}
