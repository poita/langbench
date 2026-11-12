// Package compiler translates a checked Vellum program into bytecode
// (SPEC.md section 16). It consumes the annotations the checker leaves on
// the syntax tree and never looks anything up by name.
package compiler

import (
	"math"

	"langvm/ast"
	bc "langvm/bytecode"
	"langvm/check"
	"langvm/types"
)

// Compile produces the bytecode program for a checked program.
func Compile(p *check.Program) *bc.Program {
	c := &compiler{prog: p, out: &bc.Program{}, consts: map[constKey]int32{}}
	for _, d := range p.Decls {
		info := bc.DeclInfo{Name: d.Name, IsEnum: d.IsEnum}
		for _, f := range d.Fields {
			info.Fields = append(info.Fields, f.Name)
		}
		for _, v := range d.Variants {
			info.Variants = append(info.Variants, bc.Variant{Name: v.Name, NPayload: len(v.Payload)})
		}
		c.out.Decls = append(c.out.Decls, info)
	}
	c.out.NumTraits = len(p.Traits)
	// Assign function indices to all declared functions first.
	for _, m := range p.Modules {
		for _, it := range m.Items {
			switch d := it.(type) {
			case *ast.FnDecl:
				c.assign(d.Func)
			case *ast.TraitDecl:
				for _, md := range d.Methods {
					if md.Body != nil {
						c.assign(md.Func)
					}
				}
			case *ast.ImplDecl:
				for _, md := range d.Methods {
					c.assign(md.Func)
				}
			}
		}
	}
	for _, m := range p.Modules {
		for _, it := range m.Items {
			switch d := it.(type) {
			case *ast.FnDecl:
				c.compileFunc(d.Func, d.Body)
			case *ast.TraitDecl:
				for _, md := range d.Methods {
					if md.Body != nil {
						c.compileFunc(md.Func, md.Body)
					}
				}
			case *ast.ImplDecl:
				for _, md := range d.Methods {
					c.compileFunc(md.Func, md.Body)
				}
			}
		}
	}
	for _, impl := range p.Impls {
		e := bc.ImplEntry{Trait: impl.Trait.ID, Ctor: impl.Ctor}
		for i, f := range impl.Methods {
			if f == nil {
				f = impl.Trait.Methods[i].Default
			}
			e.Methods = append(e.Methods, int32(f.Index))
		}
		c.out.Impls = append(c.out.Impls, e)
	}
	c.out.Main = p.Main.Index
	return c.out
}

type constKey struct {
	kind bc.ConstKind
	i    int64
	s    string
}

type compiler struct {
	prog   *check.Program
	out    *bc.Program
	consts map[constKey]int32
}

func (c *compiler) assign(f *types.Func) {
	f.Index = len(c.out.Funcs)
	c.out.Funcs = append(c.out.Funcs, nil)
}

func (c *compiler) constant(k bc.Const) int32 {
	key := constKey{kind: k.Kind, i: k.I}
	switch k.Kind {
	case bc.ConstFloat:
		key.i = int64(math.Float64bits(k.F))
	case bc.ConstStr:
		key.s = string(k.S)
	}
	if i, ok := c.consts[key]; ok {
		return i
	}
	i := int32(len(c.out.Consts))
	c.out.Consts = append(c.out.Consts, k)
	c.consts[key] = i
	return i
}

func (c *compiler) compileFunc(f *types.Func, body *ast.Block) {
	fg := newFnGen(c, f.Body)
	fg.funcBlock(body)
	c.out.Funcs[f.Index] = fg.finish(f.Name)
}

// ---------------------------------------------------------------- function generator

type label struct {
	target  int
	patches []int
}

func newLabel() *label { return &label{target: -1} }

type loopCtx struct {
	save       int
	breaks     *label
	contTarget int
	conts      []int
}

type fnGen struct {
	c       *compiler
	body    *types.Body
	code    []bc.Instr
	next    int
	max     int
	nparams int
	loops   []*loopCtx
}

