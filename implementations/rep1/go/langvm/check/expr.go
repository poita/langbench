package check

import (
	"langvm/ast"
	"langvm/diag"
	"langvm/types"
)

// ---------------------------------------------------------------- paths

type resKind uint8

const (
	resLocal resKind = iota
	resFunc
	resVariant
	resTraitMethod
	resType
)

type valueRes struct {
	kind    resKind
	local   *types.Local
	fn      *types.Func
	variant *types.Variant
	trait   *types.Trait
	method  int
}

func (fc *fnCtx) lookupValue(name string) (valEntry, bool) {
	if e, ok := fc.mod.valuesNS[name]; ok {
		return e, true
	}
	e, ok := fc.c.preludeValues[name]
	return e, ok
}

func (fc *fnCtx) isTypeName(name string) bool {
	if _, ok := fc.mod.typesNS[name]; ok {
		return true
	}
	if _, ok := primTypes[name]; ok {
		return true
	}
	switch name {
	case "Option", "Result", "Self":
		return true
	}
	return false
}

func entryRes(e valEntry) valueRes {
	if e.fn != nil {
		return valueRes{kind: resFunc, fn: e.fn}
	}
	return valueRes{kind: resVariant, variant: e.variant}
}

// resolvePath resolves a value path (section 5.4 and 10.2). With allowLocal
// an unqualified name is looked up among local bindings first.
func (fc *fnCtx) resolvePath(p *ast.PathExpr, allowLocal bool) valueRes {
	name := p.Name.Name
	if p.Qual == nil {
		if allowLocal {
			if l := fc.findLocal(name); l != nil {
				fc.useLocal(l)
				return valueRes{kind: resLocal, local: l}
			}
		}
		if e, ok := fc.lookupValue(name); ok {
			return entryRes(e)
		}
		if fc.isTypeName(name) {
			return valueRes{kind: resType}
		}
		fc.fail(diag.UnknownName, p.Name.Pos)
	}
	im := fc.mod.imports[p.Qual.Name]
	if im != nil {
		e, ok := im.valuesNS[name]
		if !ok {
			fc.fail(diag.UnknownName, p.Name.Pos)
		}
		pub := false
		if e.fn != nil {
			pub = e.fn.Pub
		} else {
			pub = e.variant.Decl.Pub
		}
		if !pub && im != fc.mod {
			fc.fail(diag.NotPublic, p.Name.Pos)
		}
		return entryRes(e)
	}
	if tr := fc.c.visibleTraitByName(fc.mod, p.Qual.Name); tr != nil {
		mi := tr.MethodIndex(name)
		if mi < 0 {
			fc.fail(diag.UnknownName, p.Name.Pos)
		}
		return valueRes{kind: resTraitMethod, trait: tr, method: mi}
	}
	fc.fail(diag.UnknownModule, p.Qual.Pos)
	return valueRes{}
}

// identVariant returns the 0-payload variant a bare identifier pattern
// names, or nil when it is a binding.
func (fc *fnCtx) identVariant(name string) *types.Variant {
	e, ok := fc.lookupValue(name)
	if ok && e.variant != nil && len(e.variant.Payload) == 0 {
		return e.variant
	}
	return nil
}

// ---------------------------------------------------------------- infer

func (fc *fnCtx) mismatch(pos diag.Pos) { fc.fail(diag.TypeMismatch, pos) }

