package check

import (
	"langvm/ast"
	"langvm/diag"
)

func (b *body) infer(e ast.Expr) *Type { return b.expr(e, nil) }
func (b *body) check(e ast.Expr, t *Type) {
	b.expr(e, t)
}

// def applies the default checking rule of SPEC 9.1.
func (b *body) def(e ast.Expr, s, exp *Type) *Type {
	if exp != nil && !unify(exp, s) {
		b.fail(diag.TypeMismatch, e.Position())
	}
	return s
}

func (b *body) expr(e ast.Expr, exp *Type) *Type {
	switch n := e.(type) {
	case *ast.IntLit:
		return b.def(e, TInt, exp)
	case *ast.FloatLit:
		return b.def(e, TFloat, exp)
	case *ast.StrLit:
		return b.def(e, TStr, exp)
	case *ast.CharLit:
		return b.def(e, TChar, exp)
	case *ast.BoolLit:
		return b.def(e, TBool, exp)
	case *ast.SelfExpr:
		if b.selfTy == nil {
			b.fail(diag.SelfOutside, n.P)
		}
		l := b.lookup("self")
		b.useLocal(l)
		n.Res = l
		return b.def(e, l.Type, exp)
	case *ast.PathExpr:
		return b.pathValue(n, exp)
	case *ast.Unary:
		return b.unary(n, exp)
	case *ast.Binary:
		return b.binary(n, exp)
	case *ast.IndexExpr:
		return b.index(n, exp)
	case *ast.FieldExpr:
		t := prune(b.infer(n.X))
		if t.Kind != KNamed || t.Decl.IsEnum {
			b.fail(diag.NotStruct, n.X.Position())
		}
		for i, f := range t.Decl.Fields {
			if f.Name == n.Name.Name {
				n.Sem = i
				return b.def(e, subst(f.Type, declSubst(t)), exp)
			}
		}
		b.fail(diag.UnknownField, n.Name.Pos)
	case *ast.ListLit:
		return b.listLit(n, exp)
	case *ast.MapLit:
		return b.mapLit(n, exp)
	case *ast.TupleLit:
		return b.tupleLit(n, exp)
	case *ast.Lambda:
		return b.lambda(n, exp)
	case *ast.IfExpr:
		return b.ifExpr(n, exp)
	case *ast.MatchExpr:
		return b.matchExpr(n, exp)
	case *ast.Block:
		return b.blockExpr(n, exp)
	case *ast.StructLit:
		return b.structLit(n, exp)
	case *ast.Call:
		return b.call(n, exp)
	case *ast.MethodCall:
		return b.methodCall(n, exp)
	}
	panic("check: unknown expression node")
}

// ------------------------------------------------------------------ operators

func (b *body) unary(n *ast.Unary, exp *Type) *Type {
	switch n.Op {
	case ast.OpNeg:
		t := prune(b.infer(n.X))
		switch t.Kind {
		case KInt:
			n.Sem = SemInt
		case KFloat:
			n.Sem = SemFloat
		default:
			b.fail(diag.TypeMismatch, n.X.Position())
		}
		return b.def(n, t, exp)
	case ast.OpNot:
		b.check(n.X, TBool)
		return b.def(n, TBool, exp)
	}
	b.check(n.X, TInt)
	return b.def(n, TInt, exp)
}