func newFnGen(c *compiler, body *types.Body) *fnGen {
	fg := &fnGen{c: c, body: body}
	for _, p := range body.Params {
		p.Slot = fg.alloc()
	}
	fg.nparams = len(body.Params)
	return fg
}

func (fg *fnGen) finish(name string) *bc.Function {
	return &bc.Function{Name: name, NParams: fg.nparams, NLocals: fg.max, Code: fg.code}
}

func (fg *fnGen) alloc() int {
	s := fg.next
	fg.next++
	if fg.next > fg.max {
		fg.max = fg.next
	}
	return s
}

func (fg *fnGen) emit(op bc.Op, a, b, c int) int {
	fg.code = append(fg.code, bc.Instr{Op: op, A: int32(a), B: int32(b), C: int32(c)})
	return len(fg.code) - 1
}

// jump emits a jump-like instruction to a label.
func (fg *fnGen) jump(op bc.Op, l *label) {
	i := fg.emit(op, 0, 0, 0)
	if l.target >= 0 {
		fg.code[i].A = int32(l.target)
	} else {
		l.patches = append(l.patches, i)
	}
}

func (fg *fnGen) bind(l *label) {
	l.target = len(fg.code)
	for _, i := range l.patches {
		fg.code[i].A = int32(l.target)
	}
	l.patches = nil
}

func (fg *fnGen) funcBlock(b *ast.Block) {
	for _, s := range b.Stmts {
		fg.stmt(s)
	}
	if b.Trailing != nil {
		fg.expr(b.Trailing)
		fg.emit(bc.Ret, 0, 0, 0)
	} else {
		fg.emit(bc.RetUnit, 0, 0, 0)
	}
}

// ---------------------------------------------------------------- statements

func (fg *fnGen) stmt(s ast.Stmt) {
	switch s := s.(type) {
	case *ast.LetStmt:
		fg.expr(s.Init)
		fg.irrefutable(s.Pat)
	case *ast.VarStmt:
		fg.expr(s.Init)
		s.Local.Slot = fg.alloc()
		fg.emit(bc.StoreLocal, s.Local.Slot, 0, 0)
	case *ast.AssignStmt:
		switch t := s.Target.(type) {
		case *ast.PathExpr:
			fg.expr(s.Value)
			fg.emit(bc.StoreLocal, s.Local.Slot, 0, 0)
		case *ast.IndexExpr:
			fg.expr(t.X)
			fg.expr(t.I)
			fg.expr(s.Value)
			fg.emit(bc.IndexSet, 0, 0, 0)
		}
	case *ast.ExprStmt:
		fg.expr(s.X)
		fg.emit(bc.Pop, 0, 0, 0)
	case *ast.ReturnStmt:
		if s.X == nil {
			fg.emit(bc.RetUnit, 0, 0, 0)
		} else {
			fg.expr(s.X)
			fg.emit(bc.Ret, 0, 0, 0)
		}
	case *ast.WhileStmt:
		mark := fg.next
		lc := &loopCtx{save: fg.alloc(), breaks: newLabel()}
		fg.emit(bc.SaveSP, lc.save, 0, 0)
		top := len(fg.code)
		lc.contTarget = top
		fg.loops = append(fg.loops, lc)
		fg.expr(s.Cond)
		fg.jump(bc.JumpIfFalse, lc.breaks)
		fg.loopBody(s.Body)
		fg.emit(bc.Jump, top, 0, 0)
		fg.loops = fg.loops[:len(fg.loops)-1]
		fg.bind(lc.breaks)
		fg.next = mark
	case *ast.ForStmt:
		fg.forStmt(s)
	case *ast.BreakStmt:
		lc := fg.loops[len(fg.loops)-1]
		fg.emit(bc.RestoreSP, lc.save, 0, 0)
		fg.jump(bc.Jump, lc.breaks)
	case *ast.ContinueStmt:
		lc := fg.loops[len(fg.loops)-1]
		fg.emit(bc.RestoreSP, lc.save, 0, 0)
		if lc.contTarget >= 0 {
			fg.emit(bc.Jump, lc.contTarget, 0, 0)
		} else {
			lc.conts = append(lc.conts, fg.emit(bc.Jump, 0, 0, 0))
		}
	}
}

