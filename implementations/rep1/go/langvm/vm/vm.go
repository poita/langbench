// Package vm is the Vellum virtual machine: a switch-dispatched stack machine
// over the bytecode of package bytecode, plus the 132-function standard
// library (SPEC sections 14 to 16).
package vm

import (
	"math"

	"langvm/builtins"
	"langvm/bytecode"
)

// MaxFrames is the call-depth limit (SPEC 14.5).
const MaxFrames = 20000

type frame struct {
	fn   *bytecode.Func
	pc   int  // saved pc while a callee runs
	base int  // local slot 0
	ret  int  // stack index where the result is stored on return
	cl   *Obj // running closure (for upvalues), or nil
}

// VM is the virtual machine state.
type VM struct {
	prog     *bytecode.Program
	consts   []Value
	stack    []Value
	frames   []frame
	nframes  int
	sp       int // sp at the time of the last built-in call (for re-entry)
	out      []byte
	builtins []BuiltinFn
	units    [][]Value // payload-less enum values per declaration
	argbuf   [4]Value
}

// New returns a VM with empty output and no program loaded.
func New() *VM { return &VM{} }

// Load prepares the VM to run prog.
func Load(prog *bytecode.Program) *VM {
	m := &VM{prog: prog}
	m.consts = make([]Value, len(prog.Consts))
	for i, c := range prog.Consts {
		switch c.Kind {
		case bytecode.ConstInt:
			m.consts[i] = Int(c.Int)
		case bytecode.ConstFloat:
			m.consts[i] = Float(c.Float)
		case bytecode.ConstChar:
			m.consts[i] = Char(rune(c.Int))
		default:
			m.consts[i] = Str(c.Str)
		}
	}
	m.builtins = make([]BuiltinFn, len(builtins.Specs))
	for i, s := range builtins.Specs {
		m.builtins[i] = registry[s.Name]
	}
	m.units = make([][]Value, len(prog.Types))
	for d, t := range prog.Types {
		m.units[d] = make([]Value, len(t.Variants))
		for v := range t.Variants {
			if d == OptionDecl && v == VarNone {
				m.units[d][v] = NoneV
			} else {
				m.units[d][v] = Value{P: &Obj{Kind: KEnum, Decl: int32(d), Var: int32(v)}}
			}
		}
	}
	m.stack = make([]Value, 1<<16)
	m.frames = make([]frame, MaxFrames)
	return m
}

// Run executes the program's main function and returns everything the
// program printed, including a final panic line if it panicked.
func (m *VM) Run() []byte {
	func() {
		defer func() {
			if r := recover(); r != nil {
				if p, ok := r.(*Panic); ok {
					m.WriteRunes([]rune("panic: " + p.Msg + "\n"))
					return
				}
				panic(r)
			}
		}()
		fn := m.prog.Funcs[m.prog.Main]
		m.ensure(0, fn)
		m.pushFrame(fn, 0, 0, nil)
		m.exec(0)
	}()
	return m.out
}

func (m *VM) ensure(base int, fn *bytecode.Func) {
	need := base + fn.NSlots + fn.MaxStack + 8
	if need > len(m.stack) {
		n := len(m.stack) * 2
		if n < need {
			n = need * 2
		}
		ns := make([]Value, n)
		copy(ns, m.stack)
		m.stack = ns
	}
}

func (m *VM) pushFrame(fn *bytecode.Func, base, ret int, cl *Obj) {
	if m.nframes >= MaxFrames {
		m.Panic("call stack overflow")
	}
	m.frames[m.nframes] = frame{fn: fn, base: base, ret: ret, cl: cl}
	m.nframes++
}

// invoke calls closure f with the first n values of argbuf from a built-in
// and returns its result.
func (m *VM) invoke(f Value, n int) Value {
	cl := f.P
	fn := m.prog.Funcs[cl.Decl]
	base := m.sp
	m.ensure(base, fn)
	copy(m.stack[base:], m.argbuf[:n])
	stop := m.nframes
	m.pushFrame(fn, base, base, cl)
	saved := m.sp
	m.exec(stop)
	m.sp = saved
	return m.stack[base]
}

func (m *VM) ctorOf(v Value) int {
	switch v.P.Kind {
	case KStruct, KEnum:
		return 8 + int(v.P.Decl)
	}
	return int(v.P.Kind)
}

