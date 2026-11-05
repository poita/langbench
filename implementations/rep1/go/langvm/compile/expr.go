package compile

import (
	"langvm/ast"
	"langvm/bytecode"
	"langvm/check"
)

// expr compiles e, leaving exactly one value on the operand stack.
func (f *fnc) expr(e ast.Expr) {
	switch n := e.(type) {
	case *ast.IntLit:
		f.pushInt(n.Val)
	case *ast.FloatLit:
		f.emit(bytecode.PushConst, f.c.constIdx(bytecode.Const{Kind: bytecode.ConstFloat, Float: n.Val}), 0, 0)
	case *ast.StrLit:
		f.emit(bytecode.PushConst, f.c.constIdx(bytecode.Const{Kind: bytecode.ConstStr, Str: n.Val}), 0, 0)
	case *ast.CharLit:
		f.emit(bytecode.PushConst, f.c.constIdx(bytecode.Const{Kind: bytecode.ConstChar, Int: int64(n.Val)}), 0, 0)
	case *ast.BoolLit:
		if n.Val {
			f.emit(bytecode.PushTrue, 0, 0, 0)
		} else {
			f.emit(bytecode.PushFalse, 0, 0, 0)
		}
	case *ast.SelfExpr:
		f.loadLocal(n.Res.(*check.Local))
	case *ast.PathExpr:
		switch r := n.Res.(type) {
		case *check.Local:
			f.loadLocal(r)
		case *check.Variant:
			f.emit(bytecode.MakeEnum, r.Enum.ID, r.Index, 0)
		}
	case *ast.Unary:
		f.expr(n.X)
		switch n.Op {
		case ast.OpNeg:
			if n.Sem == check.SemFloat {
				f.emit(bytecode.NegF, 0, 0, 0)
			} else {
				f.emit(bytecode.NegI, 0, 0, 0)
			}
		case ast.OpNot:
			f.emit(bytecode.NotB, 0, 0, 0)
		default:
			f.emit(bytecode.BNot, 0, 0, 0)
		}
	case *ast.Binary:
		f.binary(n)
	case *ast.IndexExpr:
		f.expr(n.X)
		f.expr(n.Index)
		f.emit(bytecode.IndexGet, 0, 0, 0)
	case *ast.FieldExpr:
		f.expr(n.X)
		f.emit(bytecode.GetField, n.Sem, 0, 0)
	case *ast.ListLit:
		for _, x := range n.Elems {
			f.expr(x)
		}
		f.emit(bytecode.MakeList, len(n.Elems), 0, 0)
	case *ast.MapLit:
		for i := range n.Keys {
			f.expr(n.Keys[i])
			f.expr(n.Vals[i])
		}
		f.emit(bytecode.MakeMap, len(n.Keys), 0, 0)
	case *ast.TupleLit:
		for _, x := range n.Elems {
			f.expr(x)
		}
		f.emit(bytecode.MakeTuple, len(n.Elems), 0, 0)
	case *ast.Lambda:
		f.lambda(n)
	case *ast.IfExpr:
		f.ifExpr(n)
	case *ast.MatchExpr:
		f.matchExpr(n)
	case *ast.Block:
		f.block(n)
	case *ast.StructLit:
		f.structLit(n)
	case *ast.Call:
		f.call(n)
	case *ast.MethodCall:
		f.expr(n.Recv)
		for _, a := range n.Args {
			f.expr(a)
		}
		r := n.Res.(*check.MethodRes)
		f.emit(bytecode.CallMethod, r.Trait.ID, r.Method.Index, len(n.Args))
	default:
		panic("compile: unknown expression")
	}
}

func (f *fnc) binary(n *ast.Binary) {
	switch n.Op {
	case ast.OpAnd:
		f.expr(n.L)
		j := f.emit(bytecode.JumpIfFalse, 0, 0, 0)
		f.expr(n.R)
		end := f.emit(bytecode.Jump, 0, 0, 0)
		f.patch(j, f.here())
		f.depth--
		f.emit(bytecode.PushFalse, 0, 0, 0)
		f.patch(end, f.here())
		return
	case ast.OpOr:
		f.expr(n.L)
		j := f.emit(bytecode.JumpIfTrue, 0, 0, 0)
		f.expr(n.R)
		end := f.emit(bytecode.Jump, 0, 0, 0)
		f.patch(j, f.here())
		f.depth--
		f.emit(bytecode.PushTrue, 0, 0, 0)
		f.patch(end, f.here())
		return
	}
	f.expr(n.L)
	f.expr(n.R)
	fl := n.Sem == check.SemFloat
	pick := func(i, fl2 bytecode.Op) bytecode.Op {
		if fl {
			return fl2
		}
		return i
	}
	var op bytecode.Op
	switch n.Op {
	case ast.OpAdd:
		op = pick(bytecode.AddI, bytecode.AddF)
	case ast.OpSub:
		op = pick(bytecode.SubI, bytecode.SubF)
	case ast.OpMul:
		op = pick(bytecode.MulI, bytecode.MulF)
	case ast.OpDiv:
		op = pick(bytecode.DivI, bytecode.DivF)
	case ast.OpMod:
		op = bytecode.ModI
	case ast.OpConcat:
		if n.Sem == check.SemStr {
			op = bytecode.ConcatStr
		} else {
			op = bytecode.ConcatList
		}
	case ast.OpBitAnd:
		op = bytecode.BAnd
	case ast.OpBitOr:
		op = bytecode.BOr
	case ast.OpBitXor:
		op = bytecode.BXor
	case ast.OpShl:
		op = bytecode.Shl
	case ast.OpShr:
		op = bytecode.Shr
	case ast.OpEq:
		op = bytecode.Eq
	case ast.OpNe:
		op = bytecode.Ne
	case ast.OpLt:
		op = bytecode.Lt
	case ast.OpLe:
		op = bytecode.Le
	case ast.OpGt:
		op = bytecode.Gt
	case ast.OpGe:
		op = bytecode.Ge
	}
	f.emit(op, 0, 0, 0)
}