func (fg *fnGen) loopBody(b *ast.Block) {
	mark := fg.next
	for _, s := range b.Stmts {
		fg.stmt(s)
	}
	if b.Trailing != nil {
		fg.expr(b.Trailing)
		fg.emit(bc.Pop, 0, 0, 0)
	}
	fg.next = mark
}

func (fg *fnGen) forStmt(s *ast.ForStmt) {
	mark := fg.next
	lc := &loopCtx{breaks: newLabel(), contTarget: -1}
	if s.End == nil {
		lst := fg.alloc()
		idx := fg.alloc()
		lc.save = fg.alloc()
		fg.expr(s.Iter)
		fg.emit(bc.StoreLocal, lst, 0, 0)
		fg.emit(bc.PushConst, int(fg.c.constant(bc.Const{Kind: bc.ConstInt, I: 0})), 0, 0)
		fg.emit(bc.StoreLocal, idx, 0, 0)
		fg.emit(bc.SaveSP, lc.save, 0, 0)
		top := len(fg.code)
		lc.contTarget = top
		fg.loops = append(fg.loops, lc)
		i := fg.emit(bc.IterNext, idx, lst, 0)
		inner := fg.next
		fg.irrefutable(s.Pat)
		fg.loopBody(s.Body)
		fg.next = inner
		fg.emit(bc.Jump, top, 0, 0)
		fg.loops = fg.loops[:len(fg.loops)-1]
		fg.code[i].C = int32(len(fg.code))
		fg.bind(lc.breaks)
	} else {
		cur := fg.alloc()
		end := fg.alloc()
		lc.save = fg.alloc()
		fg.expr(s.Iter)
		fg.emit(bc.StoreLocal, cur, 0, 0)
		fg.expr(s.End)
		fg.emit(bc.StoreLocal, end, 0, 0)
		fg.emit(bc.SaveSP, lc.save, 0, 0)
		top := len(fg.code)
		fg.loops = append(fg.loops, lc)
		fg.emit(bc.LoadLocal, cur, 0, 0)
		fg.emit(bc.LoadLocal, end, 0, 0)
		fg.emit(bc.Lt, 0, 0, 0)
		fg.jump(bc.JumpIfFalse, lc.breaks)
		inner := fg.next
		fg.emit(bc.LoadLocal, cur, 0, 0)
		fg.irrefutable(s.Pat)
		fg.loopBody(s.Body)
		fg.next = inner
		contAt := len(fg.code)
		for _, j := range lc.conts {
			fg.code[j].A = int32(contAt)
		}
		fg.emit(bc.LoadLocal, cur, 0, 0)
		fg.emit(bc.PushConst, int(fg.c.constant(bc.Const{Kind: bc.ConstInt, I: 1})), 0, 0)
		fg.emit(bc.AddI, 0, 0, 0)
		fg.emit(bc.StoreLocal, cur, 0, 0)
		fg.emit(bc.Jump, top, 0, 0)
		fg.loops = fg.loops[:len(fg.loops)-1]
		fg.bind(lc.breaks)
	}
	fg.next = mark
}

// irrefutable binds an irrefutable pattern to the value on top of the stack.
func (fg *fnGen) irrefutable(p ast.Pattern) {
	switch p := p.(type) {
	case *ast.WildPat:
		fg.emit(bc.Pop, 0, 0, 0)
		return
	case *ast.IdentPat:
		if p.Variant == nil {
			p.Local.Slot = fg.alloc()
			fg.emit(bc.StoreLocal, p.Local.Slot, 0, 0)
			return
		}
	}
	fail := newLabel()
	fg.pat(p, fail)
	if len(fail.patches) > 0 {
		end := newLabel()
		fg.jump(bc.Jump, end)
		fg.bind(fail)
		fg.emit(bc.NoMatch, 0, 0, 0)
		fg.bind(end)
	}
}