func (fc *fnCtx) infer(e ast.Expr) *types.Type {
	switch e := e.(type) {
	case *ast.IntLit:
		return types.Int
	case *ast.FloatLit:
		return types.Float
	case *ast.StrLit:
		return types.Str
	case *ast.CharLit:
		return types.Char
	case *ast.BoolLit:
		return types.Bool
	case *ast.SelfExpr:
		l := fc.findLocal("self")
		if l == nil {
			fc.fail(diag.SelfOutside, e.Pos)
		}
		fc.useLocal(l)
		e.Local = l
		return l.Type
	case *ast.PathExpr:
		return fc.pathValue(e, nil)
	case *ast.UnaryExpr:
		return fc.unary(e)
	case *ast.BinaryExpr:
		return fc.binary(e)
	case *ast.CallExpr:
		t, _ := fc.callExpr(e, nil)
		return t
	case *ast.MethodCallExpr:
		return fc.methodCall(e)
	case *ast.IndexExpr:
		return fc.index(e)
	case *ast.FieldExpr:
		return fc.field(e)
	case *ast.StructLit:
		return fc.structLit(e, nil)
	case *ast.ListLit:
		if len(e.Elems) == 0 {
			fc.fail(diag.CannotInfer, e.Pos)
		}
		t := fc.infer(e.Elems[0])
		for _, x := range e.Elems[1:] {
			fc.check(x, t)
		}
		return types.NewList(t)
	case *ast.MapLit:
		if len(e.Entries) == 0 {
			fc.fail(diag.CannotInfer, e.Pos)
		}
		k := fc.infer(e.Entries[0].K)
		if !fc.c.isKey(k) {
			fc.fail(diag.BadKeyType, e.Entries[0].K.ExprPos())
		}
		v := fc.infer(e.Entries[0].V)
		for _, en := range e.Entries[1:] {
			fc.check(en.K, k)
			fc.check(en.V, v)
		}
		return types.NewMap(k, v)
	case *ast.TupleLit:
		if len(e.Elems) > 8 {
			fc.fail(diag.BadArity, e.Pos)
		}
		ps := make([]*types.Type, len(e.Elems))
		for i, x := range e.Elems {
			ps[i] = fc.infer(x)
		}
		return types.NewTuple(ps)
	case *ast.Lambda:
		return fc.lambda(e, nil)
	case *ast.IfExpr:
		return fc.ifExpr(e, nil)
	case *ast.MatchExpr:
		return fc.matchExpr(e, nil)
	case *ast.Block:
		return fc.inferBlock(e)
	}
	panic("unhandled expression")
}

func (fc *fnCtx) pathValue(e *ast.PathExpr, want *types.Type) *types.Type {
	res := fc.resolvePath(e, true)
	switch res.kind {
	case resLocal:
		e.Kind = ast.RefLocal
		e.Local = res.local
		return res.local.Type
	case resVariant:
		if len(res.variant.Payload) == 0 {
			e.Kind = ast.RefVariant
			e.Variant = res.variant
			return fc.genericCall(e.Pos, res.variant.Decl.TParams, nil, variantRet(res.variant), nil, want)
		}
	}
	fc.fail(diag.BadValueRef, e.Name.Pos)
	return nil
}

func variantRet(v *types.Variant) *types.Type {
	args := make([]*types.Type, len(v.Decl.TParams))
	for i, p := range v.Decl.TParams {
		args[i] = types.NewParam(p)
	}
	return types.NewNamed(v.Decl, args)
}

// ---------------------------------------------------------------- check