func (b *body) binary(n *ast.Binary, exp *Type) *Type {
	switch n.Op {
	case ast.OpAdd, ast.OpSub, ast.OpMul, ast.OpDiv, ast.OpMod:
		l := prune(b.infer(n.L))
		switch l.Kind {
		case KInt:
			n.Sem = SemInt
		case KFloat:
			n.Sem = SemFloat
			if n.Op == ast.OpMod {
				b.fail(diag.TypeMismatch, n.L.Position())
			}
		default:
			b.fail(diag.TypeMismatch, n.L.Position())
		}
		b.check(n.R, l)
		return b.def(n, l, exp)
	case ast.OpConcat:
		l := prune(b.infer(n.L))
		switch l.Kind {
		case KStr:
			n.Sem = SemStr
		case KList:
			n.Sem = SemList
		default:
			b.fail(diag.TypeMismatch, n.L.Position())
		}
		b.check(n.R, l)
		return b.def(n, l, exp)
	case ast.OpBitAnd, ast.OpBitOr, ast.OpBitXor, ast.OpShl, ast.OpShr:
		b.check(n.L, TInt)
		b.check(n.R, TInt)
		return b.def(n, TInt, exp)
	case ast.OpLt, ast.OpLe, ast.OpGt, ast.OpGe:
		l := b.infer(n.L)
		if !b.c.isOrd(l) {
			b.fail(diag.NotOrd, n.L.Position())
		}
		b.check(n.R, l)
		return b.def(n, TBool, exp)
	case ast.OpEq, ast.OpNe:
		l := b.infer(n.L)
		if !b.c.isEq(l, map[*TypeDecl]bool{}) {
			b.fail(diag.NotEq, n.L.Position())
		}
		b.check(n.R, l)
		return b.def(n, TBool, exp)
	}
	// && and ||
	b.check(n.L, TBool)
	b.check(n.R, TBool)
	return b.def(n, TBool, exp)
}

func (b *body) index(n *ast.IndexExpr, exp *Type) *Type {
	a := prune(b.infer(n.X))
	switch a.Kind {
	case KList:
		b.check(n.Index, TInt)
		n.Sem = SemList
		return b.def(n, a.Elems[0], exp)
	case KStr:
		b.check(n.Index, TInt)
		n.Sem = SemStr
		return b.def(n, TChar, exp)
	case KMap:
		b.check(n.Index, a.Elems[0])
		n.Sem = SemMap
		return b.def(n, a.Elems[1], exp)
	}
	b.fail(diag.NotIndexable, n.X.Position())
	return nil
}

// ------------------------------------------------------------------ literals

func (b *body) listLit(n *ast.ListLit, exp *Type) *Type {
	if exp == nil {
		if len(n.Elems) == 0 {
			b.fail(diag.CannotInfer, n.P)
		}
		t := b.infer(n.Elems[0])
		for _, e := range n.Elems[1:] {
			b.check(e, t)
		}
		return listOf(t)
	}
	t := prune(exp)
	if t.Kind == KVar {
		nt := listOf(b.newVar())
		unify(t, nt)
		t = nt
	}
	if t.Kind != KList {
		b.fail(diag.TypeMismatch, n.P)
	}
	for _, e := range n.Elems {
		b.check(e, t.Elems[0])
	}
	return t
}

func (b *body) mapLit(n *ast.MapLit, exp *Type) *Type {
	if exp == nil {
		if len(n.Keys) == 0 {
			b.fail(diag.CannotInfer, n.P)
		}
		k := b.infer(n.Keys[0])
		if !b.c.isKey(k) {
			b.fail(diag.BadKeyType, n.Keys[0].Position())
		}
		v := b.infer(n.Vals[0])
		for i := 1; i < len(n.Keys); i++ {
			b.check(n.Keys[i], k)
			b.check(n.Vals[i], v)
		}
		return mapOf(k, v)
	}
	t := prune(exp)
	if t.Kind == KVar {
		nt := mapOf(b.newVar(), b.newVar())
		unify(t, nt)
		t = nt
	}
	if t.Kind != KMap {
		b.fail(diag.TypeMismatch, n.P)
	}
	for i := range n.Keys {
		b.check(n.Keys[i], t.Elems[0])
		b.check(n.Vals[i], t.Elems[1])
	}
	if k := prune(t.Elems[0]); k.Kind != KVar && !b.c.isKey(k) {
		b.fail(diag.BadKeyType, n.P)
	}
	return t
}

func (b *body) tupleLit(n *ast.TupleLit, exp *Type) *Type {
	if len(n.Elems) > 8 {
		b.fail(diag.BadArity, n.P)
	}
	if exp == nil {
		elems := make([]*Type, len(n.Elems))
		for i, e := range n.Elems {
			elems[i] = b.infer(e)
		}
		return &Type{Kind: KTuple, Elems: elems}
	}
	t := prune(exp)
	if t.Kind == KVar {
		elems := make([]*Type, len(n.Elems))
		for i := range elems {
			elems[i] = b.newVar()
		}
		nt := &Type{Kind: KTuple, Elems: elems}
		unify(t, nt)
		t = nt
	}
	if t.Kind != KTuple || len(t.Elems) != len(n.Elems) {
		b.fail(diag.TypeMismatch, n.P)
	}
	for i, e := range n.Elems {
		b.check(e, t.Elems[i])
	}
	return t
}

