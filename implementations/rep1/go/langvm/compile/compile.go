// Package compile translates a checked Vellum program into bytecode
// (SPEC section 16).
package compile

import (
	"langvm/ast"
	"langvm/bytecode"
	"langvm/check"
)

type constKey struct {
	kind bytecode.ConstKind
	i    int64
	s    string
}

type compiler struct {
	prog   *check.Program
	out    *bytecode.Program
	consts map[constKey]int
}

// Compile turns a checked program into bytecode.
func Compile(p *check.Program) *bytecode.Program {
	c := &compiler{prog: p, out: &bytecode.Program{}, consts: map[constKey]int{}}
	out := c.out
	for _, t := range p.Types {
		ti := bytecode.TypeInfo{Name: t.Name, IsEnum: t.IsEnum, NFields: len(t.Fields)}
		for _, v := range t.Variants {
			ti.Variants = append(ti.Variants, bytecode.VariantInfo{Name: v.Name, NPayload: len(v.Payload)})
		}
		out.Types = append(out.Types, ti)
	}
	out.Funcs = make([]*bytecode.Func, len(p.Funcs))
	for i, f := range p.Funcs {
		f.ID = i
	}
	for i, f := range p.Funcs {
		out.Funcs[i] = c.compileFunc(f)
	}
	out.Main = p.Main.ID
	out.NumCtors = p.NumCtors
	out.NumTrait = len(p.Traits)
	out.Methods = make([][]int32, len(p.Traits)*p.NumCtors)
	for _, impl := range p.Impls {
		tr := impl.Trait
		ids := make([]int32, len(tr.Methods))
		for i, m := range tr.Methods {
			if impl.Methods[i] != nil {
				ids[i] = int32(impl.Methods[i].ID)
			} else {
				ids[i] = int32(m.Default.ID)
			}
		}
		out.Methods[tr.ID*p.NumCtors+impl.Ctor] = ids
	}
	return out
}

func (c *compiler) constIdx(k bytecode.Const) int {
	var key constKey
	switch k.Kind {
	case bytecode.ConstInt, bytecode.ConstChar:
		key = constKey{kind: k.Kind, i: k.Int}
	case bytecode.ConstFloat:
		key = constKey{kind: k.Kind, i: int64(floatBits(k.Float))}
	default:
		key = constKey{kind: k.Kind, s: string(k.Str)}
	}
	if i, ok := c.consts[key]; ok {
		return i
	}
	i := len(c.out.Consts)
	c.out.Consts = append(c.out.Consts, k)
	c.consts[key] = i
	return i
}

func (c *compiler) compileFunc(f *check.Func) *bytecode.Func {
	fc := newFnc(c, f.Info, f.Name)
	fc.params()
	fc.block(f.Decl.Body)
	fc.emit(bytecode.Ret, 0, 0, 0)
	return fc.finish()
}

// ------------------------------------------------------------ per function

type loopCtx struct {
	depth     int
	breaks    []int
	continues []int
}

type fnc struct {
	c        *compiler
	info     *check.FnInfo
	name     string
	code     []bytecode.Instr
	next     int // next free slot
	nslots   int
	depth    int
	maxDepth int
	loops    []*loopCtx
}

func newFnc(c *compiler, info *check.FnInfo, name string) *fnc {
	return &fnc{c: c, info: info, name: name}
}

func (f *fnc) params() {
	for _, p := range f.info.Params {
		p.Slot = f.alloc()
	}
}

func (f *fnc) finish() *bytecode.Func {
	return &bytecode.Func{
		Name: f.name, NParams: len(f.info.Params), NSlots: f.nslots,
		MaxStack: f.maxDepth + 2, Code: f.code,
	}
}

func (f *fnc) alloc() int {
	s := f.next
	f.next++
	if f.next > f.nslots {
		f.nslots = f.next
	}
	return s
}

