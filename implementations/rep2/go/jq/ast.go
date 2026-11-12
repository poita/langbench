package jq

// node is one compiled filter expression. eval runs it on input in, calling
// out for every result in order. An error from out aborts evaluation and is
// returned unchanged; errors raised by the node itself are *Error values.
type node interface {
	eval(env *env, in Value, out func(Value) error) error
}

// env is a persistent (immutable, shared-tail) list of variable bindings.
type env struct {
	name   string
	val    Value
	parent *env
}

func (e *env) lookup(name string) (Value, bool) {
	for ; e != nil; e = e.parent {
		if e.name == name {
			return e.val, true
		}
	}
	return nil, false
}

type (
	identityNode struct{}
	literalNode  struct{ v Value }
	varNode      struct{ name string }
	pipeNode     struct{ l, r node }
	commaNode    struct{ l, r node }
	negNode      struct{ x node }
	// binNode is an arithmetic or comparison operator; the right operand is
	// the outer loop.
	binNode struct {
		op   string
		l, r node
		fn   func(a, b Value) (Value, error)
	}
	andNode   struct{ l, r node }
	orNode    struct{ l, r node }
	arrayNode struct{ body node } // body may be nil
	ifNode    struct{ cond, then, els node }
	bindNode  struct {
		src  node
		name string
		body node
	}
	reduceNode struct {
		src    node
		name   string
		init   node
		update node
	}
	tryNode struct{ body node }
	// indexNode is T[K]; iterNode is T[]; sliceNode is T[A:B]. opt marks the
	// tolerant "?" form that skips the failing combination.
	indexNode struct {
		term, key node
		opt       bool
	}
	iterNode struct {
		term node
		opt  bool
	}
	sliceNode struct {
		term, from, to node // from/to may be nil
		opt            bool
	}
	objectNode struct{ entries []objEntry }
)

type objEntry struct{ key, val node }

func (identityNode) eval(_ *env, in Value, out func(Value) error) error { return out(in) }

func (n *literalNode) eval(_ *env, _ Value, out func(Value) error) error { return out(n.v) }

func (n *varNode) eval(e *env, _ Value, out func(Value) error) error {
	v, ok := e.lookup(n.name)
	if !ok {
		return errorf("$%s is not defined", n.name)
	}
	return out(v)
}

func (n *pipeNode) eval(e *env, in Value, out func(Value) error) error {
	return n.l.eval(e, in, func(v Value) error { return n.r.eval(e, v, out) })
}

func (n *commaNode) eval(e *env, in Value, out func(Value) error) error {
	if err := n.l.eval(e, in, out); err != nil {
		return err
	}
	return n.r.eval(e, in, out)
}

func (n *negNode) eval(e *env, in Value, out func(Value) error) error {
	return n.x.eval(e, in, func(v Value) error {
		f, ok := v.(float64)
		if !ok {
			return errorf("%s cannot be negated", TypeName(v))
		}
		return out(-f)
	})
}

func (n *binNode) eval(e *env, in Value, out func(Value) error) error {
	if lit, ok := n.r.(*literalNode); ok {
		b := lit.v
		return n.l.eval(e, in, func(a Value) error {
			v, err := n.fn(a, b)
			if err != nil {
				return err
			}
			return out(v)
		})
	}
	return n.r.eval(e, in, func(b Value) error {
		return n.l.eval(e, in, func(a Value) error {
			v, err := n.fn(a, b)
			if err != nil {
				return err
			}
			return out(v)
		})
	})
}

func (n *andNode) eval(e *env, in Value, out func(Value) error) error {
	return n.l.eval(e, in, func(a Value) error {
		if !Truthy(a) {
			return out(false)
		}
		return n.r.eval(e, in, func(b Value) error { return out(Truthy(b)) })
	})
}

func (n *orNode) eval(e *env, in Value, out func(Value) error) error {
	return n.l.eval(e, in, func(a Value) error {
		if Truthy(a) {
			return out(true)
		}
		return n.r.eval(e, in, func(b Value) error { return out(Truthy(b)) })
	})
}

func (n *arrayNode) eval(e *env, in Value, out func(Value) error) error {
	arr := []Value{}
	if n.body != nil {
		err := n.body.eval(e, in, func(v Value) error {
			arr = append(arr, v)
			return nil
		})
		if err != nil {
			return err
		}
	}
	return out(arr)
}