func (fc *fnCtx) check(e ast.Expr, want *types.Type) {
	switch e := e.(type) {
	case *ast.ListLit:
		w := rs(want)
		var elem *types.Type
		switch w.Kind {
		case types.KVar:
			elem = fc.c.newVar()
			types.Unify(w, types.NewList(elem))
		case types.KList:
			elem = w.Args[0]
		default:
			fc.mismatch(e.Pos)
		}
		for _, x := range e.Elems {
			fc.check(x, elem)
		}
	case *ast.MapLit:
		w := rs(want)
		var k, v *types.Type
		switch w.Kind {
		case types.KVar:
			k, v = fc.c.newVar(), fc.c.newVar()
			types.Unify(w, types.NewMap(k, v))
		case types.KMap:
			k, v = w.Args[0], w.Args[1]
		default:
			fc.mismatch(e.Pos)
		}
		for _, en := range e.Entries {
			fc.check(en.K, k)
			fc.check(en.V, v)
		}
		if types.Ground(k) && !fc.c.isKey(k) {
			fc.fail(diag.BadKeyType, e.Pos)
		}
	case *ast.TupleLit:
		if len(e.Elems) > 8 {
			fc.fail(diag.BadArity, e.Pos)
		}
		w := rs(want)
		var parts []*types.Type
		switch w.Kind {
		case types.KVar:
			parts = make([]*types.Type, len(e.Elems))
			for i := range parts {
				parts[i] = fc.c.newVar()
			}
			types.Unify(w, types.NewTuple(parts))
		case types.KTuple:
			if len(w.Args) != len(e.Elems) {
				fc.mismatch(e.Pos)
			}
			parts = w.Args
		default:
			fc.mismatch(e.Pos)
		}
		for i, x := range e.Elems {
			fc.check(x, parts[i])
		}
	case *ast.Lambda:
		fc.lambda(e, want)
	case *ast.IfExpr:
		fc.ifExpr(e, want)
	case *ast.MatchExpr:
		fc.matchExpr(e, want)
	case *ast.Block:
		fc.checkBlock(e, want)
	case *ast.CallExpr:
		t, used := fc.callExpr(e, want)
		if !used && !types.Unify(want, t) {
			fc.mismatch(e.Pos)
		}
	case *ast.PathExpr:
		res := fc.resolvePath(e, true)
		if res.kind == resVariant && len(res.variant.Payload) == 0 {
			e.Kind = ast.RefVariant
			e.Variant = res.variant
			fc.genericCall(e.Pos, res.variant.Decl.TParams, nil, variantRet(res.variant), nil, want)
			return
		}
		t := fc.pathFromRes(e, res)
		if !types.Unify(want, t) {
			fc.mismatch(e.Pos)
		}
	case *ast.StructLit:
		fc.structLit(e, want)
	default:
		s := fc.infer(e)
		if !types.Unify(want, s) {
			fc.mismatch(e.ExprPos())
		}
	}
}

func (fc *fnCtx) pathFromRes(e *ast.PathExpr, res valueRes) *types.Type {
	if res.kind == resLocal {
		e.Kind = ast.RefLocal
		e.Local = res.local
		return res.local.Type
	}
	fc.fail(diag.BadValueRef, e.Name.Pos)
	return nil
}

// ---------------------------------------------------------------- blocks

func (fc *fnCtx) inferBlock(b *ast.Block) *types.Type {
	fc.pushScope()
	defer fc.popScope()
	for _, s := range b.Stmts {
		fc.stmt(s)
	}
	if b.Trailing != nil {
		return fc.infer(b.Trailing)
	}
	return types.Unit
}

func (fc *fnCtx) checkBlock(b *ast.Block, want *types.Type) {
	fc.pushScope()
	defer fc.popScope()
	for _, s := range b.Stmts {
		fc.stmt(s)
	}
	if b.Trailing != nil {
		fc.check(b.Trailing, want)
		return
	}
	if b.Diverges() {
		return
	}
	if !types.Unify(want, types.Unit) {
		fc.mismatch(b.Pos)
	}
}

// ---------------------------------------------------------------- operators

func (fc *fnCtx) unary(e *ast.UnaryExpr) *types.Type {
	switch e.Op {
	case "-":
		t := rs(fc.infer(e.X))
		if t.Kind != types.KInt && t.Kind != types.KFloat {
			fc.mismatch(e.X.ExprPos())
		}
		e.Float = t.Kind == types.KFloat
		return t
	case "!":
		fc.check(e.X, types.Bool)
		return types.Bool
	}
	fc.check(e.X, types.Int)
	return types.Int
}

