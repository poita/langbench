package interp

import (
	"github.com/peter/jq/syntax"
	"github.com/peter/jq/value"
)

// sink receives one output of an evaluation. Returning a non-nil error stops
// the evaluation and propagates the error to the caller of eval.
type sink = func(value.Value) error

// env is a persistent variable environment: one node per binding.
type env struct {
	val  value.Value
	next *env
}

func (e *env) lookup(slot int) value.Value {
	for ; slot > 0; slot-- {
		e = e.next
	}
	return e.val
}

// Run evaluates the program against input and calls emit for every output in
// order. Evaluation stops at the first error, which is returned: an *Error
// for a jq runtime error, or whatever error emit returned.
func (p *Program) Run(input value.Value, emit func(value.Value) error) error {
	return eval(p.root, input, nil, emit)
}

func eval(n *node, v value.Value, e *env, out sink) error {
	switch n.op {
	case syntax.OpIdentity:
		return out(v)
	case syntax.OpLiteral:
		return out(n.val)
	case syntax.OpVar:
		return out(e.lookup(n.slot))
	case syntax.OpPipe:
		return eval(n.a, v, e, func(x value.Value) error { return eval(n.b, x, e, out) })
	case syntax.OpComma:
		if err := eval(n.a, v, e, out); err != nil {
			return err
		}
		return eval(n.b, v, e, out)
	case syntax.OpNeg:
		return eval(n.a, v, e, func(x value.Value) error {
			if x.Kind() != value.KindNumber {
				return errorf("%s cannot be negated", describe(x))
			}
			return out(value.Number(-x.Float()))
		})
	case syntax.OpBinary:
		// The right operand is the outer loop.
		return eval(n.b, v, e, func(r value.Value) error {
			return eval(n.a, v, e, func(l value.Value) error {
				res, err := binary(n.bin, l, r)
				if err != nil {
					return err
				}
				return out(res)
			})
		})
	case syntax.OpAnd:
		return eval(n.a, v, e, func(l value.Value) error {
			if !l.Truthy() {
				return out(value.False)
			}
			return eval(n.b, v, e, func(r value.Value) error { return out(value.Bool(r.Truthy())) })
		})
	case syntax.OpOr:
		return eval(n.a, v, e, func(l value.Value) error {
			if l.Truthy() {
				return out(value.True)
			}
			return eval(n.b, v, e, func(r value.Value) error { return out(value.Bool(r.Truthy())) })
		})
	case syntax.OpArray:
		if n.a == nil {
			return out(value.Array([]value.Value{}))
		}
		elems := []value.Value{}
		if err := eval(n.a, v, e, func(x value.Value) error {
			elems = append(elems, x)
			return nil
		}); err != nil {
			return err
		}
		return out(value.Array(elems))
	case syntax.OpObject:
		return evalObject(n, 0, make([]value.Entry, len(n.entries)), v, e, out)
	case syntax.OpIf:
		return eval(n.a, v, e, func(c value.Value) error {
			switch {
			case c.Truthy():
				return eval(n.b, v, e, out)
			case n.c != nil:
				return eval(n.c, v, e, out)
			}
			return out(v)
		})
	case syntax.OpAs:
		return eval(n.a, v, e, func(x value.Value) error {
			return eval(n.b, v, &env{val: x, next: e}, out)
		})
	case syntax.OpReduce:
		return eval(n.b, v, e, func(acc value.Value) error {
			err := eval(n.a, v, e, func(x value.Value) error {
				last, seen := value.Null, false
				err := eval(n.c, acc, &env{val: x, next: e}, func(y value.Value) error {
					last, seen = y, true
					return nil
				})
				if err != nil {
					return err
				}
				if seen {
					acc = last
				} else {
					acc = value.Null
				}
				return nil
			})
			if err != nil {
				return err
			}
			return out(acc)
		})
	case syntax.OpIndex:
		return evalIndex(n, v, e, out)
	case syntax.OpIter:
		return eval(n.a, v, e, func(t value.Value) error {
			switch t.Kind() {
			case value.KindArray:
				for _, x := range t.Elems() {
					if err := out(x); err != nil {
						return err
					}
				}
				return nil
			case value.KindObject:
				for _, en := range t.Object().Entries() {
					if err := out(en.Value); err != nil {
						return err
					}
				}
				return nil
			}
			if n.optional {
				return nil
			}
			return errorf("Cannot iterate over %s", describe(t))
		})
	case syntax.OpSlice:
		return evalSlice(n, v, e, out)
	case syntax.OpTry:
		return evalTry(n.a, v, e, out)
	case syntax.OpCall:
		return evalCall(n, v, e, out)
	}
	panic("interp: unknown node")
}

// evalTry emits the outputs of term until its first error, which is
// swallowed. Errors returned by out (raised downstream) are not caught.
func evalTry(term *node, v value.Value, e *env, out sink) error {
	var downstream error
	err := eval(term, v, e, func(x value.Value) error {
		if err := out(x); err != nil {
			downstream = err
			return err
		}
		return nil
	})
	if err != nil && err == downstream {
		return err
	}
	if _, ok := err.(*Error); ok || err == nil {
		return nil
	}
	return err
}

// evalObject enumerates the combinations of an object construction: entries
// left to right, key stream outside value stream. slots holds the current
// (key, value) pair of every entry.
func evalObject(n *node, i int, slots []value.Entry, v value.Value, e *env, out sink) error {
	if i == len(n.entries) {
		return out(buildObject(n, slots))
	}
	en := &n.entries[i]
	withKey := func(k string) error {
		return eval(en.val, v, e, func(x value.Value) error {
			slots[i] = value.Entry{Key: k, Value: x}
			return evalObject(n, i+1, slots, v, e, out)
		})
	}
	if en.isLit {
		return withKey(en.litKey)
	}
	return eval(en.key, v, e, func(k value.Value) error {
		if k.Kind() != value.KindString {
			return errorf("Object keys must be strings, not %s", describe(k))
		}
		return withKey(k.Str())
	})
}

func buildObject(n *node, slots []value.Entry) value.Value {
	if n.literalKeys {
		return value.ObjectFromEntries(append([]value.Entry(nil), slots...))
	}
	b := value.NewObjectBuilder(len(slots))
	for _, s := range slots {
		b.Set(s.Key, s.Value)
	}
	return b.Build()
}
