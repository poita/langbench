package template

import (
	"bytes"

	"example.com/template/filters"
	"example.com/template/syntax"
	"example.com/template/tplerr"
	"example.com/template/value"
)

type namedArg struct {
	name string
	val  value.Value
}

// macro is a macro value: its definition, the scope it was defined in and
// the rendering it belongs to.
type macro struct {
	def   *syntax.MacroDef
	scope *Scope
	r     *rendering
}

func (m *macro) CallableName() string { return "macro " + m.def.Name }

func (m *macro) call(args []value.Value, kwargs []namedArg) (value.Value, error) {
	params := m.def.Params
	if len(args) > len(params) {
		return nil, tplerr.New(tplerr.Type, "macro %s: too many arguments", m.def.Name)
	}
	sc := newScope(m.scope)
	bound := make([]bool, len(params))
	sc.entries = make([]binding, 0, len(params))
	for i, a := range args {
		sc.entries = append(sc.entries, binding{params[i].Name, a})
		bound[i] = true
	}
	for _, kw := range kwargs {
		idx := -1
		for i, p := range params {
			if p.Name == kw.name {
				idx = i
				break
			}
		}
		if idx < 0 || bound[idx] {
			return nil, tplerr.New(tplerr.Type, "macro %s: bad keyword argument %q", m.def.Name, kw.name)
		}
		sc.Set(kw.name, kw.val)
		bound[idx] = true
	}
	for i, p := range params {
		if bound[i] {
			continue
		}
		if p.Default == nil {
			sc.Set(p.Name, value.Undefined)
			continue
		}
		v, err := eval(p.Default, sc)
		if err != nil {
			return nil, err
		}
		sc.Set(p.Name, v)
	}
	var buf bytes.Buffer
	if err := m.r.execNodes(m.def.Body, sc, &buf); err != nil {
		return nil, err
	}
	return buf.String(), nil
}

// rangeFn is the built-in range.
type rangeFn struct{}

func (rangeFn) CallableName() string { return "range" }

func (rangeFn) call(args []value.Value, kwargs []namedArg) (value.Value, error) {
	if len(kwargs) > 0 {
		return nil, tplerr.New(tplerr.Type, "range takes no keyword arguments")
	}
	if len(args) < 1 || len(args) > 3 {
		return nil, tplerr.New(tplerr.Type, "range takes 1 to 3 arguments")
	}
	nums := make([]int64, len(args))
	for i, a := range args {
		switch x := a.(type) {
		case int64:
			nums[i] = x
		case bool:
			if x {
				nums[i] = 1
			}
		case value.UndefinedType:
			return nil, tplerr.New(tplerr.Undefined, "range argument is undefined")
		default:
			return nil, tplerr.New(tplerr.Type, "range arguments must be integers")
		}
	}
	start, stop, step := int64(0), nums[0], int64(1)
	if len(nums) >= 2 {
		start, stop = nums[0], nums[1]
	}
	if len(nums) == 3 {
		step = nums[2]
	}
	if step == 0 {
		return nil, tplerr.New(tplerr.Type, "range step must not be zero")
	}
	var items []value.Value
	if step > 0 && start < stop {
		items = make([]value.Value, 0, (stop-start+step-1)/step)
	} else if step < 0 && start > stop {
		items = make([]value.Value, 0, (start-stop-step-1)/-step)
	}
	if step > 0 {
		for i := start; i < stop; i += step {
			items = append(items, i)
		}
	} else {
		for i := start; i > stop; i += step {
			items = append(items, i)
		}
	}
	return value.NewList(items), nil
}

type callable interface {
	call(args []value.Value, kwargs []namedArg) (value.Value, error)
}

