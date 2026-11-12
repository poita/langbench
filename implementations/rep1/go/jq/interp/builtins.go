package interp

import (
	"example.com/jq/syntax"
	"math"
	"strings"

	"example.com/jq/value"
)

// builtinFn builds the evaluator for a builtin from its compiled arguments.
type builtinFn func(args []evalFn) evalFn

type builtinKey struct {
	name  string
	arity int
}

var builtins map[builtinKey]builtinFn

func init() {
	builtins = map[builtinKey]builtinFn{
		{"empty", 0}: func([]evalFn) evalFn {
			return func(*env, Value, func(Value) error) error { return nil }
		},
		{"error", 0}: func([]evalFn) evalFn {
			return func(_ *env, in Value, _ func(Value) error) error { return &Error{Value: in} }
		},
		{"error", 1}: func(a []evalFn) evalFn {
			return func(e *env, in Value, _ func(Value) error) error {
				return a[0](e, in, func(v Value) error { return &Error{Value: v} })
			}
		},
		{"select", 1}: func(a []evalFn) evalFn {
			return func(e *env, in Value, out func(Value) error) error {
				return a[0](e, in, func(c Value) error {
					if value.Truthy(c) {
						return out(in)
					}
					return nil
				})
			}
		},
		{"map", 1}: func(a []evalFn) evalFn {
			return func(e *env, in Value, out func(Value) error) error {
				var res []Value
				if arr, ok := in.([]Value); ok {
					res = make([]Value, 0, len(arr))
				} else {
					res = []Value{}
				}
				err := iterate(in, func(x Value) error {
					return a[0](e, x, func(y Value) error {
						res = append(res, y)
						return nil
					})
				})
				if err != nil {
					return err
				}
				return out(res)
			}
		},
		{"sort_by", 1}: func(a []evalFn) evalFn {
			return byKey(a[0], "sorted", func(arr, keys []Value) Value {
				perm := value.SortedOrder(keys)
				res := make([]Value, len(arr))
				for i, p := range perm {
					res[i] = arr[p]
				}
				return res
			})
		},
		{"group_by", 1}: func(a []evalFn) evalFn {
			return byKey(a[0], "grouped", func(arr, keys []Value) Value {
				perm := value.SortedOrder(keys)
				res := []Value{}
				var cur []Value
				for i, p := range perm {
					if i > 0 && value.Compare(keys[perm[i-1]], keys[p]) != 0 {
						res = append(res, cur)
						cur = nil
					}
					cur = append(cur, arr[p])
				}
				if cur != nil {
					res = append(res, cur)
				}
				return res
			})
		},
		{"has", 1}: func(a []evalFn) evalFn {
			return func(e *env, in Value, out func(Value) error) error {
				return a[0](e, in, func(k Value) error {
					r, err := has(in, k)
					if err != nil {
						return err
					}
					return out(r)
				})
			}
		},
	}

	simple := map[string]func(Value) (Value, error){
		"not":      func(in Value) (Value, error) { return !value.Truthy(in), nil },
		"length":   length,
		"keys":     keys,
		"type":     func(in Value) (Value, error) { return value.TypeName(in), nil },
		"add":      addAll,
		"sort":     sortValues,
		"unique":   unique,
		"reverse":  reverse,
		"min":      func(in Value) (Value, error) { return extreme(in, false) },
		"max":      func(in Value) (Value, error) { return extreme(in, true) },
		"tostring": tostring,
		"tonumber": tonumber,
	}
	for name, f := range simple {
		builtins[builtinKey{name, 0}] = func([]evalFn) evalFn {
			return func(_ *env, in Value, out func(Value) error) error {
				v, err := f(in)
				if err != nil {
					return err
				}
				return out(v)
			}
		}
	}
}

func (c *compiler) compileCall(n *syntax.Call) evalFn {
	b, ok := builtins[builtinKey{n.Name, len(n.Args)}]
	if !ok {
		c.fail("%s/%d is not defined", n.Name, len(n.Args))
	}
	args := make([]evalFn, len(n.Args))
	for i, a := range n.Args {
		args[i] = c.compile(a)
	}
	return b(args)
}

// byKey evaluates the key expression f on every element of an array input,
// collecting all of its outputs into one key array per element, then hands the
// elements and keys to build. Each key is evaluated exactly once.
func byKey(f evalFn, what string, build func(arr, keys []Value) Value) evalFn {
	return func(e *env, in Value, out func(Value) error) error {
		arr, ok := in.([]Value)
		if !ok {
			return errf("%s cannot be %s, as it is not an array", describe(in), what)
		}
		keys := make([]Value, len(arr))
		for i, x := range arr {
			ks := []Value{}
			if err := f(e, x, func(k Value) error {
				ks = append(ks, k)
				return nil
			}); err != nil {
				return err
			}
			keys[i] = ks
		}
		return out(build(arr, keys))
	}
}

func length(in Value) (Value, error) {
	switch x := in.(type) {
	case nil:
		return 0.0, nil
	case float64:
		return math.Abs(x), nil
	case string:
		return float64(runeCount(x)), nil
	case []Value:
		return float64(len(x)), nil
	case *value.Object:
		return float64(x.Len()), nil
	}
	return nil, errf("%s has no length", describe(in))
}

