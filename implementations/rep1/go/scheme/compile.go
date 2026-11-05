package scheme

type nodeKind uint8

const (
	nConst nodeKind = iota
	nVar
	nIf
	nDefine
	nSet
	nLambda
	nLet
	nNamedLet
	nLetStar
	nLetrec
	nBegin
	nCond
	nAnd
	nOr
	nApp
)

// node is a pre-analysed expression. Which fields are used depends on kind.
type node struct {
	kind    nodeKind
	id      int32   // nVar, nDefine, nSet: symbol id
	val     Value   // nConst
	a, b, c *node   // nIf: test/then/else; nDefine/nSet: a = expr; let family: a = body
	list    []*node // nBegin/nAnd/nOr: forms; nApp: operator then operands; let family: inits
	names   []int32 // let family: bound ids (capacity == length)
	proc    *procDesc
	clauses []clause
}

type clause struct {
	test *node // nil for else
	body *node // nil for a (test) clause
}

// procDesc is the shared descriptor of a lambda, procedure define or named
// let: parameter ids, rest flag and the compiled body.
type procDesc struct {
	params []int32 // required parameters, then the rest parameter if any
	nreq   int
	rest   bool
	body   *node
}

// compile converts a datum into a node tree. It never evaluates anything.
func (in *Interp) compile(x Value) *node {
	switch x.t {
	case tSym:
		return &node{kind: nVar, id: int32(x.n)}
	case tPair:
		p := x.pair()
		if p.car.t == tSym && p.car.n < int64(numSpecialSyms) && int32(p.car.n) != symElse {
			return in.compileSpecial(int32(p.car.n), p.cdr)
		}
		items := listItems(x)
		list := make([]*node, len(items))
		for i, it := range items {
			list[i] = in.compile(it)
		}
		return &node{kind: nApp, list: list}
	}
	return &node{kind: nConst, val: x}
}

// listItems returns the elements of a (proper or dotted) list; a malformed
// non-list is a syntax error.
func listItems(v Value) []Value {
	var out []Value
	for v.t == tPair {
		p := v.pair()
		out = append(out, p.car)
		v = p.cdr
	}
	if v.t != tNil {
		throw(ErrSyntax)
	}
	return out
}

func (in *Interp) compileSpecial(sym int32, rest Value) *node {
	args := listItems(rest)
	need := func(n int) {
		if len(args) < n {
			throw(ErrSyntax)
		}
	}
	switch sym {
	case symQuote:
		need(1)
		return &node{kind: nConst, val: args[0]}
	case symIf:
		need(2)
		n := &node{kind: nIf, a: in.compile(args[0]), b: in.compile(args[1])}
		if len(args) > 2 {
			n.c = in.compile(args[2])
		}
		return n
	case symDefine:
		need(2)
		target := args[0]
		if target.t == tPair {
			tp := target.pair()
			if tp.car.t != tSym {
				throw(ErrSyntax)
			}
			lam := in.compileProc(tp.cdr, args[1:])
			return &node{kind: nDefine, id: int32(tp.car.n), a: &node{kind: nLambda, proc: lam}}
		}
		if target.t != tSym {
			throw(ErrSyntax)
		}
		return &node{kind: nDefine, id: int32(target.n), a: in.compile(args[1])}
	case symSet:
		need(2)
		if args[0].t != tSym {
			throw(ErrSyntax)
		}
		return &node{kind: nSet, id: int32(args[0].n), a: in.compile(args[1])}
	case symLambda:
		need(2)
		return &node{kind: nLambda, proc: in.compileProc(args[0], args[1:])}
	case symLet:
		need(2)
		if args[0].t == tSym { // named let
			names, inits := in.compileBindings(args[1])
			// The loop name lives in a frame of its own: a one-slot id list.
			nameSlot := []int32{int32(args[0].n)}
			params := make([]int32, len(names))
			copy(params, names)
			desc := &procDesc{params: params[:len(params):len(params)], nreq: len(params),
				body: in.compileBody(args[2:])}
			return &node{kind: nNamedLet, names: nameSlot[:1:1], list: inits, proc: desc}
		}
		names, inits := in.compileBindings(args[0])
		return &node{kind: nLet, names: names, list: inits, a: in.compileBody(args[1:])}
	case symLetStar:
		need(2)
		names, inits := in.compileBindings(args[0])
		return &node{kind: nLetStar, names: names, list: inits, a: in.compileBody(args[1:])}
	case symLetrec:
		need(2)
		names, inits := in.compileBindings(args[0])
		return &node{kind: nLetrec, names: names, list: inits, a: in.compileBody(args[1:])}
	case symBegin:
		need(1)
		return in.compileBody(args)
	case symCond:
		n := &node{kind: nCond}
		for _, cl := range args {
			parts := listItems(cl)
			if len(parts) == 0 {
				throw(ErrSyntax)
			}
			var c clause
			if parts[0].t == tSym && int32(parts[0].n) == symElse {
				c.body = in.compileBody(parts[1:])
			} else {
				c.test = in.compile(parts[0])
				if len(parts) > 1 {
					c.body = in.compileBody(parts[1:])
				}
			}
			n.clauses = append(n.clauses, c)
		}
		return n
	case symAnd, symOr:
		list := make([]*node, len(args))
		for i, a := range args {
			list[i] = in.compile(a)
		}
		k := nAnd
		if sym == symOr {
			k = nOr
		}
		return &node{kind: k, list: list}
	}
	throw(ErrSyntax)
	return nil
}

// compileBody compiles a non-empty sequence; a single form is returned as is.
func (in *Interp) compileBody(forms []Value) *node {
	if len(forms) == 0 {
		throw(ErrSyntax)
	}
	if len(forms) == 1 {
		return in.compile(forms[0])
	}
	list := make([]*node, len(forms))
	for i, f := range forms {
		list[i] = in.compile(f)
	}
	return &node{kind: nBegin, list: list}
}

// compileBindings splits ((v init) ...) into ids and compiled inits.
func (in *Interp) compileBindings(bs Value) (names []int32, inits []*node) {
	for _, b := range listItems(bs) {
		parts := listItems(b)
		if len(parts) != 2 || parts[0].t != tSym {
			throw(ErrSyntax)
		}
		names = append(names, int32(parts[0].n))
		inits = append(inits, in.compile(parts[1]))
	}
	return names[:len(names):len(names)], inits
}

// compileProc builds a descriptor from a parameter spec and body forms.
func (in *Interp) compileProc(params Value, body []Value) *procDesc {
	d := &procDesc{}
	for params.t == tPair {
		p := params.pair()
		if p.car.t != tSym {
			throw(ErrSyntax)
		}
		d.params = append(d.params, int32(p.car.n))
		params = p.cdr
	}
	d.nreq = len(d.params)
	switch params.t {
	case tNil:
	case tSym:
		d.params = append(d.params, int32(params.n))
		d.rest = true
	default:
		throw(ErrSyntax)
	}
	d.params = d.params[:len(d.params):len(d.params)]
	d.body = in.compileBody(body)
	return d
}