func effect(op bytecode.Op, a, b, c int32) int {
	switch op {
	case bytecode.PushConst, bytecode.PushTrue, bytecode.PushFalse, bytecode.PushUnit,
		bytecode.LoadLocal, bytecode.LoadUpval, bytecode.Dup,
		bytecode.PushPayload, bytecode.PushField, bytecode.PushTuple, bytecode.PushElem,
		bytecode.PushRest, bytecode.SeqLenSlot, bytecode.SeqGetSlot:
		return 1
	case bytecode.StoreLocal, bytecode.Pop, bytecode.JumpIfFalse, bytecode.JumpIfTrue, bytecode.Panic,
		bytecode.AddI, bytecode.SubI, bytecode.MulI, bytecode.DivI, bytecode.ModI,
		bytecode.BAnd, bytecode.BOr, bytecode.BXor, bytecode.Shl, bytecode.Shr,
		bytecode.AddF, bytecode.SubF, bytecode.MulF, bytecode.DivF,
		bytecode.Eq, bytecode.Ne, bytecode.Lt, bytecode.Le, bytecode.Gt, bytecode.Ge,
		bytecode.ConcatStr, bytecode.ConcatList, bytecode.IndexGet:
		return -1
	case bytecode.MakeClosure:
		return 1 - int(b)
	case bytecode.Call:
		return 1 - int(b)
	case bytecode.CallValue:
		return -int(a)
	case bytecode.CallBuiltin:
		return 1 - int(b)
	case bytecode.CallMethod:
		return -int(c)
	case bytecode.MakeList, bytecode.MakeTuple:
		return 1 - int(a)
	case bytecode.MakeMap:
		return 1 - 2*int(a)
	case bytecode.MakeStruct:
		return 1 - int(b)
	case bytecode.MakeEnum:
		return 1 - int(c)
	case bytecode.IndexSet:
		return -3
	case bytecode.Ret:
		return -1
	}
	return 0
}

func (f *fnc) emit(op bytecode.Op, a, b, c int) int {
	f.code = append(f.code, bytecode.Instr{Op: op, A: int32(a), B: int32(b), C: int32(c)})
	f.depth += effect(op, int32(a), int32(b), int32(c))
	if f.depth > f.maxDepth {
		f.maxDepth = f.depth
	}
	return len(f.code) - 1
}

func (f *fnc) here() int { return len(f.code) }

// patch points jump instruction i at target.
func (f *fnc) patch(i, target int) {
	in := &f.code[i]
	switch in.Op {
	case bytecode.Jump, bytecode.JumpIfFalse, bytecode.JumpIfTrue:
		in.A = int32(target)
	default:
		in.C = int32(target)
	}
}

func (f *fnc) patchAll(list []int, target int) {
	for _, i := range list {
		f.patch(i, target)
	}
}

// ---------------------------------------------------------------- locals

func (f *fnc) loadLocal(l *check.Local) {
	if l.Owner == f.info {
		f.emit(bytecode.LoadLocal, l.Slot, 0, 0)
		return
	}
	f.emit(bytecode.LoadUpval, f.info.CapIndex[l], 0, 0)
}

func (f *fnc) pushInt(n int64) {
	f.emit(bytecode.PushConst, f.c.constIdx(bytecode.Const{Kind: bytecode.ConstInt, Int: n}), 0, 0)
}

// ------------------------------------------------------------- statements

// block compiles a block as an expression: it leaves exactly one value.
func (f *fnc) block(b *ast.Block) {
	saved := f.next
	for _, s := range b.Stmts {
		f.stmt(s)
	}
	if b.Tail != nil {
		f.expr(b.Tail)
	} else {
		f.emit(bytecode.PushUnit, 0, 0, 0)
	}
	f.next = saved
}

// stmtBlock compiles a loop body: the trailing expression's value is dropped.
func (f *fnc) stmtBlock(b *ast.Block) {
	saved := f.next
	for _, s := range b.Stmts {
		f.stmt(s)
	}
	if b.Tail != nil {
		f.expr(b.Tail)
		f.emit(bytecode.Pop, 0, 0, 0)
	}
	f.next = saved
}

