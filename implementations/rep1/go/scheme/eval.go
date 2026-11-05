package scheme

// Closure is a procedure descriptor plus its captured environment.
type Closure struct {
	proc *procDesc
	env  *Frame
}

// ev evaluates n, short-circuiting constants and variables without a call
// into the full evaluator.
func (in *Interp) ev(n *node, env *Frame) Value {
	switch n.kind {
	case nConst:
		return n.val
	case nVar:
		return in.lookup(n.id, env)
	}
	return in.eval(n, env)
}

// eval is the single trampolined evaluator. Forms in tail position replace n
// (and env) and loop; other subforms recurse. Applications fall out of the
// switch into the shared call section below it.
func (in *Interp) eval(n *node, env *Frame) Value {
loop:
	for {
		var fn Value
		var base int
		switch n.kind {
		case nConst:
			return n.val
		case nVar:
			return in.lookup(n.id, env)
		case nIf:
			if in.ev(n.a, env).isFalse() {
				if n.c == nil {
					return voidV
				}
				n = n.c
			} else {
				n = n.b
			}
			continue
		case nDefine:
			in.define(n.id, env, in.ev(n.a, env))
			return voidV
		case nSet:
			in.assign(n.id, env, in.ev(n.a, env))
			return voidV
		case nLambda:
			return Value{t: tClosure, ref: &Closure{n.proc, env}}
		case nBegin:
			last := len(n.list) - 1
			for _, f := range n.list[:last] {
				in.ev(f, env)
			}
			n = n.list[last]
			continue
		case nAnd:
			if len(n.list) == 0 {
				return trueV
			}
			last := len(n.list) - 1
			for _, f := range n.list[:last] {
				if v := in.ev(f, env); v.isFalse() {
					return v
				}
			}
			n = n.list[last]
			continue
		case nOr:
			if len(n.list) == 0 {
				return falsV
			}
			last := len(n.list) - 1
			for _, f := range n.list[:last] {
				if v := in.ev(f, env); !v.isFalse() {
					return v
				}
			}
			n = n.list[last]
			continue
		case nCond:
			for i := range n.clauses {
				c := &n.clauses[i]
				if c.test == nil {
					n = c.body
					continue loop
				}
				v := in.ev(c.test, env)
				if v.isFalse() {
					continue
				}
				if c.body == nil {
					return v
				}
				n = c.body
				continue loop
			}
			return voidV
		case nLet:
			b := len(in.stack)
			for _, init := range n.list {
				v := in.ev(init, env)
				in.stack = append(in.stack, v)
			}
			vals := make([]Value, len(n.list))
			copy(vals, in.stack[b:])
			in.stack = in.stack[:b]
			env = &Frame{parent: env, ids: n.names, vals: vals}
			n = n.a
			continue
		case nLetStar:
			if len(n.names) == 0 {
				env = &Frame{parent: env}
			}
			for i, init := range n.list {
				v := in.ev(init, env)
				env = &Frame{parent: env, ids: n.names[i : i+1 : i+1], vals: []Value{v}}
			}
			n = n.a
			continue
		case nLetrec:
			env = &Frame{parent: env,
				ids:  make([]int32, 0, len(n.names)),
				vals: make([]Value, 0, len(n.names))}
			for i, init := range n.list {
				v := in.ev(init, env)
				in.define(n.names[i], env, v)
			}
			n = n.a
			continue
		case nNamedLet:
			base = len(in.stack)
			for _, init := range n.list {
				v := in.ev(init, env)
				in.stack = append(in.stack, v)
			}
			loopFrame := &Frame{parent: env, ids: n.names, vals: make([]Value, 1)}
			fn = Value{t: tClosure, ref: &Closure{n.proc, loopFrame}}
			loopFrame.vals[0] = fn
		case nApp:
			fn = in.ev(n.list[0], env)
			base = len(in.stack)
			for _, a := range n.list[1:] {
				v := in.ev(a, env)
				in.stack = append(in.stack, v)
			}
		}

		// Application of fn to in.stack[base:].
		for {
			switch fn.t {
			case tClosure:
				c := fn.ref.(*Closure)
				p := c.proc
				args := in.stack[base:]
				nargs := len(args)
				if nargs < p.nreq || (!p.rest && nargs > p.nreq) {
					throw(ErrArity)
				}
				vals := make([]Value, len(p.params))
				copy(vals, args[:p.nreq])
				if p.rest {
					rest := nilV
					for i := nargs - 1; i >= p.nreq; i-- {
						rest = cons(args[i], rest)
					}
					vals[p.nreq] = rest
				}
				in.stack = in.stack[:base]
				env = &Frame{parent: c.env, ids: p.params, vals: vals}
				n = p.body
				continue loop
			case tPrim:
				args := in.stack[base:]
				def := &primTable[fn.n]
				if len(args) < def.min || (def.max >= 0 && len(args) > def.max) {
					throw(ErrArity)
				}
				if fn.n == primApplyIdx {
					fn = in.spliceApply(base)
					continue
				}
				r := def.fn(in, args)
				in.stack = in.stack[:base]
				return r
			default:
				throw(ErrType)
			}
		}
	}
}

// spliceApply rearranges the argument stack in place for (apply f a ... lst):
// the procedure is dropped and the list's elements are spliced after the
// leading arguments. It returns the procedure to call.
func (in *Interp) spliceApply(base int) Value {
	k := len(in.stack) - base
	f := in.stack[base]
	lst := in.stack[base+k-1]
	for l := lst; ; l = l.pair().cdr {
		if l.t == tNil {
			break
		}
		if l.t != tPair {
			throw(ErrType)
		}
	}
	copy(in.stack[base:], in.stack[base+1:base+k-1])
	in.stack = in.stack[:base+k-2]
	for lst.t == tPair {
		p := lst.pair()
		in.stack = append(in.stack, p.car)
		lst = p.cdr
	}
	return f
}