// ------------------------------------------------------------------- lambdas

func (b *body) lambda(n *ast.Lambda, exp *Type) *Type {
	var ptypes []*Type
	var ret *Type
	if exp == nil {
		ptypes = make([]*Type, len(n.Params))
		for i, p := range n.Params {
			if p.Type == nil {
				b.fail(diag.CannotInfer, p.Name.Pos)
			}
			ptypes[i] = b.c.resolveType(p.Type, b.sc)
		}
		if n.Ret != nil {
			ret = b.c.resolveType(n.Ret, b.sc)
		}
		b.dupLambdaParams(n)
		if ret == nil {
			ret = b.lambdaBody(n, ptypes, nil)
		} else {
			b.lambdaBody(n, ptypes, ret)
		}
		return &Type{Kind: KFn, Elems: ptypes, Ret: ret}
	}
	t := prune(exp)
	if t.Kind == KVar {
		elems := make([]*Type, len(n.Params))
		for i := range elems {
			elems[i] = b.newVar()
		}
		nt := &Type{Kind: KFn, Elems: elems, Ret: b.newVar()}
		unify(t, nt)
		t = nt
	}
	if t.Kind != KFn || len(t.Elems) != len(n.Params) {
		b.fail(diag.TypeMismatch, n.P)
	}
	ptypes = t.Elems
	for i, p := range n.Params {
		if p.Type != nil {
			ann := b.c.resolveType(p.Type, b.sc)
			if !unify(ptypes[i], ann) {
				b.fail(diag.TypeMismatch, p.Type.Pos)
			}
		} else if prune(ptypes[i]).Kind == KVar {
			b.fail(diag.CannotInfer, p.Name.Pos)
		}
	}
	ret = t.Ret
	if n.Ret != nil {
		ann := b.c.resolveType(n.Ret, b.sc)
		if !unify(ret, ann) {
			b.fail(diag.TypeMismatch, n.Ret.Pos)
		}
	}
	b.dupLambdaParams(n)
	b.lambdaBody(n, ptypes, ret)
	return t
}

func (b *body) dupLambdaParams(n *ast.Lambda) {
	seen := map[string]bool{}
	for _, p := range n.Params {
		if seen[p.Name.Name] {
			b.fail(diag.DupName, p.Name.Pos)
		}
		seen[p.Name.Name] = true
	}
}

// lambdaBody checks a lambda's body. With ret != nil the body is checked
// against it (SPEC 11.6); with ret == nil the body's type is synthesised and
// returned.
func (b *body) lambdaBody(n *ast.Lambda, ptypes []*Type, ret *Type) *Type {
	info := &FnInfo{Parent: b.fn, Lambda: n, Ret: ret}
	n.Info = info
	saved := b.fn
	b.fn = info
	b.push()
	for i, p := range n.Params {
		info.Params = append(info.Params, b.declare(p.Name.Name, false, ptypes[i]))
	}
	var result *Type
	blk, isBlock := n.Body.(*ast.Block)
	switch {
	case ret != nil && isBlock:
		b.funcBody(blk, ret, n.P)
		result = ret
	case ret != nil:
		b.check(n.Body, ret)
		result = ret
	case isBlock:
		b.push()
		for _, s := range blk.Stmts {
			b.stmt(s)
		}
		if blk.Tail != nil {
			result = b.infer(blk.Tail)
		} else {
			result = TUnit
		}
		b.pop()
		info.Ret = result
	default:
		result = b.infer(n.Body)
		info.Ret = result
	}
	b.pop()
	b.fn = saved
	return result
}

// ---------------------------------------------------------------- if / match

func (b *body) ifExpr(n *ast.IfExpr, exp *Type) *Type {
	b.check(n.Cond, TBool)
	if n.Else == nil {
		if exp != nil && !unify(exp, TUnit) {
			b.fail(diag.TypeMismatch, n.P)
		}
		b.check(n.Then, TUnit)
		return TUnit
	}
	if exp != nil {
		b.check(n.Then, exp)
		b.check(n.Else, exp)
		return exp
	}
	if !n.Then.Div {
		t := b.infer(n.Then)
		b.check(n.Else, t)
		return t
	}
	b.infer(n.Then)
	if ast.Diverges(n.Else) {
		b.infer(n.Else)
		return TUnit
	}
	return b.infer(n.Else)
}