// eval evaluates an expression in a scope.
func eval(e syntax.Expr, sc *Scope) (value.Value, error) {
	switch e := e.(type) {
	case *syntax.Literal:
		return e.Value, nil
	case *syntax.Name:
		if v, ok := sc.Lookup(e.Name); ok {
			return v, nil
		}
		if e.Name == "range" {
			return rangeFn{}, nil
		}
		return value.Undefined, nil
	case *syntax.ListLit:
		items := make([]value.Value, len(e.Elems))
		for i, x := range e.Elems {
			v, err := eval(x, sc)
			if err != nil {
				return nil, err
			}
			items[i] = v
		}
		return value.NewList(items), nil
	case *syntax.Neg:
		v, err := eval(e.X, sc)
		if err != nil {
			return nil, err
		}
		return value.Neg(v)
	case *syntax.Not:
		v, err := eval(e.X, sc)
		if err != nil {
			return nil, err
		}
		t, err := value.Truthy(v)
		if err != nil {
			return nil, err
		}
		return !t, nil
	case *syntax.Binary:
		l, err := eval(e.L, sc)
		if err != nil {
			return nil, err
		}
		r, err := eval(e.R, sc)
		if err != nil {
			return nil, err
		}
		return value.Binary(e.Op, l, r)
	case *syntax.Logic:
		l, err := eval(e.L, sc)
		if err != nil {
			return nil, err
		}
		t, err := value.Truthy(l)
		if err != nil {
			return nil, err
		}
		if t == e.Or {
			return l, nil
		}
		return eval(e.R, sc)
	case *syntax.Compare:
		return evalCompare(e, sc)
	case *syntax.FilterExpr:
		in, err := eval(e.X, sc)
		if err != nil {
			return nil, err
		}
		var args []value.Value
		if len(e.Args) > 0 {
			args = make([]value.Value, len(e.Args))
			for i, a := range e.Args {
				if args[i], err = eval(a, sc); err != nil {
					return nil, err
				}
			}
		}
		return filters.Apply(e.Name, in, args)
	case *syntax.IsDefined:
		v, err := eval(e.X, sc)
		if err != nil {
			return nil, err
		}
		return value.IsUndefined(v) == e.Negate, nil
	case *syntax.Attr:
		v, err := eval(e.X, sc)
		if err != nil {
			return nil, err
		}
		return value.GetAttr(v, e.Name)
	case *syntax.Index:
		v, err := eval(e.X, sc)
		if err != nil {
			return nil, err
		}
		k, err := eval(e.Key, sc)
		if err != nil {
			return nil, err
		}
		return value.GetItem(v, k)
	case *syntax.Call:
		return evalCall(e, sc)
	}
	return nil, tplerr.New(tplerr.Type, "unknown expression %T", e)
}

func evalCompare(e *syntax.Compare, sc *Scope) (value.Value, error) {
	left, err := eval(e.First, sc)
	if err != nil {
		return nil, err
	}
	for i, op := range e.Ops {
		right, err := eval(e.Rest[i], sc)
		if err != nil {
			return nil, err
		}
		ok, err := value.Compare(op, left, right)
		if err != nil {
			return nil, err
		}
		if !ok {
			return false, nil
		}
		left = right
	}
	return true, nil
}

func evalCall(e *syntax.Call, sc *Scope) (value.Value, error) {
	fn, err := eval(e.Fn, sc)
	if err != nil {
		return nil, err
	}
	args := make([]value.Value, len(e.Args))
	for i, a := range e.Args {
		if args[i], err = eval(a, sc); err != nil {
			return nil, err
		}
	}
	var kwargs []namedArg
	if len(e.Kwargs) > 0 {
		kwargs = make([]namedArg, len(e.Kwargs))
		for i, k := range e.Kwargs {
			v, err := eval(k.X, sc)
			if err != nil {
				return nil, err
			}
			kwargs[i] = namedArg{k.Name, v}
		}
	}
	switch f := fn.(type) {
	case value.UndefinedType:
		return nil, tplerr.New(tplerr.Undefined, "calling the undefined value")
	case callable:
		return f.call(args, kwargs)
	}
	return nil, tplerr.New(tplerr.Type, "value of type %T is not callable", fn)
}
