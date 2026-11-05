package jq

import (
	"jq/value"
)

// env is a persistent linked list of variable bindings.
type env struct {
	name   string
	val    value.Value
	parent *env
}

func (e *env) lookup(name string) (value.Value, bool) {
	for ; e != nil; e = e.parent {
		if e.name == name {
			return e.val, true
		}
	}
	return value.Null, false
}

// sink receives one output of a stream. A non-nil return aborts evaluation.
type sink func(value.Value) error

// eval evaluates n on input in, calling out once per output in stream order.
func eval(n *node, in value.Value, e *env, out sink) error {
	switch n.kind {
	case nIdentity:
		return out(in)
	case nLiteral:
		return out(n.val)
	case nVar:
		v, ok := e.lookup(n.name)
		if !ok {
			return errorf("$%s is not defined", n.name)
		}
		return out(v)

	case nField:
		if n.a.single {
			t, err := one(n.a, in, e)
			if err != nil {
				return err
			}
			v, ok := indexField(t, n.name)
			if !ok {
				if n.opt {
					return nil
				}
				return fieldError(t, n.name)
			}
			return out(v)
		}
		return eval(n.a, in, e, func(t value.Value) error {
			v, ok := indexField(t, n.name)
			if !ok {
				if n.opt {
					return nil
				}
				return fieldError(t, n.name)
			}
			return out(v)
		})

	case nIndex:
		return eval(n.b, in, e, func(k value.Value) error {
			return eval(n.a, in, e, func(t value.Value) error {
				v, ok := indexValue(t, k)
				if !ok {
					if n.opt {
						return nil
					}
					return indexError(t, k)
				}
				return out(v)
			})
		})

	case nIterate:
		return eval(n.a, in, e, func(t value.Value) error {
			ok, err := iterate(t, out)
			if !ok && !n.opt {
				return errorf("Cannot iterate over %s", t.TypeName())
			}
			return err
		})

	case nSlice:
		from, to := sliceBound(n.b), sliceBound(n.c)
		return eval(from, in, e, func(f value.Value) error {
			return eval(to, in, e, func(tv value.Value) error {
				return eval(n.a, in, e, func(t value.Value) error {
					v, ok := sliceValue(t, f, tv)
					if !ok {
						if n.opt {
							return nil
						}
						return sliceError(t)
					}
					return out(v)
				})
			})
		})

	case nTry:
		var down error
		err := eval(n.a, in, e, func(v value.Value) error {
			if err := out(v); err != nil {
				down = err
				return err
			}
			return nil
		})
		if err != nil && err != down {
			return nil // raised inside the term: swallowed
		}
		return err

	case nPipe:
		return eval(n.a, in, e, func(v value.Value) error {
			return eval(n.b, v, e, out)
		})

	case nComma:
		if err := eval(n.a, in, e, out); err != nil {
			return err
		}
		return eval(n.b, in, e, out)

	case nBinary:
		if n.b.single {
			b, err := one(n.b, in, e)
			if err != nil {
				return err
			}
			if n.a.single {
				a, err := one(n.a, in, e)
				if err != nil {
					return err
				}
				r, err := binaryOp(n.op, a, b)
				if err != nil {
					return err
				}
				return out(r)
			}
			return eval(n.a, in, e, func(a value.Value) error {
				r, err := binaryOp(n.op, a, b)
				if err != nil {
					return err
				}
				return out(r)
			})
		}
		return eval(n.b, in, e, func(b value.Value) error {
			return eval(n.a, in, e, func(a value.Value) error {
				r, err := binaryOp(n.op, a, b)
				if err != nil {
					return err
				}
				return out(r)
			})
		})

	case nAnd:
		return eval(n.a, in, e, func(a value.Value) error {
			if !a.Truthy() {
				return out(value.False)
			}
			return eval(n.b, in, e, func(b value.Value) error {
				return out(value.Bool(b.Truthy()))
			})
		})

	case nOr:
		return eval(n.a, in, e, func(a value.Value) error {
			if a.Truthy() {
				return out(value.True)
			}
			return eval(n.b, in, e, func(b value.Value) error {
				return out(value.Bool(b.Truthy()))
			})
		})

	case nNeg:
		return eval(n.a, in, e, func(v value.Value) error {
			if !v.IsNumber() {
				return errorf("%s (%s) cannot be negated", v.TypeName(), short(v))
			}
			return out(value.Number(-v.Float()))
		})

	case nArray:
		if n.a == nil {
			return out(value.Array([]value.Value{}))
		}
		items := make([]value.Value, 0, 4)
		err := eval(n.a, in, e, func(v value.Value) error {
			items = append(items, v)
			return nil
		})
		if err != nil {
			return err
		}
		return out(value.Array(items))

	case nObject:
		return evalObject(n, in, e, out)

	case nIf:
		return eval(n.a, in, e, func(c value.Value) error {
			if c.Truthy() {
				return eval(n.b, in, e, out)
			}
			return eval(n.c, in, e, out)
		})

	case nBind:
		return eval(n.a, in, e, func(v value.Value) error {
			return eval(n.b, in, &env{name: n.name, val: v, parent: e}, out)
		})

	case nReduce:
		return eval(n.b, in, e, func(init value.Value) error {
			acc := init
			err := eval(n.a, in, e, func(v value.Value) error {
				inner := &env{name: n.name, val: v, parent: e}
				last := value.Null
				if n.c.single {
					r, err := one(n.c, acc, inner)
					if err != nil {
						return err
					}
					acc = r
					return nil
				}
				err := eval(n.c, acc, inner, func(r value.Value) error {
					last = r
					return nil
				})
				acc = last
				return err
			})
			if err != nil {
				return err
			}
			return out(acc)
		})

	case nCall:
		return callBuiltin(n, in, e, out)
	}
	return errorf("internal error: unknown node kind %d", n.kind)
}