// ---------------------------------------------------------------- patterns

// pat compiles a pattern test. Stack on entry: [..., V]. On success the
// value is consumed and bindings are stored; on failure control jumps to fail
// with the value consumed.
func (fg *fnGen) pat(p ast.Pattern, fail *label) {
	switch p := p.(type) {
	case *ast.WildPat:
		fg.emit(bc.Pop, 0, 0, 0)
	case *ast.IdentPat:
		if p.Variant == nil {
			p.Local.Slot = fg.alloc()
			fg.emit(bc.StoreLocal, p.Local.Slot, 0, 0)
			return
		}
		fg.composite(fail, func(cleanup *label) {
			fg.variantTest(p.Variant, cleanup)
		})
	case *ast.LitPat:
		switch p.Kind {
		case ast.LitInt:
			fg.emit(bc.PushConst, int(fg.c.constant(bc.Const{Kind: bc.ConstInt, I: p.Int})), 0, 0)
		case ast.LitChar:
			fg.emit(bc.PushConst, int(fg.c.constant(bc.Const{Kind: bc.ConstChar, I: p.Int})), 0, 0)
		case ast.LitStr:
			fg.emit(bc.PushConst, int(fg.c.constant(bc.Const{Kind: bc.ConstStr, S: p.Str})), 0, 0)
		case ast.LitBool:
			if p.Int != 0 {
				fg.emit(bc.PushTrue, 0, 0, 0)
			} else {
				fg.emit(bc.PushFalse, 0, 0, 0)
			}
		}
		fg.emit(bc.Eq, 0, 0, 0)
		fg.jump(bc.JumpIfFalse, fail)
	case *ast.VariantPat:
		fg.composite(fail, func(cleanup *label) {
			fg.variantTest(p.Variant, cleanup)
			for i, a := range p.Args {
				fg.sub(a, bc.GetPayload, i, cleanup)
			}
		})
	case *ast.TuplePat:
		fg.composite(fail, func(cleanup *label) {
			for i, a := range p.Elems {
				fg.sub(a, bc.GetTuple, i, cleanup)
			}
		})
	case *ast.StructPat:
		fg.composite(fail, func(cleanup *label) {
			for _, f := range p.Fields {
				if f.Pat == nil {
					fg.emit(bc.Dup, 0, 0, 0)
					fg.emit(bc.GetField, f.Index, 0, 0)
					f.Local.Slot = fg.alloc()
					fg.emit(bc.StoreLocal, f.Local.Slot, 0, 0)
				} else {
					fg.sub(f.Pat, bc.GetField, f.Index, cleanup)
				}
			}
		})
	case *ast.ListPat:
		fg.composite(fail, func(cleanup *label) {
			n := len(p.Elems)
			fg.emit(bc.SeqLen, 0, 0, 0)
			fg.emit(bc.PushConst, int(fg.c.constant(bc.Const{Kind: bc.ConstInt, I: int64(n)})), 0, 0)
			if p.HasRest {
				fg.emit(bc.Ge, 0, 0, 0)
			} else {
				fg.emit(bc.Eq, 0, 0, 0)
			}
			fg.jump(bc.JumpIfFalse, cleanup)
			for i, e := range p.Elems {
				if _, ok := e.(*ast.WildPat); ok {
					continue
				}
				fg.emit(bc.PushConst, int(fg.c.constant(bc.Const{Kind: bc.ConstInt, I: int64(i)})), 0, 0)
				fg.emit(bc.SeqGet, 0, 0, 0)
				fg.pat(e, cleanup)
			}
			if p.Rest != nil {
				fg.emit(bc.ListRest, n, 0, 0)
				p.Local.Slot = fg.alloc()
				fg.emit(bc.StoreLocal, p.Local.Slot, 0, 0)
			}
		})
	}
}

