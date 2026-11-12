package check

import (
	"langvm/ast"
	"langvm/diag"
	"langvm/types"
)

// fnCtx is the state of checking one function body (or lambda body).
type fnCtx struct {
	c          *checker
	mod        *modInfo
	tc         *tctx
	parent     *fnCtx
	body       *types.Body
	ret        *types.Type
	retUnknown bool
	scopes     []map[string]*types.Local
	loops      int
}

func (fc *fnCtx) fail(k diag.Kind, pos diag.Pos) { fc.c.fail(k, pos) }

func (fc *fnCtx) pushScope() { fc.scopes = append(fc.scopes, map[string]*types.Local{}) }
func (fc *fnCtx) popScope()  { fc.scopes = fc.scopes[:len(fc.scopes)-1] }

func (fc *fnCtx) declare(l *types.Local) {
	fc.scopes[len(fc.scopes)-1][l.Name] = l
}

func (fc *fnCtx) newLocal(name string, t *types.Type, mutable bool) *types.Local {
	return &types.Local{Name: name, Type: t, Mutable: mutable, Owner: fc.body}
}

// findLocal looks a name up in the current function and then in enclosing
// functions, without recording a capture.
func (fc *fnCtx) findLocal(name string) *types.Local {
	for f := fc; f != nil; f = f.parent {
		for i := len(f.scopes) - 1; i >= 0; i-- {
			if l, ok := f.scopes[i][name]; ok {
				return l
			}
		}
	}
	return nil
}

// useLocal records that l is read in this function, capturing it in every
// lambda between here and the function that owns it.
func (fc *fnCtx) useLocal(l *types.Local) {
	for f := fc; f != nil && f.body != l.Owner; f = f.parent {
		found := false
		for _, c := range f.body.Captures {
			if c == l {
				found = true
				break
			}
		}
		if !found {
			f.body.Captures = append(f.body.Captures, l)
		}
	}
}

func (c *checker) pushVars() { c.varScopes = append(c.varScopes, nil) }

func (c *checker) popVars() []*types.Type {
	n := len(c.varScopes) - 1
	vs := c.varScopes[n]
	c.varScopes = c.varScopes[:n]
	return vs
}

func (c *checker) newVar() *types.Type {
	c.nextVar++
	v := &types.Type{Kind: types.KVar, ID: c.nextVar}
	if n := len(c.varScopes); n > 0 {
		c.varScopes[n-1] = append(c.varScopes[n-1], v)
	}
	return v
}

func rs(t *types.Type) *types.Type { return types.Resolve(t) }

// checkFunc checks a function, method or default body.
func (c *checker) checkFunc(m *modInfo, f *types.Func, pos diag.Pos, params []*ast.Param, body *ast.Block,
	self *types.Type, tparams []*types.TypeParam, isMethod bool) {
	tc := &tctx{mod: m, tparams: map[string]*types.TypeParam{}, self: self}
	for _, p := range tparams {
		tc.tparams[p.Name] = p
	}
	fc := &fnCtx{c: c, mod: m, tc: tc, ret: f.Ret}
	fc.body = &types.Body{}
	f.Body = fc.body
	fc.pushScope()
	off := 0
	if isMethod {
		l := fc.newLocal("self", f.Params[0], false)
		fc.declare(l)
		fc.body.Params = append(fc.body.Params, l)
		off = 1
	}
	for i, p := range params {
		l := fc.newLocal(p.Name.Name, f.Params[off+i], false)
		fc.declare(l)
		fc.body.Params = append(fc.body.Params, l)
	}
	fc.funcBody(body, f.Ret, pos)
}

// funcBody checks a function-like body against its return type (11.6).
func (fc *fnCtx) funcBody(b *ast.Block, ret *types.Type, fnPos diag.Pos) {
	for _, s := range b.Stmts {
		fc.stmt(s)
	}
	if b.Trailing != nil {
		fc.check(b.Trailing, ret)
		return
	}
	if rs(ret).Kind != types.KUnit && !b.Diverges() {
		fc.fail(diag.MissingReturn, fnPos)
	}
}

// ---------------------------------------------------------------- statements

