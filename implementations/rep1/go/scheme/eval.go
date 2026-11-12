package scheme

// eval evaluates n in env. It is a trampoline: forms in tail position (the
// branches of if, the last form of a body, a procedure call, ...) replace nd
// and env and go round the loop instead of recursing, so tail calls use
// constant host stack. Non-tail evaluation recurses.
func (in *Interp) eval(nd node, env *Env) Value {
eval:
	for {
		switch n := nd.(type) {
		case *constNode:
			return n.v

		case *refNode:
			v, ok := env.lookup(n.sym)
			if !ok {
				Raise(ErrUnboundVariable)
			}
			return v

		case *ifNode:
			if IsTrue(in.eval(n.test, env)) {
				nd = n.then
			} else if n.els != nil {
				nd = n.els
			} else {
				return Unspecified
			}

		case *seqNode:
			last := len(n.nodes) - 1
			for _, s := range n.nodes[:last] {
				in.eval(s, env)
			}
			nd = n.nodes[last]

		case *defineNode:
			env.define(n.sym, in.eval(n.expr, env))
			return Unspecified

		case *setNode:
			v := in.eval(n.expr, env)
			if !env.set(n.sym, v) {
				Raise(ErrUnboundVariable)
			}
			return Unspecified

		case *lambdaNode:
			return &Closure{lam: n, env: env}

		case *letNode:
			vals := make([]Value, len(n.inits), len(n.inits))
			for i, init := range n.inits {
				vals[i] = in.eval(init, env)
			}
			env = &Env{parent: env, syms: n.syms, vals: vals}
			nd = n.body

		case *letrecNode:
			env = &Env{parent: env, syms: n.syms[:0:0]}
			for i, init := range n.inits {
				env.define(n.syms[i], in.eval(init, env))
			}
			nd = n.body

		case *namedLetNode:
			args := make([]Value, len(n.inits))
			for i, init := range n.inits {
				args[i] = in.eval(init, env)
			}
			loopEnv := &Env{parent: env, syms: []*Symbol{n.name}, vals: make([]Value, 1)}
			loopEnv.vals[0] = &Closure{lam: n.lam, env: loopEnv}
			env = &Env{parent: loopEnv, syms: n.lam.all, vals: args}
			nd = n.lam.body

		case *condNode:
			matched := false
			for i := range n.clauses {
				cl := &n.clauses[i]
				if cl.test == nil {
					nd, matched = cl.body, true
					break
				}
				tv := in.eval(cl.test, env)
				if IsTrue(tv) {
					if cl.body == nil {
						return tv
					}
					nd, matched = cl.body, true
					break
				}
			}
			if !matched {
				return Unspecified
			}

		case *andNode:
			if len(n.nodes) == 0 {
				return True
			}
			last := len(n.nodes) - 1
			for _, s := range n.nodes[:last] {
				if v := in.eval(s, env); !IsTrue(v) {
					return v
				}
			}
			nd = n.nodes[last]

		case *orNode:
			if len(n.nodes) == 0 {
				return False
			}
			last := len(n.nodes) - 1
			for _, s := range n.nodes[:last] {
				if v := in.eval(s, env); IsTrue(v) {
					return v
				}
			}
			nd = n.nodes[last]

		case *callNode:
			f := in.eval(n.fn, env)
			args := make([]Value, len(n.args))
			for i, a := range n.args {
				args[i] = in.eval(a, env)
			}
			for {
				switch p := f.(type) {
				case *Closure:
					env = p.bind(args)
					nd = p.lam.body
					continue eval
				case *Primitive:
					if len(args) < p.Min || (p.Max >= 0 && len(args) > p.Max) {
						Raise(ErrArity)
					}
					if p.isApply {
						f, args = spreadApply(args)
						continue // apply's call is a tail call
					}
					return p.Fn(in, args)
				default:
					Raise(ErrType)
				}
			}

		default:
			panic("scheme: unknown node type")
		}
	}
}

// bind creates the call frame for applying closure c to args.
func (c *Closure) bind(args []Value) *Env {
	lam := c.lam
	if len(args) < lam.nreq || (!lam.rest && len(args) > lam.nreq) {
		Raise(ErrArity)
	}
	if lam.rest {
		var rest Value = Nil
		for i := len(args) - 1; i >= lam.nreq; i-- {
			rest = &Pair{args[i], rest}
		}
		vals := make([]Value, lam.nreq+1)
		copy(vals, args)
		vals[lam.nreq] = rest
		args = vals
	}
	return &Env{parent: c.env, syms: lam.all, vals: args}
}

// spreadApply turns the arguments (f a ... lst) of apply into f and the
// argument vector (a ... elements-of-lst).
func spreadApply(args []Value) (Value, []Value) {
	f := args[0]
	last := args[len(args)-1]
	rest, ok := ListToSlice(last)
	if !ok {
		Raise(ErrType)
	}
	out := make([]Value, 0, len(args)-2+len(rest))
	out = append(out, args[1:len(args)-1]...)
	out = append(out, rest...)
	return f, out
}