func (fg *fnGen) variantTest(v *types.Variant, cleanup *label) {
	if len(v.Decl.Variants) == 1 {
		return
	}
	fg.emit(bc.IsVariant, v.Index, 0, 0)
	fg.jump(bc.JumpIfFalse, cleanup)
}

// sub matches a sub-pattern against a component of the value on top of the
// stack, which stays in place.
func (fg *fnGen) sub(p ast.Pattern, get bc.Op, idx int, cleanup *label) {
	if _, ok := p.(*ast.WildPat); ok {
		return
	}
	fg.emit(bc.Dup, 0, 0, 0)
	fg.emit(get, idx, 0, 0)
	fg.pat(p, cleanup)
}

// composite wraps a pattern that inspects the value on top of the stack in
// place: body runs with the value present and jumps to its cleanup label on
// failure; on success the value is popped.
func (fg *fnGen) composite(fail *label, body func(cleanup *label)) {
	cleanup := newLabel()
	body(cleanup)
	fg.emit(bc.Pop, 0, 0, 0)
	if len(cleanup.patches) == 0 {
		return
	}
	end := newLabel()
	fg.jump(bc.Jump, end)
	fg.bind(cleanup)
	fg.emit(bc.Pop, 0, 0, 0)
	fg.jump(bc.Jump, fail)
	fg.bind(end)
}

// ---------------------------------------------------------------- expressions

func (fg *fnGen) loadVar(l *types.Local) {
	if l.Owner == fg.body {
		fg.emit(bc.LoadLocal, l.Slot, 0, 0)
		return
	}
	for i, c := range fg.body.Captures {
		if c == l {
			fg.emit(bc.LoadUpval, i, 0, 0)
			return
		}
	}
	panic("compiler: variable is neither local nor captured: " + l.Name)
}

func (fg *fnGen) expr(e ast.Expr) {
	switch e := e.(type) {
	case *ast.IntLit:
		fg.emit(bc.PushConst, int(fg.c.constant(bc.Const{Kind: bc.ConstInt, I: e.Val})), 0, 0)
	case *ast.FloatLit:
		fg.emit(bc.PushConst, int(fg.c.constant(bc.Const{Kind: bc.ConstFloat, F: e.Val})), 0, 0)
	case *ast.StrLit:
		fg.emit(bc.PushConst, int(fg.c.constant(bc.Const{Kind: bc.ConstStr, S: e.Val})), 0, 0)
	case *ast.CharLit:
		fg.emit(bc.PushConst, int(fg.c.constant(bc.Const{Kind: bc.ConstChar, I: int64(e.Val)})), 0, 0)
	case *ast.BoolLit:
		if e.Val {
			fg.emit(bc.PushTrue, 0, 0, 0)
		} else {
			fg.emit(bc.PushFalse, 0, 0, 0)
		}
	case *ast.SelfExpr:
		fg.loadVar(e.Local)
	case *ast.PathExpr:
		switch e.Kind {
		case ast.RefLocal:
			fg.loadVar(e.Local)
		case ast.RefVariant:
			fg.emit(bc.MakeEnum, e.Variant.Decl.ID, e.Variant.Index, 0)
		default:
			panic("compiler: unresolved path " + e.Name.Name)
		}
	case *ast.UnaryExpr:
		fg.expr(e.X)
		switch e.Op {
		case "-":
			if e.Float {
				fg.emit(bc.NegF, 0, 0, 0)
			} else {
				fg.emit(bc.NegI, 0, 0, 0)
			}
		case "!":
			fg.emit(bc.NotB, 0, 0, 0)
		case "~":
			fg.emit(bc.BNot, 0, 0, 0)
		}
	case *ast.BinaryExpr:
		fg.binary(e)
	case *ast.CallExpr:
		fg.call(e)
	case *ast.MethodCallExpr:
		fg.expr(e.Recv)
		for _, a := range e.Args {
			fg.expr(a)
		}
		fg.emit(bc.CallMethod, e.Trait.ID, e.Method, len(e.Args))
	case *ast.IndexExpr:
		fg.expr(e.X)
		fg.expr(e.I)
		fg.emit(bc.IndexGet, 0, 0, 0)
	case *ast.FieldExpr:
		fg.expr(e.X)
		fg.emit(bc.GetField, e.Index, 0, 0)
	case *ast.StructLit:
		fg.structLit(e)
	case *ast.ListLit:
		for _, x := range e.Elems {
			fg.expr(x)
		}
		fg.emit(bc.MakeList, len(e.Elems), 0, 0)
	case *ast.MapLit:
		for _, en := range e.Entries {
			fg.expr(en.K)
			fg.expr(en.V)
		}
		fg.emit(bc.MakeMap, len(e.Entries), 0, 0)
	case *ast.TupleLit:
		for _, x := range e.Elems {
			fg.expr(x)
		}
		fg.emit(bc.MakeTuple, len(e.Elems), 0, 0)
	case *ast.Lambda:
		fg.lambda(e)
	case *ast.IfExpr:
		fg.ifExpr(e)
	case *ast.MatchExpr:
		fg.match(e)
	case *ast.Block:
		mark := fg.next
		for _, s := range e.Stmts {
			fg.stmt(s)
		}
		if e.Trailing != nil {
			fg.expr(e.Trailing)
		} else {
			fg.emit(bc.PushUnit, 0, 0, 0)
		}
		fg.next = mark
	default:
		panic("compiler: unhandled expression")
	}
}