func (n *ifNode) eval(e *env, in Value, out func(Value) error) error {
	return n.cond.eval(e, in, func(c Value) error {
		if Truthy(c) {
			return n.then.eval(e, in, out)
		}
		if n.els == nil {
			return out(in)
		}
		return n.els.eval(e, in, out)
	})
}

func (n *bindNode) eval(e *env, in Value, out func(Value) error) error {
	return n.src.eval(e, in, func(v Value) error {
		return n.body.eval(&env{name: n.name, val: v, parent: e}, in, out)
	})
}

func (n *reduceNode) eval(e *env, in Value, out func(Value) error) error {
	return n.init.eval(e, in, func(init Value) error {
		acc := init
		err := n.src.eval(e, in, func(v Value) error {
			inner := &env{name: n.name, val: v, parent: e}
			var last Value
			err := n.update.eval(inner, acc, func(r Value) error {
				last = r
				return nil
			})
			if err != nil {
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
}

// passThrough wraps an error returned by a downstream consumer so that an
// enclosing try does not mistake it for an error raised inside its body.
type passThrough struct{ err error }

func (p *passThrough) Error() string { return p.err.Error() }

func (n *tryNode) eval(e *env, in Value, out func(Value) error) error {
	err := n.body.eval(e, in, func(v Value) error {
		if err := out(v); err != nil {
			return &passThrough{err}
		}
		return nil
	})
	switch x := err.(type) {
	case nil:
		return nil
	case *passThrough:
		return x.err
	case *Error:
		return nil
	}
	return err
}

func (n *indexNode) eval(e *env, in Value, out func(Value) error) error {
	step := func(t, k Value) error {
		v, err := indexValue(t, k)
		if err != nil {
			if n.opt {
				return nil
			}
			return err
		}
		return out(v)
	}
	_, termIsIdentity := n.term.(identityNode)
	if lit, ok := n.key.(*literalNode); ok {
		if termIsIdentity {
			return step(in, lit.v)
		}
		return n.term.eval(e, in, func(t Value) error { return step(t, lit.v) })
	}
	return n.key.eval(e, in, func(k Value) error {
		if termIsIdentity {
			return step(in, k)
		}
		return n.term.eval(e, in, func(t Value) error { return step(t, k) })
	})
}

func (n *iterNode) eval(e *env, in Value, out func(Value) error) error {
	return n.term.eval(e, in, func(t Value) error {
		switch x := t.(type) {
		case []Value:
			for _, v := range x {
				if err := out(v); err != nil {
					return err
				}
			}
			return nil
		case *Object:
			for _, v := range x.vals {
				if err := out(v); err != nil {
					return err
				}
			}
			return nil
		}
		if n.opt {
			return nil
		}
		return errorf("cannot iterate over %s", TypeName(t))
	})
}

func (n *sliceNode) eval(e *env, in Value, out func(Value) error) error {
	withBound := func(b node, f func(Value) error) error {
		if b == nil {
			return f(nil)
		}
		return b.eval(e, in, f)
	}
	return withBound(n.from, func(a Value) error {
		return withBound(n.to, func(b Value) error {
			return n.term.eval(e, in, func(t Value) error {
				v, err := sliceValue(t, a, b)
				if err != nil {
					if n.opt {
						return nil
					}
					return err
				}
				return out(v)
			})
		})
	})
}

func (n *objectNode) eval(e *env, in Value, out func(Value) error) error {
	keys := make([]string, len(n.entries))
	vals := make([]Value, len(n.entries))
	var rec func(i int) error
	rec = func(i int) error {
		if i == len(n.entries) {
			o := NewObject(len(keys))
			for j, k := range keys {
				o.Set(k, vals[j])
			}
			return out(o)
		}
		ent := n.entries[i]
		return ent.key.eval(e, in, func(k Value) error {
			ks, ok := k.(string)
			if !ok {
				return errorf("object key must be a string, not %s", TypeName(k))
			}
			return ent.val.eval(e, in, func(v Value) error {
				keys[i], vals[i] = ks, v
				return rec(i + 1)
			})
		})
	}
	return rec(0)
}
