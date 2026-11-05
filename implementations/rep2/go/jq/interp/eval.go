// Package interp evaluates parsed jq filters with a push-style tree-walking
// interpreter: eval(node, input, env, sink) calls sink once per output, in
// stream order, and nested generators are nested callbacks.
package interp

import (
	"errors"
	"fmt"

	"example.com/jq/syntax"
	"example.com/jq/value"
)

// Sink receives each output of a filter. Returning a non-nil error aborts the
// evaluation; the error is returned from Run unchanged.
type Sink func(value.Value) error

// Program is a checked filter ready to run. It is immutable and may be run
// any number of times.
type Program struct {
	root syntax.Node
}

// Compile checks that every builtin and variable used by the filter exists
// and returns a runnable Program.
func Compile(root syntax.Node) (*Program, error) {
	if err := check(root, nil); err != nil {
		return nil, err
	}
	return &Program{root: root}, nil
}

// Run evaluates the program with the given input, calling emit for each
// output. Evaluation stops at the first error, which is returned. Errors
// raised by the filter are *value.Error; an error returned by emit is
// returned as is.
func (p *Program) Run(input value.Value, emit Sink) error {
	return eval(p.root, input, nil, emit)
}

// env is a persistent linked list of variable bindings.
type env struct {
	name string
	val  value.Value
	next *env
}

func (e *env) lookup(name string) (value.Value, bool) {
	for ; e != nil; e = e.next {
		if e.name == name {
			return e.val, true
		}
	}
	return value.Null, false
}

// passThrough wraps an error raised downstream of a try so the try does not
// swallow it.
type passThrough struct{ err error }

func (p *passThrough) Error() string { return p.err.Error() }

// errStop ends the evaluation of a generator early (used by error(f)).
var errStop = errors.New("stop")

func eval(n syntax.Node, in value.Value, ev *env, out Sink) error {
	switch n := n.(type) {
	case *syntax.Identity:
		return out(in)
	case *syntax.Literal:
		return out(n.Val)
	case *syntax.Var:
		v, _ := ev.lookup(n.Name)
		return out(v)
	case *syntax.Index:
		return evalIndex(n, in, ev, out)
	case *syntax.Slice:
		return evalSlice(n, in, ev, out)
	case *syntax.Iterate:
		return eval(n.Term, in, ev, func(t value.Value) error {
			if !value.Iterable(t) {
				if n.Opt {
					return nil
				}
				return value.Iterate(t, nil)
			}
			return value.Iterate(t, out)
		})
	case *syntax.Try:
		var mine *passThrough
		err := eval(n.Term, in, ev, func(v value.Value) error {
			if err := out(v); err != nil {
				mine = &passThrough{err}
				return mine
			}
			return nil
		})
		if err == nil {
			return nil
		}
		if pt, ok := err.(*passThrough); ok {
			return pt.err
		}
		if err == errStop {
			return err
		}
		return nil
	case *syntax.Pipe:
		return eval(n.L, in, ev, func(v value.Value) error { return eval(n.R, v, ev, out) })
	case *syntax.Comma:
		if err := eval(n.L, in, ev, out); err != nil {
			return err
		}
		return eval(n.R, in, ev, out)
	case *syntax.Binary:
		return evalBinary(n, in, ev, out)
	case *syntax.And:
		return eval(n.L, in, ev, func(a value.Value) error {
			if !a.Truthy() {
				return out(value.False)
			}
			return eval(n.R, in, ev, func(b value.Value) error { return out(value.Bool(b.Truthy())) })
		})
	case *syntax.Or:
		return eval(n.L, in, ev, func(a value.Value) error {
			if a.Truthy() {
				return out(value.True)
			}
			return eval(n.R, in, ev, func(b value.Value) error { return out(value.Bool(b.Truthy())) })
		})
	case *syntax.Neg:
		return eval(n.X, in, ev, func(v value.Value) error {
			r, err := value.Neg(v)
			if err != nil {
				return err
			}
			return out(r)
		})
	case *syntax.Array:
		if n.Body == nil {
			return out(value.Array([]value.Value{}))
		}
		var buf []value.Value
		if err := eval(n.Body, in, ev, func(v value.Value) error {
			buf = append(buf, v)
			return nil
		}); err != nil {
			return err
		}
		if buf == nil {
			buf = []value.Value{}
		}
		return out(value.Array(buf))
	case *syntax.Object:
		return evalObject(n, in, ev, out)
	case *syntax.If:
		return eval(n.Cond, in, ev, func(c value.Value) error {
			if c.Truthy() {
				return eval(n.Then, in, ev, out)
			}
			if n.Else == nil {
				return out(in)
			}
			return eval(n.Else, in, ev, out)
		})
	case *syntax.As:
		return eval(n.Source, in, ev, func(v value.Value) error {
			return eval(n.Body, in, &env{n.Name, v, ev}, out)
		})
	case *syntax.Reduce:
		return eval(n.Init, in, ev, func(acc value.Value) error {
			err := eval(n.Source, in, ev, func(v value.Value) error {
				inner := &env{n.Name, v, ev}
				last := value.Null
				if err := eval(n.Update, acc, inner, func(r value.Value) error {
					last = r
					return nil
				}); err != nil {
					return err
				}
				acc = last
				return nil
			})
			if err != nil {
				return err
			}
			return out(acc)
		})
	case *syntax.Call:
		return evalCall(n, in, ev, out)
	}
	return fmt.Errorf("jq: unsupported node %T", n)
}