func (fg *fnGen) binary(e *ast.BinaryExpr) {
	switch e.Op {
	case "&&":
		fg.expr(e.L)
		short := newLabel()
		end := newLabel()
		fg.jump(bc.JumpIfFalse, short)
		fg.expr(e.R)
		fg.jump(bc.Jump, end)
		fg.bind(short)
		fg.emit(bc.PushFalse, 0, 0, 0)
		fg.bind(end)
		return
	case "||":
		fg.expr(e.L)
		short := newLabel()
		end := newLabel()
		fg.jump(bc.JumpIfTrue, short)
		fg.expr(e.R)
		fg.jump(bc.Jump, end)
		fg.bind(short)
		fg.emit(bc.PushTrue, 0, 0, 0)
		fg.bind(end)
		return
	}
	fg.expr(e.L)
	fg.expr(e.R)
	var op bc.Op
	switch e.Op {
	case "+":
		op = pick(e.Float, bc.AddF, bc.AddI)
	case "-":
		op = pick(e.Float, bc.SubF, bc.SubI)
	case "*":
		op = pick(e.Float, bc.MulF, bc.MulI)
	case "/":
		op = pick(e.Float, bc.DivF, bc.DivI)
	case "%":
		op = bc.ModI
	case "++":
		op = pick(e.List, bc.ConcatList, bc.ConcatStr)
	case "&":
		op = bc.BAnd
	case "|":
		op = bc.BOr
	case "^":
		op = bc.BXor
	case "<<":
		op = bc.Shl
	case ">>":
		op = bc.Shr
	case "==":
		op = bc.Eq
	case "!=":
		op = bc.Ne
	case "<":
		op = bc.Lt
	case "<=":
		op = bc.Le
	case ">":
		op = bc.Gt
	case ">=":
		op = bc.Ge
	}
	fg.emit(op, 0, 0, 0)
}

func pick(cond bool, a, b bc.Op) bc.Op {
	if cond {
		return a
	}
	return b
}