var nullNode = &node{kind: nLiteral, val: value.Null, single: true}

func sliceBound(n *node) *node {
	if n == nil {
		return nullNode
	}
	return n
}

// one evaluates a node that is statically known to produce exactly one
// output (or an error), without building callbacks for the common shapes.
func one(n *node, in value.Value, e *env) (value.Value, error) {
	switch n.kind {
	case nIdentity:
		return in, nil
	case nLiteral:
		return n.val, nil
	case nVar:
		v, ok := e.lookup(n.name)
		if !ok {
			return value.Null, errorf("$%s is not defined", n.name)
		}
		return v, nil
	case nField:
		t, err := one(n.a, in, e)
		if err != nil {
			return value.Null, err
		}
		v, ok := indexField(t, n.name)
		if !ok {
			return value.Null, fieldError(t, n.name)
		}
		return v, nil
	case nIndex:
		k, err := one(n.b, in, e)
		if err != nil {
			return value.Null, err
		}
		t, err := one(n.a, in, e)
		if err != nil {
			return value.Null, err
		}
		v, ok := indexValue(t, k)
		if !ok {
			return value.Null, indexError(t, k)
		}
		return v, nil
	case nBinary:
		b, err := one(n.b, in, e)
		if err != nil {
			return value.Null, err
		}
		a, err := one(n.a, in, e)
		if err != nil {
			return value.Null, err
		}
		return binaryOp(n.op, a, b)
	case nPipe:
		v, err := one(n.a, in, e)
		if err != nil {
			return value.Null, err
		}
		return one(n.b, v, e)
	case nNeg:
		v, err := one(n.a, in, e)
		if err != nil {
			return value.Null, err
		}
		if !v.IsNumber() {
			return value.Null, errorf("%s (%s) cannot be negated", v.TypeName(), short(v))
		}
		return value.Number(-v.Float()), nil
	case nAnd, nOr:
		a, err := one(n.a, in, e)
		if err != nil {
			return value.Null, err
		}
		if a.Truthy() == (n.kind == nOr) {
			return value.Bool(n.kind == nOr), nil
		}
		b, err := one(n.b, in, e)
		if err != nil {
			return value.Null, err
		}
		return value.Bool(b.Truthy()), nil
	case nIf:
		c, err := one(n.a, in, e)
		if err != nil {
			return value.Null, err
		}
		if c.Truthy() {
			return one(n.b, in, e)
		}
		return one(n.c, in, e)
	}
	// General case: run the stream and take its single output.
	result := value.Null
	err := eval(n, in, e, func(v value.Value) error {
		result = v
		return nil
	})
	return result, err
}

// evalObject implements {k1: v1, k2: v2, ...}: nested loops with the first
// entry outermost and, within an entry, the key stream outside the value
// stream. One scratch slot per entry is reused for every combination.
func evalObject(n *node, in value.Value, e *env, out sink) error {
	k := len(n.entries)
	keys := make([]string, k)
	vals := make([]value.Value, k)
	var rec func(i int) error
	build := func() error {
		var o *value.Object
		if n.litKeys {
			o = value.NewObject(k)
			for i := 0; i < k; i++ {
				o.AppendNew(keys[i], vals[i])
			}
		} else {
			o = value.NewObject(k)
			for i := 0; i < k; i++ {
				o.Set(keys[i], vals[i])
			}
		}
		return out(value.ObjectValue(o))
	}
	rec = func(i int) error {
		if i == k {
			return build()
		}
		ent := n.entries[i]
		withKey := func(key string) error {
			keys[i] = key
			if ent.val.single {
				v, err := one(ent.val, in, e)
				if err != nil {
					return err
				}
				vals[i] = v
				return rec(i + 1)
			}
			return eval(ent.val, in, e, func(v value.Value) error {
				vals[i] = v
				return rec(i + 1)
			})
		}
		if ent.key.kind == nLiteral {
			return withKey(ent.key.val.Str())
		}
		return eval(ent.key, in, e, func(kv value.Value) error {
			if !kv.IsString() {
				return errorf("Object keys must be strings")
			}
			return withKey(kv.Str())
		})
	}
	return rec(0)
}