func (b *body) blockExpr(n *ast.Block, exp *Type) *Type {
	b.push()
	for _, s := range n.Stmts {
		b.stmt(s)
	}
	var t *Type
	switch {
	case n.Tail != nil && exp != nil:
		b.check(n.Tail, exp)
		t = exp
	case n.Tail != nil:
		t = b.infer(n.Tail)
	case exp != nil:
		if !n.Div && !unify(exp, TUnit) {
			b.fail(diag.TypeMismatch, n.P)
		}
		t = exp
	default:
		t = TUnit
	}
	b.pop()
	return t
}

func (b *body) matchExpr(n *ast.MatchExpr, exp *Type) *Type {
	s := b.infer(n.Scrut)
	if len(n.Arms) == 0 {
		b.fail(diag.NonExhaustive, n.P)
	}
	r := exp
	for _, arm := range n.Arms {
		b.push()
		b.pattern(arm.Pat, s)
		if arm.Guard != nil {
			b.check(arm.Guard, TBool)
		}
		switch {
		case r == nil:
			if ast.Diverges(arm.Body) {
				b.infer(arm.Body)
			} else {
				r = b.infer(arm.Body)
			}
		default:
			b.check(arm.Body, r)
		}
		b.pop()
	}
	b.matchAnalysis(n, s)
	if r == nil {
		return TUnit
	}
	return r
}

// ----------------------------------------------------------------- struct lit

// StructLitRes annotates a struct literal.
type StructLitRes struct {
	Decl  *TypeDecl
	Order []int // declaration index of each written field
}

func (b *body) structDecl(mod *ast.Ident, name ast.Ident, pos ast.Pos) *TypeDecl {
	if mod == nil {
		if _, ok := b.sc.params[name.Name]; ok {
			b.fail(diag.NotStruct, pos)
		}
		if name.Name == "Self" {
			if b.sc.self == nil {
				b.fail(diag.SelfOutside, pos)
			}
			st := prune(b.sc.self)
			if st.Kind != KNamed || st.Decl.IsEnum {
				b.fail(diag.NotStruct, pos)
			}
			return st.Decl
		}
		if _, ok := primTypes[name.Name]; ok {
			b.fail(diag.NotStruct, pos)
		}
	}
	d := b.c.lookupTypeDecl(b.mod, mod, name)
	if d.IsEnum {
		b.fail(diag.NotStruct, pos)
	}
	return d
}

func (b *body) structLit(n *ast.StructLit, exp *Type) *Type {
	d := b.structDecl(n.Mod, n.Name, n.P)
	b.pushVars()
	vars := make([]*Type, len(d.Params))
	m := make(map[*TypeParam]*Type, len(d.Params))
	for i, p := range d.Params {
		vars[i] = b.newVar()
		m[p] = vars[i]
	}
	st := &Type{Kind: KNamed, Decl: d, Elems: vars}
	if exp != nil && !unify(exp, st) {
		b.fail(diag.TypeMismatch, n.P)
	}
	res := &StructLitRes{Decl: d, Order: make([]int, len(n.Fields))}
	n.Res = res
	seen := map[string]bool{}
	for i, f := range n.Fields {
		if seen[f.Name.Name] {
			b.fail(diag.DupField, f.Name.Pos)
		}
		seen[f.Name.Name] = true
		idx := -1
		for j, df := range d.Fields {
			if df.Name == f.Name.Name {
				idx = j
				break
			}
		}
		if idx < 0 {
			b.fail(diag.UnknownField, f.Name.Pos)
		}
		res.Order[i] = idx
	}
	for j, df := range d.Fields {
		var fe ast.Expr
		for i, f := range n.Fields {
			if res.Order[i] == j {
				fe = f.X
				break
			}
		}
		if fe == nil {
			b.fail(diag.MissingField, n.P)
		}
		b.check(fe, subst(df.Type, m))
	}
	b.popVars(n.P)
	return zonk(st)
}