func (fg *fnGen) call(e *ast.CallExpr) {
	switch e.Kind {
	case ast.CallFunc:
		for _, a := range e.Args {
			fg.expr(a)
		}
		fg.emit(bc.Call, e.Func.Index, len(e.Args), 0)
	case ast.CallBuiltin:
		for _, a := range e.Args {
			fg.expr(a)
		}
		fg.emit(bc.CallBuiltin, e.Func.Builtin, len(e.Args), 0)
	case ast.CallVariant:
		for _, a := range e.Args {
			fg.expr(a)
		}
		fg.emit(bc.MakeEnum, e.Variant.Decl.ID, e.Variant.Index, len(e.Args))
	case ast.CallValue:
		fg.expr(e.Callee)
		for _, a := range e.Args {
			fg.expr(a)
		}
		fg.emit(bc.CallValue, len(e.Args), 0, 0)
	case ast.CallMethod:
		for _, a := range e.Args {
			fg.expr(a)
		}
		fg.emit(bc.CallMethod, e.Trait.ID, e.Method, len(e.Args)-1)
	default:
		panic("compiler: unresolved call")
	}
}

func (fg *fnGen) structLit(e *ast.StructLit) {
	identity := true
	for i, o := range e.Order {
		if o != i {
			identity = false
		}
	}
	if identity {
		for _, f := range e.Fields {
			fg.expr(f.Value)
		}
		fg.emit(bc.MakeStruct, e.Decl.ID, len(e.Fields), 0)
		return
	}
	mark := fg.next
	tmps := make([]int, len(e.Fields))
	for i, f := range e.Fields {
		fg.expr(f.Value)
		tmps[i] = fg.alloc()
		fg.emit(bc.StoreLocal, tmps[i], 0, 0)
	}
	for d := range e.Fields {
		for i, o := range e.Order {
			if o == d {
				fg.emit(bc.LoadLocal, tmps[i], 0, 0)
			}
		}
	}
	fg.emit(bc.MakeStruct, e.Decl.ID, len(e.Fields), 0)
	fg.next = mark
}

func (fg *fnGen) lambda(l *ast.Lambda) {
	c := fg.c
	idx := len(c.out.Funcs)
	c.out.Funcs = append(c.out.Funcs, nil)
	lg := newFnGen(c, l.Func.Body)
	switch b := l.Body.(type) {
	case *ast.Block:
		lg.funcBlock(b)
	default:
		lg.expr(l.Body)
		lg.emit(bc.Ret, 0, 0, 0)
	}
	c.out.Funcs[idx] = lg.finish("<lambda>")
	for _, cp := range l.Func.Body.Captures {
		fg.loadVar(cp)
	}
	fg.emit(bc.MakeClosure, idx, len(l.Func.Body.Captures), 0)
}

func (fg *fnGen) ifExpr(e *ast.IfExpr) {
	fg.expr(e.Cond)
	els := newLabel()
	end := newLabel()
	fg.jump(bc.JumpIfFalse, els)
	fg.expr(e.Then)
	fg.jump(bc.Jump, end)
	fg.bind(els)
	if e.Else != nil {
		fg.expr(e.Else)
	} else {
		fg.emit(bc.PushUnit, 0, 0, 0)
	}
	fg.bind(end)
}

func (fg *fnGen) match(m *ast.MatchExpr) {
	mark := fg.next
	fg.expr(m.Scr)
	tmp := fg.alloc()
	fg.emit(bc.StoreLocal, tmp, 0, 0)
	end := newLabel()
	for _, arm := range m.Arms {
		armMark := fg.next
		fg.emit(bc.LoadLocal, tmp, 0, 0)
		fail := newLabel()
		fg.pat(arm.Pat, fail)
		if arm.Guard != nil {
			fg.expr(arm.Guard)
			fg.jump(bc.JumpIfFalse, fail)
		}
		fg.expr(arm.Body)
		fg.jump(bc.Jump, end)
		fg.bind(fail)
		fg.next = armMark
	}
	fg.emit(bc.NoMatch, 0, 0, 0)
	fg.bind(end)
	fg.next = mark
}