func (fc *fnCtx) binary(e *ast.BinaryExpr) *types.Type {
	switch e.Op {
	case "+", "-", "*", "/", "%":
		l := rs(fc.infer(e.L))
		if l.Kind != types.KInt && l.Kind != types.KFloat {
			fc.mismatch(e.L.ExprPos())
		}
		if e.Op == "%" && l.Kind == types.KFloat {
			fc.mismatch(e.L.ExprPos())
		}
		fc.check(e.R, l)
		e.Float = l.Kind == types.KFloat
		return l
	case "++":
		l := rs(fc.infer(e.L))
		if l.Kind != types.KStr && l.Kind != types.KList {
			fc.mismatch(e.L.ExprPos())
		}
		fc.check(e.R, l)
		e.List = l.Kind == types.KList
		return l
	case "&", "|", "^", "<<", ">>":
		fc.check(e.L, types.Int)
		fc.check(e.R, types.Int)
		return types.Int
	case "<", "<=", ">", ">=":
		l := fc.infer(e.L)
		if !fc.c.isOrd(l) {
			fc.fail(diag.NotOrd, e.L.ExprPos())
		}
		fc.check(e.R, l)
		return types.Bool
	case "==", "!=":
		l := fc.infer(e.L)
		if !fc.c.isEq(l) {
			fc.fail(diag.NotEq, e.L.ExprPos())
		}
		fc.check(e.R, l)
		return types.Bool
	}
	// && ||
	fc.check(e.L, types.Bool)
	fc.check(e.R, types.Bool)
	return types.Bool
}

func (fc *fnCtx) index(e *ast.IndexExpr) *types.Type {
	a := rs(fc.infer(e.X))
	switch a.Kind {
	case types.KList:
		fc.check(e.I, types.Int)
		return a.Args[0]
	case types.KStr:
		fc.check(e.I, types.Int)
		return types.Char
	case types.KMap:
		fc.check(e.I, a.Args[0])
		return a.Args[1]
	}
	fc.fail(diag.NotIndexable, e.X.ExprPos())
	return nil
}

func (fc *fnCtx) field(e *ast.FieldExpr) *types.Type {
	t := rs(fc.infer(e.X))
	if t.Kind != types.KNamed || t.Decl.IsEnum {
		fc.fail(diag.NotStruct, e.X.ExprPos())
	}
	i := t.Decl.FieldIndex(e.Name.Name)
	if i < 0 {
		fc.fail(diag.UnknownField, e.Name.Pos)
	}
	e.Index = i
	return types.Subst(t.Decl.Fields[i].Type, declSubst(t.Decl, t.Args))
}

func declSubst(d *types.Decl, args []*types.Type) map[*types.TypeParam]*types.Type {
	m := make(map[*types.TypeParam]*types.Type, len(args))
	for i, p := range d.TParams {
		m[p] = args[i]
	}
	return m
}

// ---------------------------------------------------------------- struct literals

func (fc *fnCtx) structLit(e *ast.StructLit, want *types.Type) *types.Type {
	decl := fc.c.lookupTypeDecl(fc.mod, e.Path)
	if decl.IsEnum {
		fc.fail(diag.NotStruct, e.Path.Pos)
	}
	e.Decl = decl
	fc.c.pushVars()
	args := make([]*types.Type, len(decl.TParams))
	for i := range args {
		args[i] = fc.c.newVar()
	}
	st := types.NewNamed(decl, args)
	if want != nil {
		if !types.Unify(st, want) {
			fc.mismatch(e.Path.Pos)
		}
	}
	seen := map[string]bool{}
	e.Order = make([]int, len(e.Fields))
	provided := make([]*ast.FieldInit, len(decl.Fields))
	for wi, fi := range e.Fields {
		if seen[fi.Name.Name] {
			fc.fail(diag.DupField, fi.Name.Pos)
		}
		seen[fi.Name.Name] = true
		idx := decl.FieldIndex(fi.Name.Name)
		if idx < 0 {
			fc.fail(diag.UnknownField, fi.Name.Pos)
		}
		e.Order[wi] = idx
		provided[idx] = fi
	}
	sub := declSubst(decl, args)
	for i, f := range decl.Fields {
		if provided[i] == nil {
			fc.fail(diag.MissingField, e.Path.Pos)
		}
		fc.check(provided[i].Value, types.Subst(f.Type, sub))
	}
	vars := fc.c.popVars()
	for _, v := range vars {
		if !types.Ground(v) {
			fc.fail(diag.CannotInfer, e.Path.Pos)
		}
	}
	return st
}