// --------------------------------------------------------------------- paths

func (b *body) isTypeName(name string) bool {
	if _, ok := b.mod.Types[name]; ok {
		return true
	}
	if _, ok := b.c.prelude.Types[name]; ok {
		return true
	}
	if _, ok := primTypes[name]; ok {
		return true
	}
	return name == "Self"
}

// resolveValue resolves a value path to a *Local, *Func, *Variant or
// *TraitMethodRef.
func (b *body) resolveValue(n *ast.PathExpr) any {
	if n.Mod == nil {
		name := n.Name.Name
		if l := b.lookup(name); l != nil {
			return l
		}
		if v, ok := b.mod.Values[name]; ok {
			return v
		}
		if v, ok := b.c.prelude.Values[name]; ok {
			return v
		}
		if b.isTypeName(name) {
			b.fail(diag.BadValueRef, n.Name.Pos)
		}
		b.fail(diag.UnknownName, n.Name.Pos)
	}
	return b.qualifiedValue(n.Mod, n.Name)
}

func (c *Checker) findTrait(mod *Module, name string) *Trait {
	for _, t := range c.visibleTraits(mod) {
		if t.Name == name {
			return t
		}
	}
	return c.prelude.Traits[name]
}

func (b *body) qualifiedValue(mod *ast.Ident, name ast.Ident) any {
	if m, ok := b.mod.Imports[mod.Name]; ok {
		v, ok := m.Values[name.Name]
		if !ok {
			b.fail(diag.UnknownName, name.Pos)
		}
		pub := true
		switch x := v.(type) {
		case *Func:
			pub = x.Pub
		case *Variant:
			pub = x.Enum.Pub
		}
		if !pub && m != b.mod {
			b.fail(diag.NotPublic, name.Pos)
		}
		return v
	}
	if tr := b.c.findTrait(b.mod, mod.Name); tr != nil {
		mt, ok := tr.ByName[name.Name]
		if !ok {
			b.fail(diag.UnknownName, name.Pos)
		}
		return &TraitMethodRef{Trait: tr, Method: mt}
	}
	b.fail(diag.UnknownModule, mod.Pos)
	return nil
}

// enumType is the type `E<P1, ..., Pk>` over the enum's own parameters.
func enumType(d *TypeDecl) *Type {
	elems := make([]*Type, len(d.Params))
	for i, p := range d.Params {
		elems[i] = p.T
	}
	return &Type{Kind: KNamed, Decl: d, Elems: elems}
}

// pathValue types a value path used as a plain value (not as a callee).
func (b *body) pathValue(n *ast.PathExpr, exp *Type) *Type {
	switch r := b.resolveValue(n).(type) {
	case *Local:
		b.useLocal(r)
		n.Res = r
		return b.def(n, r.Type, exp)
	case *Variant:
		if len(r.Payload) > 0 {
			b.fail(diag.BadValueRef, n.Name.Pos)
		}
		n.Res = r
		return b.genericCall(n.P, r.Enum.Params, nil, enumType(r.Enum), nil, exp)
	}
	b.fail(diag.BadValueRef, n.Name.Pos)
	return nil
}

// ----------------------------------------------------------------- generic calls

// genericCall implements SPEC 9.4.
func (b *body) genericCall(pos ast.Pos, tparams []*TypeParam, params []*Type, ret *Type, args []ast.Expr, exp *Type) *Type {
	if len(args) != len(params) {
		b.fail(diag.Arity, pos)
	}
	b.pushVars()
	var m map[*TypeParam]*Type
	if len(tparams) > 0 {
		m = make(map[*TypeParam]*Type, len(tparams))
		for _, p := range tparams {
			m[p] = b.newVar()
		}
	}
	for i, a := range args {
		b.check(a, subst(params[i], m))
	}
	rt := subst(ret, m)
	if exp != nil && !unify(rt, exp) {
		b.fail(diag.TypeMismatch, pos)
	}
	b.popVars(pos)
	for _, p := range tparams {
		for _, bd := range p.Bounds {
			if !b.c.satisfies(zonk(m[p]), bd) {
				b.fail(diag.UnsatisfiedBound, pos)
			}
		}
	}
	return zonk(rt)
}

// ---------------------------------------------------------------------- calls