func (f *fnc) ifExpr(n *ast.IfExpr) {
	f.expr(n.Cond)
	jf := f.emit(bytecode.JumpIfFalse, 0, 0, 0)
	d := f.depth
	f.block(n.Then)
	if n.Else == nil {
		// Unit-typed: the then value (Unit) is replaced by the else value.
		je := f.emit(bytecode.Jump, 0, 0, 0)
		f.patch(jf, f.here())
		f.depth = d
		f.emit(bytecode.PushUnit, 0, 0, 0)
		f.patch(je, f.here())
		return
	}
	je := f.emit(bytecode.Jump, 0, 0, 0)
	f.patch(jf, f.here())
	f.depth = d
	f.expr(n.Else)
	f.patch(je, f.here())
}

func (f *fnc) structLit(n *ast.StructLit) {
	res := n.Res.(*check.StructLitRes)
	identity := true
	for i, o := range res.Order {
		if o != i {
			identity = false
		}
	}
	if identity && len(n.Fields) == len(res.Decl.Fields) {
		for _, fi := range n.Fields {
			f.expr(fi.X)
		}
		f.emit(bytecode.MakeStruct, res.Decl.ID, len(n.Fields), 0)
		return
	}
	saved := f.next
	tmp := make([]int, len(res.Decl.Fields))
	for i, fi := range n.Fields {
		f.expr(fi.X)
		s := f.alloc()
		tmp[res.Order[i]] = s
		f.emit(bytecode.StoreLocal, s, 0, 0)
	}
	for _, s := range tmp {
		f.emit(bytecode.LoadLocal, s, 0, 0)
	}
	f.emit(bytecode.MakeStruct, res.Decl.ID, len(tmp), 0)
	f.next = saved
}

func (f *fnc) call(n *ast.Call) {
	res := n.Res.(*check.CallRes)
	switch res.Kind {
	case check.CallFunc:
		for _, a := range n.Args {
			f.expr(a)
		}
		f.emit(bytecode.Call, res.Func.ID, len(n.Args), 0)
	case check.CallBuiltin:
		for _, a := range n.Args {
			f.expr(a)
		}
		f.emit(bytecode.CallBuiltin, res.Func.Builtin, len(n.Args), 0)
	case check.CallVariant:
		for _, a := range n.Args {
			f.expr(a)
		}
		f.emit(bytecode.MakeEnum, res.Variant.Enum.ID, res.Variant.Index, len(n.Args))
	case check.CallValue:
		f.expr(n.Callee)
		for _, a := range n.Args {
			f.expr(a)
		}
		f.emit(bytecode.CallValue, len(n.Args), 0, 0)
	case check.CallTraitMethod:
		for _, a := range n.Args {
			f.expr(a)
		}
		f.emit(bytecode.CallMethod, res.Trait.Trait.ID, res.Trait.Method.Index, len(n.Args)-1)
	}
}

func (f *fnc) lambda(n *ast.Lambda) {
	info := n.Info.(*check.FnInfo)
	idx := len(f.c.out.Funcs)
	f.c.out.Funcs = append(f.c.out.Funcs, nil)
	sub := newFnc(f.c, info, "<lambda>")
	sub.params()
	if blk, ok := n.Body.(*ast.Block); ok {
		sub.block(blk)
	} else {
		sub.expr(n.Body)
	}
	sub.emit(bytecode.Ret, 0, 0, 0)
	f.c.out.Funcs[idx] = sub.finish()
	for _, l := range info.Captures {
		f.loadLocal(l)
	}
	f.emit(bytecode.MakeClosure, idx, len(info.Captures), 0)
}

// ------------------------------------------------------------------ match