func keys(in Value) (Value, error) {
	switch x := in.(type) {
	case *value.Object:
		ks := x.SortedKeys()
		out := make([]Value, len(ks))
		for i, k := range ks {
			out[i] = k
		}
		return out, nil
	case []Value:
		out := make([]Value, len(x))
		for i := range x {
			out[i] = float64(i)
		}
		return out, nil
	}
	return nil, errf("%s has no keys", describe(in))
}

func has(in, k Value) (Value, error) {
	switch x := in.(type) {
	case nil:
		return false, nil
	case *value.Object:
		if ks, ok := k.(string); ok {
			return x.Has(ks), nil
		}
	case []Value:
		if kf, ok := k.(float64); ok {
			i, ok := toIndex(kf)
			return ok && i >= 0 && i < len(x), nil
		}
	}
	return nil, errf("Cannot check whether %s has a %s key", value.TypeName(in), value.TypeName(k))
}

// addAll sums the elements of an array (or the values of an object) with +,
// starting from null, in time linear in the total size.
func addAll(in Value) (Value, error) {
	var elems []Value
	switch x := in.(type) {
	case []Value:
		elems = x
	case *value.Object:
		elems = x.Values()
	default:
		return nil, errf("Cannot iterate over %s", describe(in))
	}
	// Classify the non-null elements; homogeneous input takes a linear path.
	kind := value.KindNull
	homogeneous := true
	for _, x := range elems {
		if x == nil {
			continue
		}
		k := value.KindOf(x)
		if k == value.KindFalse || k == value.KindTrue {
			k = value.KindFalse
		}
		if kind == value.KindNull {
			kind = k
		} else if kind != k {
			homogeneous = false
			break
		}
	}
	if homogeneous {
		switch kind {
		case value.KindNumber:
			sum := 0.0
			for _, x := range elems {
				if f, ok := x.(float64); ok {
					sum += f
				}
			}
			return sum, nil
		case value.KindString:
			var sb strings.Builder
			for _, x := range elems {
				if s, ok := x.(string); ok {
					sb.WriteString(s)
				}
			}
			return sb.String(), nil
		case value.KindArray:
			n := 0
			for _, x := range elems {
				if a, ok := x.([]Value); ok {
					n += len(a)
				}
			}
			res := make([]Value, 0, n)
			for _, x := range elems {
				if a, ok := x.([]Value); ok {
					res = append(res, a...)
				}
			}
			return res, nil
		case value.KindObject:
			var b *value.Builder
			for _, x := range elems {
				if o, ok := x.(*value.Object); ok {
					if b == nil {
						b = value.NewBuilder(o.Len())
					}
					for i := 0; i < o.Len(); i++ {
						k, v := o.At(i)
						b.Set(k, v)
					}
				}
			}
			return b.Build(), nil
		}
	}
	var acc Value
	for _, x := range elems {
		var err error
		if acc, err = add(acc, x); err != nil {
			return nil, err
		}
	}
	return acc, nil
}

func sortValues(in Value) (Value, error) {
	arr, ok := in.([]Value)
	if !ok {
		return nil, errf("%s cannot be sorted, as it is not an array", describe(in))
	}
	return value.Sort(arr), nil
}

func unique(in Value) (Value, error) {
	arr, ok := in.([]Value)
	if !ok {
		return nil, errf("%s cannot be sorted, as it is not an array", describe(in))
	}
	sorted := value.Sort(arr)
	out := sorted[:0]
	for i, x := range sorted {
		if i == 0 || value.Compare(out[len(out)-1], x) != 0 {
			out = append(out, x)
		}
	}
	return out, nil
}

func reverse(in Value) (Value, error) {
	switch x := in.(type) {
	case nil:
		return []Value{}, nil
	case []Value:
		out := make([]Value, len(x))
		for i, v := range x {
			out[len(x)-1-i] = v
		}
		return out, nil
	}
	return nil, errf("Cannot reverse %s", describe(in))
}

// extreme returns the minimum (the first of equal minima) or maximum (the last
// of equal maxima) of an array.
func extreme(in Value, wantMax bool) (Value, error) {
	arr, ok := in.([]Value)
	if !ok {
		return nil, errf("Cannot compute extreme of %s", describe(in))
	}
	if len(arr) == 0 {
		return nil, nil
	}
	best := arr[0]
	for _, x := range arr[1:] {
		c := value.Compare(x, best)
		if (wantMax && c >= 0) || (!wantMax && c < 0) {
			best = x
		}
	}
	return best, nil
}

func tostring(in Value) (Value, error) {
	if s, ok := in.(string); ok {
		return s, nil
	}
	return value.String(in), nil
}

func tonumber(in Value) (Value, error) {
	switch x := in.(type) {
	case float64:
		return x, nil
	case string:
		if f, ok := value.ParseNumber(x); ok {
			return f, nil
		}
		return nil, errf("Cannot parse %q as a number", x)
	}
	return nil, errf("%s cannot be parsed as a number", describe(in))
}

func runeCount(s string) int {
	n := 0
	for range s {
		n++
	}
	return n
}