func (b *body) call(n *ast.Call, exp *Type) *Type {
	if len(n.Args) > 16 {
		b.fail(diag.BadArity, n.Callee.Position())
	}
	if path, ok := n.Callee.(*ast.PathExpr); ok {
		switch r := b.resolveValue(path).(type) {
		case *Local:
			b.useLocal(r)
			path.Res = r
			return b.indirectCall(n, r.Type, exp)
		case *Func:
			path.Res = r
			kind := CallFunc
			if r.Builtin >= 0 {
				kind = CallBuiltin
			}
			n.Res = &CallRes{Kind: kind, Func: r}
			return b.genericCall(path.P, r.TParams, r.Params, r.Ret, n.Args, exp)
		case *Variant:
			path.Res = r
			n.Res = &CallRes{Kind: CallVariant, Variant: r}
			return b.genericCall(path.P, r.Enum.Params, r.Payload, enumType(r.Enum), n.Args, exp)
		case *TraitMethodRef:
			path.Res = r
			n.Res = &CallRes{Kind: CallTraitMethod, Trait: r}
			return b.traitPathCall(n, path, r, exp)
		}
	}
	f := b.infer(n.Callee)
	n.Res = &CallRes{Kind: CallValue}
	return b.indirectCall(n, f, exp)
}

func (b *body) indirectCall(n *ast.Call, f *Type, exp *Type) *Type {
	f = prune(f)
	if f.Kind != KFn {
		b.fail(diag.NotCallable, n.Callee.Position())
	}
	if len(n.Args) != len(f.Elems) {
		b.fail(diag.Arity, n.Callee.Position())
	}
	for i, a := range n.Args {
		b.check(a, f.Elems[i])
	}
	if n.Res == nil {
		n.Res = &CallRes{Kind: CallValue}
	}
	return b.def(n, f.Ret, exp)
}

// methodCandidates returns the distinct visible traits declaring method name.
func (c *Checker) methodCandidates(mod *Module, name string) []*Trait {
	var out []*Trait
	for _, t := range c.visibleTraits(mod) {
		if _, ok := t.ByName[name]; !ok {
			continue
		}
		dup := false
		for _, o := range out {
			if o == t {
				dup = true
			}
		}
		if !dup {
			out = append(out, t)
		}
	}
	return out
}

func (b *body) methodCall(n *ast.MethodCall, exp *Type) *Type {
	if len(n.Args) > 16 {
		b.fail(diag.BadArity, n.Name.Pos)
	}
	r := b.infer(n.Recv)
	cands := b.c.methodCandidates(b.mod, n.Name.Name)
	if len(cands) == 0 {
		b.fail(diag.NoMethod, n.Name.Pos)
	}
	if len(cands) > 1 {
		b.fail(diag.AmbigMethod, n.Name.Pos)
	}
	tr := cands[0]
	mt := tr.ByName[n.Name.Name]
	if len(n.Args) != len(mt.Params) {
		b.fail(diag.Arity, n.Name.Pos)
	}
	if !b.c.satisfies(r, tr) {
		b.fail(diag.UnsatisfiedBound, n.Name.Pos)
	}
	sm := map[*TypeParam]*Type{tr.Self: r}
	for i, a := range n.Args {
		b.check(a, subst(mt.Params[i], sm))
	}
	n.Res = &MethodRes{Trait: tr, Method: mt}
	return b.def(n, subst(mt.Ret, sm), exp)
}

func (b *body) traitPathCall(n *ast.Call, path *ast.PathExpr, ref *TraitMethodRef, exp *Type) *Type {
	tr, mt := ref.Trait, ref.Method
	if len(n.Args) == 0 {
		b.fail(diag.Arity, path.Name.Pos)
	}
	r := b.infer(n.Args[0])
	if len(n.Args)-1 != len(mt.Params) {
		b.fail(diag.Arity, path.Name.Pos)
	}
	if !b.c.satisfies(r, tr) {
		b.fail(diag.UnsatisfiedBound, path.Name.Pos)
	}
	sm := map[*TypeParam]*Type{tr.Self: r}
	for i, a := range n.Args[1:] {
		b.check(a, subst(mt.Params[i], sm))
	}
	return b.def(n, subst(mt.Ret, sm), exp)
}