// ---------------------------------------------------------------- calls

// genericCall implements the generic-call rule of section 9.4 for a callee
// whose arity has already been checked. params and args have equal length.
func (fc *fnCtx) genericCall(pos diag.Pos, tparams []*types.TypeParam, params []*types.Type,
	ret *types.Type, args []ast.Expr, expected *types.Type) *types.Type {
	c := fc.c
	c.pushVars()
	sub := make(map[*types.TypeParam]*types.Type, len(tparams))
	for _, p := range tparams {
		sub[p] = c.newVar()
	}
	for i, a := range args {
		fc.check(a, types.Subst(params[i], sub))
	}
	g := types.Subst(ret, sub)
	if expected != nil {
		if !types.Unify(g, expected) {
			fc.mismatch(pos)
		}
	}
	vars := c.popVars()
	for _, v := range vars {
		if !types.Ground(v) {
			fc.fail(diag.CannotInfer, pos)
		}
	}
	for _, p := range tparams {
		for _, b := range p.Bounds {
			if !c.holds(sub[p], b) {
				fc.fail(diag.UnsatisfiedBound, pos)
			}
		}
	}
	return g
}

// callExpr types a call. The boolean reports whether the expected type (if
// any) was used by a generic-call rule, so the caller need not unify again.
func (fc *fnCtx) callExpr(e *ast.CallExpr, expected *types.Type) (*types.Type, bool) {
	if len(e.Args) > 16 {
		fc.fail(diag.BadArity, e.Pos)
	}
	var calleeType *types.Type
	if p, ok := e.Callee.(*ast.PathExpr); ok {
		res := fc.resolvePath(p, true)
		switch res.kind {
		case resFunc:
			f := res.fn
			p.Kind = ast.RefFunc
			p.Func = f
			e.Func = f
			if f.Builtin >= 0 {
				e.Kind = ast.CallBuiltin
			} else {
				e.Kind = ast.CallFunc
			}
			if len(e.Args) != len(f.Params) {
				fc.fail(diag.Arity, e.Pos)
			}
			return fc.genericCall(e.Pos, f.TParams, f.Params, f.Ret, e.Args, expected), true
		case resVariant:
			v := res.variant
			p.Kind = ast.RefVariant
			p.Variant = v
			e.Kind = ast.CallVariant
			e.Variant = v
			if len(e.Args) != len(v.Payload) {
				fc.fail(diag.Arity, e.Pos)
			}
			return fc.genericCall(e.Pos, v.Decl.TParams, v.Payload, variantRet(v), e.Args, expected), true
		case resTraitMethod:
			p.Kind = ast.RefTraitMethod
			p.Trait = res.trait
			p.Method = res.method
			return fc.traitPathCall(e, p, res), false
		case resType:
			fc.fail(diag.BadValueRef, p.Name.Pos)
		case resLocal:
			p.Kind = ast.RefLocal
			p.Local = res.local
			calleeType = res.local.Type
		}
	} else {
		calleeType = fc.infer(e.Callee)
	}
	ft := rs(calleeType)
	if ft.Kind != types.KFunc {
		fc.fail(diag.NotCallable, e.Callee.ExprPos())
	}
	if len(ft.Args) != len(e.Args) {
		fc.fail(diag.Arity, e.Callee.ExprPos())
	}
	for i, a := range e.Args {
		fc.check(a, ft.Args[i])
	}
	e.Kind = ast.CallValue
	return ft.Ret, false
}

