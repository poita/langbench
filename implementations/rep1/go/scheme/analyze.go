package scheme

// The analyser turns a datum into a tree of nodes, once, before it is
// evaluated. Evaluation never looks at raw s-expressions again.

type node interface{}

type (
	constNode  struct{ v Value }
	refNode    struct{ sym *Symbol }
	ifNode     struct{ test, then, els node } // els == nil: one-armed if
	defineNode struct {
		sym  *Symbol
		expr node
	}
	setNode struct {
		sym  *Symbol
		expr node
	}
	lambdaNode struct {
		nreq int       // number of required parameters
		rest bool      // whether a rest parameter follows the required ones
		all  []*Symbol // required parameters then the rest parameter; len == cap
		body node
	}
	seqNode  struct{ nodes []node } // at least two nodes
	callNode struct {
		fn   node
		args []node
	}
	letNode struct {
		syms  []*Symbol // len == cap
		inits []node
		body  node
	}
	namedLetNode struct {
		name  *Symbol
		lam   *lambdaNode
		inits []node
	}
	letrecNode struct {
		syms  []*Symbol
		inits []node
		body  node
	}
	condClause struct {
		test node // nil for else
		body node // nil for a bare (test) clause
	}
	condNode struct{ clauses []condClause }
	andNode  struct{ nodes []node }
	orNode   struct{ nodes []node }
)

var (
	symQuote   = Intern("quote")
	symIf      = Intern("if")
	symDefine  = Intern("define")
	symSet     = Intern("set!")
	symLambda  = Intern("lambda")
	symLet     = Intern("let")
	symLetStar = Intern("let*")
	symLetrec  = Intern("letrec")
	symBegin   = Intern("begin")
	symCond    = Intern("cond")
	symAnd     = Intern("and")
	symOr      = Intern("or")
	symElse    = Intern("else")
)

func analyze(x Value) node {
	switch x := x.(type) {
	case *Symbol:
		return &refNode{x}
	case *Pair:
		if head, ok := x.Car.(*Symbol); ok {
			switch head {
			case symQuote:
				args := formArgs(x, 1, 1)
				return &constNode{args[0]}
			case symIf:
				args := formArgs(x, 2, 3)
				n := &ifNode{test: analyze(args[0]), then: analyze(args[1])}
				if len(args) == 3 {
					n.els = analyze(args[2])
				}
				return n
			case symDefine:
				return analyzeDefine(x)
			case symSet:
				args := formArgs(x, 2, 2)
				return &setNode{symbolOf(args[0]), analyze(args[1])}
			case symLambda:
				args := formArgs(x, 2, -1)
				return analyzeLambda(args[0], args[1:])
			case symLet:
				return analyzeLet(x)
			case symLetStar:
				return analyzeLetStar(x)
			case symLetrec:
				args := formArgs(x, 2, -1)
				syms, inits := analyzeBindings(args[0])
				return &letrecNode{syms, inits, analyzeBody(args[1:])}
			case symBegin:
				args := formArgs(x, 0, -1)
				if len(args) == 0 {
					return &constNode{Unspecified}
				}
				return analyzeBody(args)
			case symCond:
				return analyzeCond(x)
			case symAnd:
				return &andNode{analyzeAll(formArgs(x, 0, -1))}
			case symOr:
				return &orNode{analyzeAll(formArgs(x, 0, -1))}
			}
		}
		fn := analyze(x.Car)
		args, ok := ListToSlice(x.Cdr)
		if !ok {
			syntaxError("improper application")
		}
		return &callNode{fn, analyzeAll(args)}
	}
	return &constNode{x}
}

// formArgs returns the operands of the special form x, checking that there
// are between min and max of them (max < 0: no upper bound).
func formArgs(x *Pair, min, max int) []Value {
	args, ok := ListToSlice(x.Cdr)
	if !ok || len(args) < min || (max >= 0 && len(args) > max) {
		syntaxError("malformed " + Write(x.Car) + " form")
	}
	return args
}