func (fc *fnCtx) stmt(s ast.Stmt) {
	switch s := s.(type) {
	case *ast.LetStmt:
		var t *types.Type
		if s.Type != nil {
			t = fc.c.resolveType(fc.tc, s.Type)
			fc.check(s.Init, t)
		} else {
			t = fc.infer(s.Init)
		}
		bs := newBinds()
		fc.pattern(s.Pat, t, bs)
		if !irrefutable(s.Pat) {
			fc.fail(diag.RefutablePattern, s.Pat.PatPos())
		}
		fc.declareBinds(bs)
	case *ast.VarStmt:
		var t *types.Type
		if s.Type != nil {
			t = fc.c.resolveType(fc.tc, s.Type)
			fc.check(s.Init, t)
		} else {
			t = fc.infer(s.Init)
		}
		l := fc.newLocal(s.Name.Name, t, true)
		s.Local = l
		fc.declare(l)
	case *ast.AssignStmt:
		fc.assign(s)
	case *ast.ExprStmt:
		fc.infer(s.X)
	case *ast.ReturnStmt:
		fc.returnStmt(s)
	case *ast.WhileStmt:
		fc.check(s.Cond, types.Bool)
		fc.loops++
		fc.stmtBlock(s.Body)
		fc.loops--
	case *ast.ForStmt:
		fc.forStmt(s)
	case *ast.BreakStmt:
		if fc.loops == 0 {
			fc.fail(diag.BreakOutside, s.Pos)
		}
	case *ast.ContinueStmt:
		if fc.loops == 0 {
			fc.fail(diag.BreakOutside, s.Pos)
		}
	}
}

// stmtBlock checks a statement block (loop body): the trailing expression is
// synthesised and discarded.
func (fc *fnCtx) stmtBlock(b *ast.Block) {
	fc.pushScope()
	for _, s := range b.Stmts {
		fc.stmt(s)
	}
	if b.Trailing != nil {
		fc.infer(b.Trailing)
	}
	fc.popScope()
}

func (fc *fnCtx) returnStmt(s *ast.ReturnStmt) {
	if fc.retUnknown {
		fc.fail(diag.CannotInfer, s.Pos)
	}
	ret := rs(fc.ret)
	if s.X == nil {
		if !types.Unify(ret, types.Unit) {
			fc.fail(diag.TypeMismatch, s.Pos)
		}
		return
	}
	if ret.Kind == types.KUnit {
		t := fc.infer(s.X)
		if rs(t).Kind != types.KUnit {
			fc.fail(diag.TypeMismatch, s.Pos)
		}
		return
	}
	fc.check(s.X, ret)
}

func (fc *fnCtx) forStmt(s *ast.ForStmt) {
	var elem *types.Type
	if s.End != nil {
		fc.check(s.Iter, types.Int)
		fc.check(s.End, types.Int)
		elem = types.Int
	} else {
		t := rs(fc.infer(s.Iter))
		switch t.Kind {
		case types.KList:
			elem = t.Args[0]
		case types.KStr:
			elem = types.Char
		default:
			fc.fail(diag.NotIterable, s.Iter.ExprPos())
		}
	}
	bs := newBinds()
	fc.pattern(s.Pat, elem, bs)
	if !irrefutable(s.Pat) {
		fc.fail(diag.RefutablePattern, s.Pat.PatPos())
	}
	fc.pushScope()
	fc.declareBinds(bs)
	fc.loops++
	fc.stmtBlock(s.Body)
	fc.loops--
	fc.popScope()
}

func (fc *fnCtx) assign(s *ast.AssignStmt) {
	switch t := s.Target.(type) {
	case *ast.PathExpr:
		if t.Qual != nil {
			fc.fail(diag.BadTarget, t.Pos)
		}
		l := fc.findLocal(t.Name.Name)
		if l == nil {
			fc.fail(diag.UnknownName, t.Name.Pos)
		}
		if !l.Mutable {
			fc.fail(diag.AssignImmutable, t.Name.Pos)
		}
		if l.Owner != fc.body {
			fc.fail(diag.AssignCaptured, t.Name.Pos)
		}
		t.Kind = ast.RefLocal
		t.Local = l
		s.Local = l
		fc.check(s.Value, l.Type)
	case *ast.IndexExpr:
		a := rs(fc.infer(t.X))
		switch a.Kind {
		case types.KList:
			fc.check(t.I, types.Int)
			fc.check(s.Value, a.Args[0])
		case types.KMap:
			fc.check(t.I, a.Args[0])
			fc.check(s.Value, a.Args[1])
		default:
			fc.fail(diag.BadTarget, t.X.ExprPos())
		}
	default:
		fc.fail(diag.BadTarget, s.Target.ExprPos())
	}
}