// exec runs until the frame count drops back to stop.
func (m *VM) exec(stop int) {
	fr := &m.frames[m.nframes-1]
	fn := fr.fn
	code := fn.Code
	base := fr.base
	stack := m.stack
	cl := fr.cl
	pc := 0
	sp := base + fn.NSlots
	consts := m.consts
	if fr.pc > 0 {
		pc = fr.pc
	}
	for {
		in := &code[pc]
		pc++
		switch in.Op {
		case bytecode.PushConst:
			stack[sp] = consts[in.A]
			sp++
		case bytecode.PushTrue:
			stack[sp] = Value{N: 1, P: tagBool}
			sp++
		case bytecode.PushFalse:
			stack[sp] = Value{P: tagBool}
			sp++
		case bytecode.PushUnit:
			stack[sp] = Unit
			sp++
		case bytecode.LoadLocal:
			stack[sp] = stack[base+int(in.A)]
			sp++
		case bytecode.StoreLocal:
			sp--
			stack[base+int(in.A)] = stack[sp]
		case bytecode.LoadUpval:
			stack[sp] = cl.V[in.A]
			sp++
		case bytecode.Pop:
			sp--
		case bytecode.Dup:
			stack[sp] = stack[sp-1]
			sp++
		case bytecode.MakeClosure:
			n := int(in.B)
			ups := make([]Value, n)
			copy(ups, stack[sp-n:sp])
			sp -= n
			stack[sp] = Value{P: &Obj{Kind: KClosure, Decl: in.A, V: ups}}
			sp++

		case bytecode.Call, bytecode.CallValue, bytecode.CallMethod:
			var callee *bytecode.Func
			var newBase, ret int
			var ncl *Obj
			switch in.Op {
			case bytecode.Call:
				callee = m.prog.Funcs[in.A]
				newBase = sp - int(in.B)
				ret = newBase
			case bytecode.CallValue:
				newBase = sp - int(in.A)
				ncl = stack[newBase-1].P
				callee = m.prog.Funcs[ncl.Decl]
				ret = newBase - 1
			default:
				argc := int(in.C)
				newBase = sp - argc - 1
				recv := stack[newBase]
				var ctor int
				switch recv.P.Kind {
				case KStruct, KEnum:
					ctor = 8 + int(recv.P.Decl)
				default:
					ctor = int(recv.P.Kind)
				}
				callee = m.prog.Funcs[m.prog.Methods[int(in.A)*m.prog.NumCtors+ctor][in.B]]
				ret = newBase
			}
			if m.nframes >= MaxFrames {
				m.Panic("call stack overflow")
			}
			if newBase+callee.NSlots+callee.MaxStack+8 > len(stack) {
				m.stack = stack
				m.ensure(newBase, callee)
				stack = m.stack
			}
			fr.pc = pc
			fr = &m.frames[m.nframes]
			m.nframes++
			fr.fn, fr.base, fr.ret, fr.cl, fr.pc = callee, newBase, ret, ncl, 0
			fn, code, base, cl = callee, callee.Code, newBase, ncl
			pc = 0
			sp = newBase + callee.NSlots

		case bytecode.CallBuiltin:
			argc := int(in.B)
			m.sp = sp
			m.stack = stack
			res := m.builtins[in.A](m, stack[sp-argc:sp])
			stack = m.stack
			sp -= argc
			stack[sp] = res
			sp++

		case bytecode.Ret, bytecode.RetUnit:
			var res Value
			if in.Op == bytecode.Ret {
				res = stack[sp-1]
			} else {
				res = Unit
			}
			ret := fr.ret
			m.nframes--
			stack[ret] = res
			if m.nframes == stop {
				return
			}
			fr = &m.frames[m.nframes-1]
			fn = fr.fn
			code = fn.Code
			base = fr.base
			cl = fr.cl
			pc = fr.pc
			sp = ret + 1

		case bytecode.AddI:
			sp--
			stack[sp-1].N += stack[sp].N
		case bytecode.SubI:
			sp--
			stack[sp-1].N -= stack[sp].N
		case bytecode.MulI:
			sp--
			stack[sp-1].N *= stack[sp].N
		case bytecode.DivI:
			sp--
			d := stack[sp].N
			if d == 0 {
				m.Panic("divide by zero")
			}
			stack[sp-1].N /= d
		case bytecode.ModI:
			sp--
			d := stack[sp].N
			if d == 0 {
				m.Panic("modulo by zero")
			}
			if d == -1 {
				stack[sp-1].N = 0
			} else {
				stack[sp-1].N %= d
			}
		case bytecode.NegI:
			stack[sp-1].N = -stack[sp-1].N
		case bytecode.BNot:
			stack[sp-1].N = ^stack[sp-1].N
		case bytecode.BAnd:
			sp--
			stack[sp-1].N &= stack[sp].N
		case bytecode.BOr:
			sp--
			stack[sp-1].N |= stack[sp].N
		case bytecode.BXor:
			sp--
			stack[sp-1].N ^= stack[sp].N
		case bytecode.Shl:
			sp--
			s := stack[sp].N
			if s < 0 || s > 63 {
				m.Panic("shift amount out of range")
			}
			stack[sp-1].N <<= uint(s)
		case bytecode.Shr:
			sp--
			s := stack[sp].N
			if s < 0 || s > 63 {
				m.Panic("shift amount out of range")
			}
			stack[sp-1].N >>= uint(s)
		case bytecode.AddF:
			sp--
			stack[sp-1].N = int64(math.Float64bits(stack[sp-1].F() + stack[sp].F()))
		case bytecode.SubF:
			sp--
			stack[sp-1].N = int64(math.Float64bits(stack[sp-1].F() - stack[sp].F()))
		case bytecode.MulF:
			sp--
			stack[sp-1].N = int64(math.Float64bits(stack[sp-1].F() * stack[sp].F()))
		case bytecode.DivF:
			sp--
			stack[sp-1].N = int64(math.Float64bits(stack[sp-1].F() / stack[sp].F()))
		case bytecode.NegF:
			stack[sp-1].N ^= math.MinInt64
		case bytecode.NotB:
			stack[sp-1].N ^= 1

		case bytecode.Eq:
			sp--
			a, b := stack[sp-1], stack[sp]
			if a.P.Kind <= KChar && a.P.Kind != KFloat {
				stack[sp-1] = Bool(a.N == b.N)
			} else {
				stack[sp-1] = Bool(Equal(a, b))
			}
		case bytecode.Ne:
			sp--
			a, b := stack[sp-1], stack[sp]
			if a.P.Kind <= KChar && a.P.Kind != KFloat {
				stack[sp-1] = Bool(a.N != b.N)
			} else {
				stack[sp-1] = Bool(!Equal(a, b))
			}
		case bytecode.Lt, bytecode.Le, bytecode.Gt, bytecode.Ge:
			sp--
			a, b := stack[sp-1], stack[sp]
			var r bool
			switch a.P.Kind {
			case KFloat:
				x, y := a.F(), b.F()
				switch in.Op {
				case bytecode.Lt:
					r = x < y
				case bytecode.Le:
					r = x <= y
				case bytecode.Gt:
					r = x > y
				default:
					r = x >= y
				}
			case KStr:
				c := CompareStr(a.P.S, b.P.S)
				switch in.Op {
				case bytecode.Lt:
					r = c < 0
				case bytecode.Le:
					r = c <= 0
				case bytecode.Gt:
					r = c > 0
				default:
					r = c >= 0
				}
			default:
				x, y := a.N, b.N
				switch in.Op {
				case bytecode.Lt:
					r = x < y
				case bytecode.Le:
					r = x <= y
				case bytecode.Gt:
					r = x > y
				default:
					r = x >= y
				}
			}
			stack[sp-1] = Bool(r)

		case bytecode.ConcatStr:
			sp--
			a, b := stack[sp-1].P.S, stack[sp].P.S
			switch {
			case len(b) == 0:
			case len(a) == 0:
				stack[sp-1] = stack[sp]
			default:
				r := make([]rune, len(a)+len(b))
				copy(r, a)
				copy(r[len(a):], b)
				stack[sp-1] = Str(r)
			}
		case bytecode.ConcatList:
			sp--
			a, b := stack[sp-1].P.V, stack[sp].P.V
			r := make([]Value, len(a)+len(b))
			copy(r, a)
			copy(r[len(a):], b)
			stack[sp-1] = List(r)

		case bytecode.Jump:
			pc = int(in.A)
		case bytecode.JumpIfFalse:
			sp--
			if stack[sp].N == 0 {
				pc = int(in.A)
			}
		case bytecode.JumpIfTrue:
			sp--
			if stack[sp].N != 0 {
				pc = int(in.A)
			}

		case bytecode.MakeList:
			n := int(in.A)
			vs := make([]Value, n)
			copy(vs, stack[sp-n:sp])
			sp -= n
			stack[sp] = List(vs)
			sp++
		case bytecode.MakeMap:
			n := int(in.A)
			mp := NewMap()
			for i := sp - 2*n; i < sp; i += 2 {
				mp.Set(stack[i], stack[i+1])
			}
			sp -= 2 * n
			stack[sp] = MapV(mp)
			sp++
		case bytecode.MakeTuple:
			n := int(in.A)
			vs := make([]Value, n)
			copy(vs, stack[sp-n:sp])
			sp -= n
			stack[sp] = Tuple(vs)
			sp++
		case bytecode.MakeStruct:
			n := int(in.B)
			vs := make([]Value, n)
			copy(vs, stack[sp-n:sp])
			sp -= n
			stack[sp] = Value{P: &Obj{Kind: KStruct, Decl: in.A, V: vs}}
			sp++
		case bytecode.MakeEnum:
			n := int(in.C)
			if n == 0 {
				stack[sp] = m.units[in.A][in.B]
				sp++
			} else {
				vs := make([]Value, n)
				copy(vs, stack[sp-n:sp])
				sp -= n
				stack[sp] = Value{P: &Obj{Kind: KEnum, Decl: in.A, Var: in.B, V: vs}}
				sp++
			}
		case bytecode.GetField, bytecode.GetPayload, bytecode.GetTuple:
			stack[sp-1] = stack[sp-1].P.V[in.A]

		case bytecode.IndexGet:
			sp--
			c, k := stack[sp-1], stack[sp]
			switch c.P.Kind {
			case KList:
				if uint64(k.N) >= uint64(len(c.P.V)) {
					m.Panic("index out of bounds")
				}
				stack[sp-1] = c.P.V[k.N]
			case KStr:
				if uint64(k.N) >= uint64(len(c.P.S)) {
					m.Panic("index out of bounds")
				}
				stack[sp-1] = Char(c.P.S[k.N])
			default:
				v, ok := c.P.M.Get(k)
				if !ok {
					m.Panic("missing key")
				}
				stack[sp-1] = v
			}
		case bytecode.IndexSet:
			sp -= 3
			c, k, v := stack[sp], stack[sp+1], stack[sp+2]
			if c.P.Kind == KList {
				if uint64(k.N) >= uint64(len(c.P.V)) {
					m.Panic("index out of bounds")
				}
				c.P.V[k.N] = v
			} else {
				c.P.M.Set(k, v)
			}

		case bytecode.NoMatch:
			m.Panic("no match")
		case bytecode.Panic:
			sp--
			m.Panic(string(stack[sp].P.S))
		case bytecode.Halt:
			m.nframes = stop
			return

		case bytecode.JumpUnlessVariant:
			if stack[base+int(in.A)].P.Var != in.B {
				pc = int(in.C)
			}
		case bytecode.JumpUnlessLen:
			if len(stack[base+int(in.A)].P.V) != int(in.B) {
				pc = int(in.C)
			}
		case bytecode.JumpUnlessLenGE:
			if len(stack[base+int(in.A)].P.V) < int(in.B) {
				pc = int(in.C)
			}
		case bytecode.PushPayload, bytecode.PushField, bytecode.PushTuple, bytecode.PushElem:
			stack[sp] = stack[base+int(in.A)].P.V[in.B]
			sp++
		case bytecode.PushRest:
			src := stack[base+int(in.A)].P.V[in.B:]
			vs := make([]Value, len(src))
			copy(vs, src)
			stack[sp] = List(vs)
			sp++
		case bytecode.SeqLenSlot:
			o := stack[base+int(in.A)].P
			if o.Kind == KList {
				stack[sp] = Int(int64(len(o.V)))
			} else {
				stack[sp] = Int(int64(len(o.S)))
			}
			sp++
		case bytecode.SeqGetSlot:
			o := stack[base+int(in.A)].P
			i := stack[base+int(in.B)].N
			if o.Kind == KList {
				stack[sp] = o.V[i]
			} else {
				stack[sp] = Char(o.S[i])
			}
			sp++
		case bytecode.IncLocal:
			stack[base+int(in.A)].N++
		}
	}
}