func (f *fnc) matchExpr(n *ast.MatchExpr) {
	saved := f.next
	f.expr(n.Scrut)
	s := f.alloc()
	f.emit(bytecode.StoreLocal, s, 0, 0)
	base := f.depth
	var ends []int
	for _, arm := range n.Arms {
		mark := f.next
		var fails []int
		f.testPat(arm.Pat, s, &fails)
		if arm.Guard != nil {
			f.expr(arm.Guard)
			fails = append(fails, f.emit(bytecode.JumpIfFalse, 0, 0, 0))
		}
		f.expr(arm.Body)
		ends = append(ends, f.emit(bytecode.Jump, 0, 0, 0))
		f.patchAll(fails, f.here())
		f.depth = base
		f.next = mark
	}
	f.emit(bytecode.NoMatch, 0, 0, 0)
	f.patchAll(ends, f.here())
	f.depth = base + 1
	if f.depth > f.maxDepth {
		f.maxDepth = f.depth
	}
	f.next = saved
}

// testPat emits code that matches the value in local slot against p. On
// failure control jumps to a location recorded in fails (patched by the
// caller); on success the pattern's bindings are stored in fresh slots.
func (f *fnc) testPat(p ast.Pattern, slot int, fails *[]int) {
	switch n := p.(type) {
	case *ast.WildPat:
	case *ast.NamePat:
		if n.Var != nil {
			v := n.Var.(*check.Variant)
			f.variantTest(v, slot, fails)
			return
		}
		l := n.Local.(*check.Local)
		l.Slot = f.alloc()
		f.emit(bytecode.LoadLocal, slot, 0, 0)
		f.emit(bytecode.StoreLocal, l.Slot, 0, 0)
	case *ast.LitPat:
		f.emit(bytecode.LoadLocal, slot, 0, 0)
		switch n.Kind {
		case ast.LitInt:
			v := n.Int
			if n.Neg {
				v = -v
			}
			f.pushInt(v)
		case ast.LitChar:
			f.emit(bytecode.PushConst, f.c.constIdx(bytecode.Const{Kind: bytecode.ConstChar, Int: n.Int}), 0, 0)
		case ast.LitStr:
			f.emit(bytecode.PushConst, f.c.constIdx(bytecode.Const{Kind: bytecode.ConstStr, Str: n.Str}), 0, 0)
		default:
			if n.Bool {
				f.emit(bytecode.PushTrue, 0, 0, 0)
			} else {
				f.emit(bytecode.PushFalse, 0, 0, 0)
			}
		}
		f.emit(bytecode.Eq, 0, 0, 0)
		*fails = append(*fails, f.emit(bytecode.JumpIfFalse, 0, 0, 0))
	case *ast.VariantPat:
		v := n.Var.(*check.Variant)
		f.variantTest(v, slot, fails)
		for i, a := range n.Args {
			f.sub(a, bytecode.PushPayload, slot, i, fails)
		}
	case *ast.StructPat:
		for _, fp := range n.Fields {
			if fp.Pat == nil {
				l := fp.Local.(*check.Local)
				f.emit(bytecode.PushField, slot, fp.Index, 0)
				l.Slot = f.alloc()
				f.emit(bytecode.StoreLocal, l.Slot, 0, 0)
				continue
			}
			f.sub(fp.Pat, bytecode.PushField, slot, fp.Index, fails)
		}
	case *ast.TuplePat:
		for i, e := range n.Elems {
			f.sub(e, bytecode.PushTuple, slot, i, fails)
		}
	case *ast.ListPat:
		op := bytecode.JumpUnlessLen
		if n.HasRest {
			op = bytecode.JumpUnlessLenGE
		}
		if len(n.Elems) > 0 || !n.HasRest {
			*fails = append(*fails, f.emit(op, slot, len(n.Elems), 0))
		}
		for i, e := range n.Elems {
			f.sub(e, bytecode.PushElem, slot, i, fails)
		}
		if n.RestLocal != nil {
			l := n.RestLocal.(*check.Local)
			f.emit(bytecode.PushRest, slot, len(n.Elems), 0)
			l.Slot = f.alloc()
			f.emit(bytecode.StoreLocal, l.Slot, 0, 0)
		}
	}
}

func (f *fnc) variantTest(v *check.Variant, slot int, fails *[]int) {
	if len(v.Enum.Variants) > 1 {
		*fails = append(*fails, f.emit(bytecode.JumpUnlessVariant, slot, v.Index, 0))
	}
}

// sub matches a component of the value in slot, fetched by op.
func (f *fnc) sub(p ast.Pattern, op bytecode.Op, slot, i int, fails *[]int) {
	switch n := p.(type) {
	case *ast.WildPat:
		return
	case *ast.NamePat:
		if n.Var == nil {
			l := n.Local.(*check.Local)
			f.emit(op, slot, i, 0)
			l.Slot = f.alloc()
			f.emit(bytecode.StoreLocal, l.Slot, 0, 0)
			return
		}
	}
	f.emit(op, slot, i, 0)
	tmp := f.alloc()
	f.emit(bytecode.StoreLocal, tmp, 0, 0)
	f.testPat(p, tmp, fails)
}
