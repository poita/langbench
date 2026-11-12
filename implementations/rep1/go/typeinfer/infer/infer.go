// Package infer implements Hindley-Milner type inference (Algorithm J with
// level-based generalisation) for the language parsed by package syntax.
//
// An [Inferer] holds the top-level environment. Feed it declarations in
// order with [Inferer.Infer]; a declaration that fails leaves the environment
// untouched.
package infer

import (
	"github.com/example/typeinfer/syntax"
	"github.com/example/typeinfer/types"
)

// Result is the outcome of inferring one declaration.
type Result struct {
	// Name is the declared name, or "" for a bare expression.
	Name string
	// Scheme is the principal type of the declaration.
	Scheme *types.Scheme
}

// Inferer infers the types of a sequence of declarations. The zero value is
// not usable; create one with [New]. It is not safe for concurrent use.
type Inferer struct {
	ctx *types.Context
	env *env
}

// New returns an Inferer whose environment holds the built-in functions
// (not, fst, snd, hd, tl, null, length, map and fold).
func New() *Inferer {
	in := &Inferer{ctx: types.NewContext(), env: newEnv()}
	for name, s := range builtins(in.ctx) {
		in.env.push(name, s)
	}
	in.env.commit(0)
	return in
}

// Infer infers the type of a declaration in the current environment. If it is
// a let or let rec declaration and succeeds, its generalised binding is added
// to the environment. On failure the environment is unchanged and the error is
// an *[Error].
func (in *Inferer) Infer(d syntax.Decl) (res Result, err error) {
	mark := in.env.mark()
	defer func() {
		if r := recover(); r != nil {
			e, ok := r.(*Error)
			if !ok {
				panic(r)
			}
			in.env.unwind(mark)
			res, err = Result{}, e
		}
	}()
	c := in.ctx
	c.EnterLevel()
	var t *types.Type
	switch {
	case d.Rec:
		t = in.inferRec(d.Name, d.Expr.(*syntax.Lam))
	default:
		t = in.infer(d.Expr)
	}
	c.LeaveLevel()
	s := c.Generalize(t)
	if d.IsBinding() {
		in.env.push(d.Name, s)
		in.env.commit(mark)
	}
	return Result{Name: d.Name, Scheme: s}, nil
}

// fail aborts inference of the current declaration.
func fail(kind ErrorKind, name string) { panic(&Error{Kind: kind, Name: name}) }

// unify unifies a and b or aborts with the corresponding error.
func (in *Inferer) unify(a, b *types.Type) {
	switch err := in.ctx.Unify(a, b); err {
	case nil:
	case types.ErrOccurs:
		fail(Occurs, "")
	default:
		fail(Unify, "")
	}
}

// inferRec infers let rec name = lam, returning the type of lam. The name is
// bound monomorphically while the function is inferred, and unbound again on
// return.
func (in *Inferer) inferRec(name string, lam *syntax.Lam) *types.Type {
	mark := in.env.mark()
	tf := in.ctx.NewVar()
	in.env.push(name, types.Mono(tf))
	t := in.infer(lam)
	in.env.unwind(mark)
	in.unify(tf, t)
	return tf
}

func (in *Inferer) infer(e syntax.Expr) *types.Type {
	c := in.ctx
	switch e := e.(type) {
	case *syntax.IntLit:
		return types.Int
	case *syntax.BoolLit:
		return types.Bool
	case *syntax.UnitLit:
		return types.Unit
	case *syntax.Var:
		s := in.env.lookup(e.Name)
		if s == nil {
			fail(Unbound, e.Name)
		}
		return c.Instantiate(s)
	case *syntax.Lam:
		mark := in.env.mark()
		tp := c.NewVar()
		in.env.push(e.Param, types.Mono(tp))
		body := in.infer(e.Body)
		in.env.unwind(mark)
		return types.Arrow(tp, body)
	case *syntax.App:
		tf := in.infer(e.Fn)
		ta := in.infer(e.Arg)
		tr := c.NewVar()
		in.unify(tf, types.Arrow(ta, tr))
		return tr
	case *syntax.Let:
		return in.inferLet(e)
	case *syntax.If:
		in.unify(in.infer(e.Cond), types.Bool)
		ta := in.infer(e.Then)
		tb := in.infer(e.Else)
		in.unify(ta, tb)
		return ta
	case *syntax.Tuple:
		ts := make([]*types.Type, len(e.Elems))
		for i, x := range e.Elems {
			ts[i] = in.infer(x)
		}
		return types.Tuple(ts)
	case *syntax.List:
		elem := c.NewVar()
		for _, x := range e.Elems {
			in.unify(elem, in.infer(x))
		}
		return types.List(elem)
	case *syntax.Cons:
		th := in.infer(e.Head)
		tt := in.infer(e.Tail)
		l := types.List(th)
		in.unify(tt, l)
		return l
	case *syntax.BinOp:
		var operand, result *types.Type
		switch e.Op {
		case syntax.OpAdd, syntax.OpSub, syntax.OpMul, syntax.OpDiv:
			operand, result = types.Int, types.Int
		case syntax.OpAnd, syntax.OpOr:
			operand, result = types.Bool, types.Bool
		default:
			operand, result = types.Int, types.Bool
		}
		in.unify(in.infer(e.L), operand)
		in.unify(in.infer(e.R), operand)
		return result
	}
	panic("infer: unknown expression node")
}

// inferLet infers let [rec] name = value in body. The right-hand side is
// inferred one level deeper so that its variables can be generalised.
func (in *Inferer) inferLet(e *syntax.Let) *types.Type {
	c := in.ctx
	c.EnterLevel()
	var tv *types.Type
	if e.Rec {
		tv = in.inferRec(e.Name, e.Value.(*syntax.Lam))
	} else {
		tv = in.infer(e.Value)
	}
	c.LeaveLevel()
	mark := in.env.mark()
	in.env.push(e.Name, c.Generalize(tv))
	body := in.infer(e.Body)
	in.env.unwind(mark)
	return body
}