// methodBound enforces steps 4 and 5 of section 8.5.
func (fc *fnCtx) methodBound(tr *types.Trait, r *types.Type, pos diag.Pos) {
	r = rs(r)
	if r.Kind == types.KParam {
		if !r.Param.HasBound(tr) {
			fc.fail(diag.UnsatisfiedBound, pos)
		}
		return
	}
	if !fc.c.holds(r, tr) {
		fc.fail(diag.UnsatisfiedBound, pos)
	}
}

func (fc *fnCtx) methodCall(e *ast.MethodCallExpr) *types.Type {
	if len(e.Args) > 16 {
		fc.fail(diag.BadArity, e.Name.Pos)
	}
	r := fc.infer(e.Recv)
	var cand *types.Trait
	n := 0
	for _, t := range fc.c.visibleTraits(fc.mod) {
		if t.MethodIndex(e.Name.Name) >= 0 {
			cand = t
			n++
		}
	}
	if n == 0 {
		fc.fail(diag.NoMethod, e.Name.Pos)
	}
	if n > 1 {
		fc.fail(diag.AmbigMethod, e.Name.Pos)
	}
	mi := cand.MethodIndex(e.Name.Name)
	tm := cand.Methods[mi]
	if len(e.Args) != len(tm.Params) {
		fc.fail(diag.Arity, e.Name.Pos)
	}
	e.Trait, e.Method = cand, mi
	return fc.finishMethod(cand, tm, r, e.Name.Pos, e.Args)
}

func (fc *fnCtx) finishMethod(tr *types.Trait, tm *types.TraitMethod, r *types.Type, pos diag.Pos, args []ast.Expr) *types.Type {
	fc.methodBound(tr, r, pos)
	sub := map[*types.TypeParam]*types.Type{tr.SelfParam: rs(r)}
	for i, a := range args {
		fc.check(a, types.Subst(tm.Params[i], sub))
	}
	return types.Subst(tm.Ret, sub)
}

func (fc *fnCtx) traitPathCall(e *ast.CallExpr, p *ast.PathExpr, res valueRes) *types.Type {
	tr := res.trait
	tm := tr.Methods[res.method]
	if len(e.Args) == 0 || len(e.Args)-1 != len(tm.Params) {
		fc.fail(diag.Arity, p.Name.Pos)
	}
	r := fc.infer(e.Args[0])
	e.Kind = ast.CallMethod
	e.Trait, e.Method = tr, res.method
	return fc.finishMethod(tr, tm, r, p.Name.Pos, e.Args[1:])
}

// ---------------------------------------------------------------- lambdas