func (f *fnc) stmt(s ast.Stmt) {
	switch n := s.(type) {
	case *ast.LetStmt:
		f.expr(n.Init)
		if np, ok := n.Pat.(*ast.NamePat); ok && np.Local != nil {
			l := np.Local.(*check.Local)
			l.Slot = f.alloc()
			f.emit(bytecode.StoreLocal, l.Slot, 0, 0)
			return
		}
		f.destructure(n.Pat)
	case *ast.VarStmt:
		f.expr(n.Init)
		l := n.Local.(*check.Local)
		l.Slot = f.alloc()
		f.emit(bytecode.StoreLocal, l.Slot, 0, 0)
	case *ast.AssignStmt:
		switch n.Sem {
		case check.AssignLocal:
			f.expr(n.Value)
			l := n.Target.(*ast.PathExpr).Res.(*check.Local)
			f.emit(bytecode.StoreLocal, l.Slot, 0, 0)
		default:
			t := n.Target.(*ast.IndexExpr)
			f.expr(t.X)
			f.expr(t.Index)
			f.expr(n.Value)
			f.emit(bytecode.IndexSet, 0, 0, 0)
		}
	case *ast.ExprStmt:
		f.expr(n.X)
		f.emit(bytecode.Pop, 0, 0, 0)
	case *ast.ReturnStmt:
		d := f.depth
		if n.X != nil {
			f.expr(n.X)
		} else {
			f.emit(bytecode.PushUnit, 0, 0, 0)
		}
		f.emit(bytecode.Ret, 0, 0, 0)
		f.depth = d
	case *ast.WhileStmt:
		lp := &loopCtx{depth: f.depth}
		f.loops = append(f.loops, lp)
		top := f.here()
		f.expr(n.Cond)
		exit := f.emit(bytecode.JumpIfFalse, 0, 0, 0)
		f.stmtBlock(n.Body)
		f.emit(bytecode.Jump, top, 0, 0)
		end := f.here()
		f.patch(exit, end)
		f.patchAll(lp.breaks, end)
		f.patchAll(lp.continues, top)
		f.loops = f.loops[:len(f.loops)-1]
	case *ast.ForStmt:
		f.forStmt(n)
	case *ast.BreakStmt:
		lp := f.loops[len(f.loops)-1]
		d := f.depth
		for f.depth > lp.depth {
			f.emit(bytecode.Pop, 0, 0, 0)
		}
		lp.breaks = append(lp.breaks, f.emit(bytecode.Jump, 0, 0, 0))
		f.depth = d
	case *ast.ContinueStmt:
		lp := f.loops[len(f.loops)-1]
		d := f.depth
		for f.depth > lp.depth {
			f.emit(bytecode.Pop, 0, 0, 0)
		}
		lp.continues = append(lp.continues, f.emit(bytecode.Jump, 0, 0, 0))
		f.depth = d
	}
}

// destructure binds an irrefutable pattern to the value on top of the stack.
func (f *fnc) destructure(p ast.Pattern) {
	if _, ok := p.(*ast.WildPat); ok {
		f.emit(bytecode.Pop, 0, 0, 0)
		return
	}
	tmp := f.alloc()
	f.emit(bytecode.StoreLocal, tmp, 0, 0)
	var fails []int
	f.testPat(p, tmp, &fails)
}

func (f *fnc) forStmt(n *ast.ForStmt) {
	saved := f.next
	lp := &loopCtx{depth: f.depth}
	f.loops = append(f.loops, lp)
	var seq, idx, hi int
	var top, exit int
	if n.Hi != nil {
		f.expr(n.Seq)
		idx = f.alloc()
		f.emit(bytecode.StoreLocal, idx, 0, 0)
		f.expr(n.Hi)
		hi = f.alloc()
		f.emit(bytecode.StoreLocal, hi, 0, 0)
		top = f.here()
		f.emit(bytecode.LoadLocal, idx, 0, 0)
		f.emit(bytecode.LoadLocal, hi, 0, 0)
		f.emit(bytecode.Lt, 0, 0, 0)
		exit = f.emit(bytecode.JumpIfFalse, 0, 0, 0)
		f.emit(bytecode.LoadLocal, idx, 0, 0)
	} else {
		f.expr(n.Seq)
		seq = f.alloc()
		f.emit(bytecode.StoreLocal, seq, 0, 0)
		idx = f.alloc()
		f.pushInt(0)
		f.emit(bytecode.StoreLocal, idx, 0, 0)
		top = f.here()
		f.emit(bytecode.LoadLocal, idx, 0, 0)
		f.emit(bytecode.SeqLenSlot, seq, 0, 0)
		f.emit(bytecode.Lt, 0, 0, 0)
		exit = f.emit(bytecode.JumpIfFalse, 0, 0, 0)
		f.emit(bytecode.SeqGetSlot, seq, idx, 0)
	}
	inner := f.next
	if np, ok := n.Pat.(*ast.NamePat); ok && np.Local != nil {
		l := np.Local.(*check.Local)
		l.Slot = f.alloc()
		f.emit(bytecode.StoreLocal, l.Slot, 0, 0)
	} else {
		f.destructure(n.Pat)
	}
	f.stmtBlock(n.Body)
	f.next = inner
	cont := f.here()
	f.emit(bytecode.IncLocal, idx, 0, 0)
	f.emit(bytecode.Jump, top, 0, 0)
	end := f.here()
	f.patch(exit, end)
	f.patchAll(lp.breaks, end)
	f.patchAll(lp.continues, cont)
	f.loops = f.loops[:len(f.loops)-1]
	f.next = saved
}
