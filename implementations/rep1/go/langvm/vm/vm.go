// Package vm executes bytecode programs for the Vellum stack machine
// (SPEC.md section 16) and implements the standard library built-ins.
package vm

import (
	"bufio"
	"io"

	bc "langvm/bytecode"
)

const maxDepth = 20000

// Panic is the error returned by Run when the program panics at run time.
type Panic struct{ Msg string }

func (p *Panic) Error() string { return "panic: " + p.Msg }

type vmPanic struct{ msg string }

type frame struct {
	code  []bc.Instr
	up    []Value
	pc    int
	base  int
	retSP int
}

type implTable struct {
	methods []int32
}

// VM is a virtual machine instance running one program.
type VM struct {
	prog   *bc.Program
	consts []Value
	funcs  []*bc.Function
	stack  []Value
	sp     int
	frames []frame
	depth  int
	out    *bufio.Writer
	impls  [][]*implTable // trait -> head constructor -> methods
}

// Run executes the program, writing its output to w. It returns nil when the
// program finishes normally and a *Panic when it panics; the output produced
// before a panic has been written to w. The panic line itself is not written.
func Run(p *bc.Program, w io.Writer) (err error) {
	v := &VM{prog: p, funcs: p.Funcs, out: bufio.NewWriterSize(w, 1<<16)}
	v.consts = make([]Value, len(p.Consts))
	for i, c := range p.Consts {
		v.consts[i] = constValue(c)
	}
	v.stack = make([]Value, 1024)
	v.impls = make([][]*implTable, p.NumTraits)
	for _, e := range p.Impls {
		if e.Ctor >= len(v.impls[e.Trait]) {
			n := make([]*implTable, e.Ctor+1)
			copy(n, v.impls[e.Trait])
			v.impls[e.Trait] = n
		}
		v.impls[e.Trait][e.Ctor] = &implTable{methods: e.Methods}
	}
	defer func() {
		if r := recover(); r != nil {
			vp, ok := r.(vmPanic)
			if !ok {
				v.out.Flush()
				panic(r)
			}
			err = &Panic{Msg: vp.msg}
		}
		v.out.Flush()
	}()
	v.run(p.Main, nil, 0)
	return nil
}

func (v *VM) panicf(msg string) { panic(vmPanic{msg}) }

func (v *VM) grow() {
	n := make([]Value, len(v.stack)*2)
	copy(n, v.stack[:v.sp])
	v.stack = n
}

func (v *VM) push(x Value) {
	if v.sp == len(v.stack) {
		v.grow()
	}
	v.stack[v.sp] = x
	v.sp++
}

func (v *VM) pop() Value {
	v.sp--
	return v.stack[v.sp]
}

func (v *VM) reserve(n int) {
	for v.sp+n > len(v.stack) {
		v.grow()
	}
	v.sp += n
}

// callClosure calls a closure from a built-in and returns its result.
func (v *VM) callClosure(cl *Closure, args ...Value) Value {
	for _, a := range args {
		v.push(a)
	}
	return v.run(int(cl.Fn), cl.Up, v.sp-len(args))
}