func symbolOf(v Value) *Symbol {
	s, ok := v.(*Symbol)
	if !ok {
		syntaxError("expected an identifier, got " + Write(v))
	}
	return s
}

func analyzeAll(xs []Value) []node {
	out := make([]node, len(xs))
	for i, x := range xs {
		out[i] = analyze(x)
	}
	return out
}

// analyzeBody analyses a non-empty sequence of forms.
func analyzeBody(forms []Value) node {
	if len(forms) == 0 {
		syntaxError("empty body")
	}
	if len(forms) == 1 {
		return analyze(forms[0])
	}
	return &seqNode{analyzeAll(forms)}
}

func analyzeDefine(x *Pair) node {
	args := formArgs(x, 2, -1)
	switch target := args[0].(type) {
	case *Symbol:
		if len(args) != 2 {
			syntaxError("malformed define")
		}
		return &defineNode{target, analyze(args[1])}
	case *Pair:
		name := symbolOf(target.Car)
		return &defineNode{name, analyzeLambda(target.Cdr, args[1:])}
	}
	syntaxError("malformed define")
	return nil
}

func analyzeLambda(params Value, body []Value) *lambdaNode {
	lam := &lambdaNode{}
	var all []*Symbol
	for {
		switch p := params.(type) {
		case Null:
			lam.all = all[:len(all):len(all)]
			lam.body = analyzeBody(body)
			return lam
		case *Symbol:
			all = append(all, p)
			lam.rest = true
			lam.all = all[:len(all):len(all)]
			lam.body = analyzeBody(body)
			return lam
		case *Pair:
			all = append(all, symbolOf(p.Car))
			lam.nreq++
			params = p.Cdr
		default:
			syntaxError("malformed parameter list")
		}
	}
}

// analyzeBindings parses ((v init) ...).
func analyzeBindings(bs Value) ([]*Symbol, []node) {
	list, ok := ListToSlice(bs)
	if !ok {
		syntaxError("malformed binding list")
	}
	syms := make([]*Symbol, len(list))
	inits := make([]node, len(list))
	for i, b := range list {
		parts, ok := ListToSlice(b)
		if !ok || len(parts) != 2 {
			syntaxError("malformed binding")
		}
		syms[i] = symbolOf(parts[0])
		inits[i] = analyze(parts[1])
	}
	return syms[:len(syms):len(syms)], inits
}

func analyzeLet(x *Pair) node {
	args := formArgs(x, 2, -1)
	if name, ok := args[0].(*Symbol); ok { // named let
		if len(args) < 3 {
			syntaxError("malformed named let")
		}
		syms, inits := analyzeBindings(args[1])
		lam := &lambdaNode{nreq: len(syms), all: syms, body: analyzeBody(args[2:])}
		return &namedLetNode{name, lam, inits}
	}
	syms, inits := analyzeBindings(args[0])
	return &letNode{syms, inits, analyzeBody(args[1:])}
}

// analyzeLetStar builds one single-binding let per binding, innermost last.
func analyzeLetStar(x *Pair) node {
	args := formArgs(x, 2, -1)
	syms, inits := analyzeBindings(args[0])
	body := analyzeBody(args[1:])
	if len(syms) == 0 {
		return &letNode{syms, nil, body}
	}
	for i := len(syms) - 1; i >= 0; i-- {
		body = &letNode{syms[i : i+1 : i+1], inits[i : i+1], body}
	}
	return body
}

func analyzeCond(x *Pair) node {
	args := formArgs(x, 0, -1)
	n := &condNode{}
	for i, c := range args {
		parts, ok := ListToSlice(c)
		if !ok || len(parts) == 0 {
			syntaxError("malformed cond clause")
		}
		var cl condClause
		if parts[0] == Value(symElse) {
			if i != len(args)-1 || len(parts) < 2 {
				syntaxError("malformed else clause")
			}
			cl.body = analyzeBody(parts[1:])
		} else {
			cl.test = analyze(parts[0])
			if len(parts) > 1 {
				cl.body = analyzeBody(parts[1:])
			}
		}
		n.clauses = append(n.clauses, cl)
	}
	return n
}