func evalIndex(n *syntax.Index, in value.Value, ev *env, out Sink) error {
	if lit, ok := n.Key.(*syntax.Literal); ok {
		if _, ok := n.Term.(*syntax.Identity); ok {
			r, err := value.Index(in, lit.Val)
			if err != nil {
				if n.Opt {
					return nil
				}
				return err
			}
			return out(r)
		}
		return eval(n.Term, in, ev, func(t value.Value) error {
			r, err := value.Index(t, lit.Val)
			if err != nil {
				if n.Opt {
					return nil
				}
				return err
			}
			return out(r)
		})
	}
	return eval(n.Key, in, ev, func(k value.Value) error {
		return eval(n.Term, in, ev, func(t value.Value) error {
			r, err := value.Index(t, k)
			if err != nil {
				if n.Opt {
					return nil
				}
				return err
			}
			return out(r)
		})
	})
}

func evalSlice(n *syntax.Slice, in value.Value, ev *env, out Sink) error {
	bound := func(b syntax.Node, f func(value.Value) error) error {
		if b == nil {
			return f(value.Null)
		}
		return eval(b, in, ev, f)
	}
	return bound(n.From, func(from value.Value) error {
		return bound(n.To, func(to value.Value) error {
			return eval(n.Term, in, ev, func(t value.Value) error {
				r, err := value.Slice(t, from, to)
				if err != nil {
					if n.Opt {
						return nil
					}
					return err
				}
				return out(r)
			})
		})
	})
}

func evalBinary(n *syntax.Binary, in value.Value, ev *env, out Sink) error {
	apply := func(a, b value.Value) error {
		r, err := binop(n.Op, a, b)
		if err != nil {
			return err
		}
		return out(r)
	}
	// The right operand is the outer loop.
	if lit, ok := n.R.(*syntax.Literal); ok {
		return eval(n.L, in, ev, func(a value.Value) error { return apply(a, lit.Val) })
	}
	return eval(n.R, in, ev, func(b value.Value) error {
		return eval(n.L, in, ev, func(a value.Value) error { return apply(a, b) })
	})
}

func binop(op syntax.Op, a, b value.Value) (value.Value, error) {
	switch op {
	case syntax.OpAdd:
		return value.Add(a, b)
	case syntax.OpSub:
		return value.Sub(a, b)
	case syntax.OpMul:
		return value.Mul(a, b)
	case syntax.OpDiv:
		return value.Div(a, b)
	case syntax.OpMod:
		return value.Mod(a, b)
	}
	c := value.Compare(a, b)
	var r bool
	switch op {
	case syntax.OpEq:
		r = c == 0
	case syntax.OpNe:
		r = c != 0
	case syntax.OpLt:
		r = c < 0
	case syntax.OpLe:
		r = c <= 0
	case syntax.OpGt:
		r = c > 0
	case syntax.OpGe:
		r = c >= 0
	}
	return value.Bool(r), nil
}

func evalObject(n *syntax.Object, in value.Value, ev *env, out Sink) error {
	if len(n.Entries) == 0 {
		return out(value.ObjectValue(value.NewObject(0)))
	}
	slots := make([]value.Entry, len(n.Entries))
	build := func() value.Value {
		if n.DistinctLiteralKeys {
			return value.ObjectValue(value.ObjectFromUniqueEntries(slots))
		}
		o := value.NewObject(len(slots))
		for _, s := range slots {
			o.Set(s.Key, s.Val)
		}
		return value.ObjectValue(o)
	}
	var fill func(i int) error
	fill = func(i int) error {
		if i == len(slots) {
			return out(build())
		}
		ent := n.Entries[i]
		withKey := func(key string) error {
			return eval(ent.Val, in, ev, func(v value.Value) error {
				slots[i] = value.Entry{Key: key, Val: v}
				return fill(i + 1)
			})
		}
		if lit, ok := ent.Key.(*syntax.Literal); ok && lit.Val.Kind() == value.KindString {
			return withKey(lit.Val.Str())
		}
		return eval(ent.Key, in, ev, func(k value.Value) error {
			if k.Kind() != value.KindString {
				return value.NewError("object keys must be strings")
			}
			return withKey(k.Str())
		})
	}
	return fill(0)
}