// run enters function fn (its arguments are the top NParams stack entries)
// and executes until that frame returns, whereupon the stack is cut back to
// retSP and the result is returned.
func (v *VM) run(fn int, up []Value, retSP int) Value {
	stopDepth := v.depth
	if v.depth >= maxDepth {
		v.panicf("call stack overflow")
	}
	f := v.funcs[fn]
	v.depth++
	base := v.sp - f.NParams
	v.reserve(f.NLocals - f.NParams)
	code := f.Code
	pc := 0
	consts := v.consts
	for {
		in := code[pc]
		pc++
		switch in.Op {
		case bc.PushConst:
			v.push(consts[in.A])
		case bc.PushTrue:
			v.push(true)
		case bc.PushFalse:
			v.push(false)
		case bc.PushUnit:
			v.push(unit)
		case bc.LoadLocal:
			v.push(v.stack[base+int(in.A)])
		case bc.StoreLocal:
			v.sp--
			v.stack[base+int(in.A)] = v.stack[v.sp]
		case bc.LoadUpval:
			v.push(up[in.A])
		case bc.Pop:
			v.sp--
		case bc.Dup:
			v.push(v.stack[v.sp-1])
		case bc.MakeClosure:
			n := int(in.B)
			var u []Value
			if n > 0 {
				u = make([]Value, n)
				copy(u, v.stack[v.sp-n:v.sp])
				v.sp -= n
			}
			v.push(&Closure{Fn: in.A, Up: u})
		case bc.Call:
			if v.depth >= maxDepth {
				v.panicf("call stack overflow")
			}
			v.frames = append(v.frames, frame{code, up, pc, base, retSP})
			v.depth++
			nf := v.funcs[in.A]
			base = v.sp - int(in.B)
			retSP = base
			v.reserve(nf.NLocals - nf.NParams)
			code = nf.Code
			pc = 0
			up = nil
		case bc.CallValue:
			argc := int(in.A)
			cl := v.stack[v.sp-argc-1].(*Closure)
			if v.depth >= maxDepth {
				v.panicf("call stack overflow")
			}
			v.frames = append(v.frames, frame{code, up, pc, base, retSP})
			v.depth++
			nf := v.funcs[cl.Fn]
			base = v.sp - argc
			retSP = base - 1
			v.reserve(nf.NLocals - nf.NParams)
			code = nf.Code
			pc = 0
			up = cl.Up
		case bc.CallMethod:
			argc := int(in.C)
			recv := v.stack[v.sp-argc-1]
			impl := v.impls[in.A][ctorOf(recv)]
			if v.depth >= maxDepth {
				v.panicf("call stack overflow")
			}
			v.frames = append(v.frames, frame{code, up, pc, base, retSP})
			v.depth++
			nf := v.funcs[impl.methods[in.B]]
			base = v.sp - argc - 1
			retSP = base
			v.reserve(nf.NLocals - nf.NParams)
			code = nf.Code
			pc = 0
			up = nil
		case bc.CallBuiltin:
			argc := int(in.B)
			args := v.stack[v.sp-argc : v.sp]
			r := builtinTable[in.A](v, args)
			v.sp -= argc
			v.push(r)
		case bc.Ret, bc.RetUnit:
			var res Value = unit
			if in.Op == bc.Ret {
				res = v.stack[v.sp-1]
			}
			v.sp = retSP
			v.depth--
			if v.depth == stopDepth {
				return res
			}
			fr := v.frames[len(v.frames)-1]
			v.frames = v.frames[:len(v.frames)-1]
			code, up, pc, base, retSP = fr.code, fr.up, fr.pc, fr.base, fr.retSP
			v.push(res)
		case bc.AddI:
			b := v.pop().(int64)
			v.stack[v.sp-1] = v.stack[v.sp-1].(int64) + b
		case bc.SubI:
			b := v.pop().(int64)
			v.stack[v.sp-1] = v.stack[v.sp-1].(int64) - b
		case bc.MulI:
			b := v.pop().(int64)
			v.stack[v.sp-1] = v.stack[v.sp-1].(int64) * b
		case bc.DivI:
			b := v.pop().(int64)
			if b == 0 {
				v.panicf("divide by zero")
			}
			v.stack[v.sp-1] = v.stack[v.sp-1].(int64) / b
		case bc.ModI:
			b := v.pop().(int64)
			if b == 0 {
				v.panicf("modulo by zero")
			}
			v.stack[v.sp-1] = v.stack[v.sp-1].(int64) % b
		case bc.NegI:
			v.stack[v.sp-1] = -v.stack[v.sp-1].(int64)
		case bc.BNot:
			v.stack[v.sp-1] = ^v.stack[v.sp-1].(int64)
		case bc.BAnd:
			b := v.pop().(int64)
			v.stack[v.sp-1] = v.stack[v.sp-1].(int64) & b
		case bc.BOr:
			b := v.pop().(int64)
			v.stack[v.sp-1] = v.stack[v.sp-1].(int64) | b
		case bc.BXor:
			b := v.pop().(int64)
			v.stack[v.sp-1] = v.stack[v.sp-1].(int64) ^ b
		case bc.Shl:
			b := v.pop().(int64)
			if b < 0 || b > 63 {
				v.panicf("shift amount out of range")
			}
			v.stack[v.sp-1] = v.stack[v.sp-1].(int64) << uint(b)
		case bc.Shr:
			b := v.pop().(int64)
			if b < 0 || b > 63 {
				v.panicf("shift amount out of range")
			}
			v.stack[v.sp-1] = v.stack[v.sp-1].(int64) >> uint(b)
		case bc.AddF:
			b := v.pop().(float64)
			v.stack[v.sp-1] = v.stack[v.sp-1].(float64) + b
		case bc.SubF:
			b := v.pop().(float64)
			v.stack[v.sp-1] = v.stack[v.sp-1].(float64) - b
		case bc.MulF:
			b := v.pop().(float64)
			v.stack[v.sp-1] = v.stack[v.sp-1].(float64) * b
		case bc.DivF:
			b := v.pop().(float64)
			v.stack[v.sp-1] = v.stack[v.sp-1].(float64) / b
		case bc.NegF:
			v.stack[v.sp-1] = -v.stack[v.sp-1].(float64)
		case bc.NotB:
			v.stack[v.sp-1] = !v.stack[v.sp-1].(bool)
		case bc.Eq:
			b := v.pop()
			v.stack[v.sp-1] = equal(v.stack[v.sp-1], b)
		case bc.Ne:
			b := v.pop()
			v.stack[v.sp-1] = !equal(v.stack[v.sp-1], b)
		case bc.Lt:
			b := v.pop()
			v.stack[v.sp-1] = less(v.stack[v.sp-1], b)
		case bc.Le:
			b := v.pop()
			v.stack[v.sp-1] = lessEq(v.stack[v.sp-1], b)
		case bc.Gt:
			b := v.pop()
			v.stack[v.sp-1] = less(b, v.stack[v.sp-1])
		case bc.Ge:
			b := v.pop()
			v.stack[v.sp-1] = lessEq(b, v.stack[v.sp-1])
		case bc.ConcatStr:
			b := v.pop().([]rune)
			a := v.stack[v.sp-1].([]rune)
			r := make([]rune, len(a)+len(b))
			copy(r, a)
			copy(r[len(a):], b)
			v.stack[v.sp-1] = r
		case bc.ConcatList:
			b := v.pop().(*List)
			a := v.stack[v.sp-1].(*List)
			r := make([]Value, len(a.Elems)+len(b.Elems))
			copy(r, a.Elems)
			copy(r[len(a.Elems):], b.Elems)
			v.stack[v.sp-1] = newList(r)
		case bc.Jump:
			pc = int(in.A)
		case bc.JumpIfFalse:
			v.sp--
			if !v.stack[v.sp].(bool) {
				pc = int(in.A)
			}
		case bc.JumpIfTrue:
			v.sp--
			if v.stack[v.sp].(bool) {
				pc = int(in.A)
			}
		case bc.MakeList:
			n := int(in.A)
			e := make([]Value, n)
			copy(e, v.stack[v.sp-n:v.sp])
			v.sp -= n
			v.push(newList(e))
		case bc.MakeMap:
			n := int(in.A)
			m := newMap()
			s := v.stack[v.sp-2*n : v.sp]
			for i := 0; i < n; i++ {
				m.set(s[2*i], s[2*i+1])
			}
			v.sp -= 2 * n
			v.push(m)
		case bc.MakeTuple:
			n := int(in.A)
			e := make([]Value, n)
			copy(e, v.stack[v.sp-n:v.sp])
			v.sp -= n
			v.push(&Tuple{E: e})
		case bc.MakeStruct:
			n := int(in.B)
			e := make([]Value, n)
			copy(e, v.stack[v.sp-n:v.sp])
			v.sp -= n
			v.push(&Struct{Decl: in.A, F: e})
		case bc.MakeEnum:
			n := int(in.C)
			var e []Value
			if n > 0 {
				e = make([]Value, n)
				copy(e, v.stack[v.sp-n:v.sp])
				v.sp -= n
			}
			v.push(&Enum{Decl: in.A, Variant: in.B, P: e})
		case bc.GetField:
			v.stack[v.sp-1] = v.stack[v.sp-1].(*Struct).F[in.A]
		case bc.GetPayload:
			v.stack[v.sp-1] = v.stack[v.sp-1].(*Enum).P[in.A]
		case bc.GetTuple:
			v.stack[v.sp-1] = v.stack[v.sp-1].(*Tuple).E[in.A]
		case bc.IndexGet:
			idx := v.pop()
			v.stack[v.sp-1] = v.indexGet(v.stack[v.sp-1], idx)
		case bc.IndexSet:
			val := v.pop()
			idx := v.pop()
			cont := v.pop()
			v.indexSet(cont, idx, val)
		case bc.IsVariant:
			v.push(v.stack[v.sp-1].(*Enum).Variant == in.A)
		case bc.SeqLen:
			switch s := v.stack[v.sp-1].(type) {
			case *List:
				v.push(int64(len(s.Elems)))
			case []rune:
				v.push(int64(len(s)))
			}
		case bc.SeqGet:
			i := v.pop().(int64)
			switch s := v.stack[v.sp-1].(type) {
			case *List:
				v.push(s.Elems[i])
			case []rune:
				v.push(s[i])
			}
		case bc.ListRest:
			l := v.stack[v.sp-1].(*List)
			r := make([]Value, len(l.Elems)-int(in.A))
			copy(r, l.Elems[in.A:])
			v.push(newList(r))
		case bc.NoMatch:
			v.panicf("no match")
		case bc.Panic:
			v.panicf(string(v.pop().([]rune)))
		case bc.Halt:
			return unit
		case bc.SaveSP:
			v.stack[base+int(in.A)] = int64(v.sp)
		case bc.RestoreSP:
			v.sp = int(v.stack[base+int(in.A)].(int64))
		case bc.IterNext:
			idx := v.stack[base+int(in.A)].(int64)
			switch s := v.stack[base+int(in.B)].(type) {
			case *List:
				if int(idx) >= len(s.Elems) {
					pc = int(in.C)
					continue
				}
				v.push(s.Elems[idx])
			case []rune:
				if int(idx) >= len(s) {
					pc = int(in.C)
					continue
				}
				v.push(s[idx])
			}
			v.stack[base+int(in.A)] = idx + 1
		default:
			panic("vm: bad opcode")
		}
	}
}

func (v *VM) indexGet(cont, idx Value) Value {
	switch c := cont.(type) {
	case *List:
		i := idx.(int64)
		if i < 0 || i >= int64(len(c.Elems)) {
			v.panicf("index out of bounds")
		}
		return c.Elems[i]
	case []rune:
		i := idx.(int64)
		if i < 0 || i >= int64(len(c)) {
			v.panicf("index out of bounds")
		}
		return c[i]
	case *Map:
		val, ok := c.get(idx)
		if !ok {
			v.panicf("missing key")
		}
		return val
	}
	panic("vm: bad index container")
}

func (v *VM) indexSet(cont, idx, val Value) {
	switch c := cont.(type) {
	case *List:
		i := idx.(int64)
		if i < 0 || i >= int64(len(c.Elems)) {
			v.panicf("index out of bounds")
		}
		c.Elems[i] = val
	case *Map:
		c.set(idx, val)
	}
}