func (fc *fnCtx) lambda(l *ast.Lambda, want *types.Type) *types.Type {
	n := len(l.Params)
	var fnT *types.Type
	if want != nil {
		w := rs(want)
		switch {
		case w.Kind == types.KVar:
			ps := make([]*types.Type, n)
			for i := range ps {
				ps[i] = fc.c.newVar()
			}
			ft := types.NewFunc(ps, fc.c.newVar())
			types.Unify(w, ft)
			w = ft
		case w.Kind != types.KFunc || len(w.Args) != n:
			fc.mismatch(l.Pos)
		}
		fnT = w
	}
	ptypes := make([]*types.Type, n)
	for i, p := range l.Params {
		if fnT != nil {
			pt := fnT.Args[i]
			if p.Type != nil {
				ann := fc.c.resolveType(fc.tc, p.Type)
				if !types.Unify(pt, ann) {
					fc.mismatch(p.Type.TypePos())
				}
			} else if rs(pt).Kind == types.KVar {
				fc.fail(diag.CannotInfer, p.Name.Pos)
			}
			ptypes[i] = pt
		} else {
			if p.Type == nil {
				fc.fail(diag.CannotInfer, p.Name.Pos)
			}
			ptypes[i] = fc.c.resolveType(fc.tc, p.Type)
		}
	}
	var ret *types.Type
	known := true
	if fnT != nil {
		ret = fnT.Ret
		if l.Ret != nil {
			ann := fc.c.resolveType(fc.tc, l.Ret)
			if !types.Unify(ret, ann) {
				fc.mismatch(l.Ret.TypePos())
			}
		}
	} else if l.Ret != nil {
		ret = fc.c.resolveType(fc.tc, l.Ret)
	} else {
		known = false
	}
	seen := map[string]bool{}
	for _, p := range l.Params {
		if seen[p.Name.Name] {
			fc.fail(diag.DupName, p.Name.Pos)
		}
		seen[p.Name.Name] = true
	}
	body := &types.Body{Parent: fc.body}
	sub := &fnCtx{c: fc.c, mod: fc.mod, tc: fc.tc, parent: fc, body: body, ret: ret, retUnknown: !known}
	sub.pushScope()
	for i, p := range l.Params {
		loc := sub.newLocal(p.Name.Name, ptypes[i], false)
		p.Local = loc
		sub.declare(loc)
		body.Params = append(body.Params, loc)
	}
	f := &types.Func{Name: "<lambda>", Module: fc.mod.tmod, Builtin: -1, Body: body, Params: ptypes}
	l.Func = f
	if known {
		switch b := l.Body.(type) {
		case *ast.Block:
			sub.funcBody(b, ret, l.Pos)
		default:
			sub.check(l.Body, ret)
		}
	} else {
		switch b := l.Body.(type) {
		case *ast.Block:
			for _, s := range b.Stmts {
				sub.stmt(s)
			}
			if b.Trailing != nil {
				ret = sub.infer(b.Trailing)
			} else {
				ret = types.Unit
			}
		default:
			ret = sub.infer(l.Body)
		}
	}
	f.Ret = ret
	return types.NewFunc(ptypes, ret)
}

// ---------------------------------------------------------------- if / match

func (fc *fnCtx) ifExpr(e *ast.IfExpr, want *types.Type) *types.Type {
	fc.check(e.Cond, types.Bool)
	if want != nil {
		if e.Else == nil {
			if !types.Unify(want, types.Unit) {
				fc.mismatch(e.Pos)
			}
			fc.checkBlock(e.Then, types.Unit)
			return types.Unit
		}
		fc.checkBlock(e.Then, want)
		fc.check(e.Else, want)
		return want
	}
	if e.Else == nil {
		fc.checkBlock(e.Then, types.Unit)
		return types.Unit
	}
	if !e.Then.Diverges() {
		t := fc.inferBlock(e.Then)
		fc.check(e.Else, t)
		return t
	}
	fc.inferBlock(e.Then)
	if ast.ExprDiverges(e.Else) {
		fc.infer(e.Else)
		return types.Unit
	}
	return fc.infer(e.Else)
}

func (fc *fnCtx) matchExpr(m *ast.MatchExpr, want *types.Type) *types.Type {
	s := fc.infer(m.Scr)
	if len(m.Arms) == 0 {
		fc.fail(diag.NonExhaustive, m.Pos)
	}
	var r *types.Type
	if want != nil {
		r = want
	}
	for _, arm := range m.Arms {
		bs := newBinds()
		fc.pattern(arm.Pat, s, bs)
		fc.pushScope()
		fc.declareBinds(bs)
		if arm.Guard != nil {
			fc.check(arm.Guard, types.Bool)
		}
		if r == nil {
			if ast.ExprDiverges(arm.Body) {
				fc.infer(arm.Body)
			} else {
				r = fc.infer(arm.Body)
			}
		} else {
			fc.check(arm.Body, r)
		}
		fc.popScope()
	}
	fc.checkExhaustive(m, s)
	if r == nil {
		return types.Unit
	}
	return r
}
