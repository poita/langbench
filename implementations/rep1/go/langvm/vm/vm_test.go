package vm

import (
	"testing"

	"langvm/bytecode"
)

func fn(nparams, nslots, maxstack int, code ...bytecode.Instr) *bytecode.Func {
	return &bytecode.Func{Name: "t", NParams: nparams, NSlots: nslots, MaxStack: maxstack, Code: code}
}

func in(op bytecode.Op, a, b, c int32) bytecode.Instr {
	return bytecode.Instr{Op: op, A: a, B: b, C: c}
}

// run executes a hand-assembled program whose main is funcs[0].
func run(consts []bytecode.Const, funcs ...*bytecode.Func) string {
	p := &bytecode.Program{Consts: consts, Funcs: funcs, Main: 0}
	return string(Load(p).Run())
}

func TestArithmeticAndOutput(t *testing.T) {
	// print(showInt(6 * 7))
	consts := []bytecode.Const{{Kind: bytecode.ConstInt, Int: 6}, {Kind: bytecode.ConstInt, Int: 7}}
	main := fn(0, 0, 4,
		in(bytecode.PushConst, 0, 0, 0), in(bytecode.PushConst, 1, 0, 0), in(bytecode.MulI, 0, 0, 0),
		in(bytecode.CallBuiltin, 0, 1, 0), // patched below
		in(bytecode.CallBuiltin, 0, 1, 0),
		in(bytecode.Pop, 0, 0, 0), in(bytecode.RetUnit, 0, 0, 0))
	main.Code[3].A = int32(builtinID("showInt"))
	main.Code[4].A = int32(builtinID("print"))
	if got := run(consts, main); got != "42\n" {
		t.Fatalf("got %q", got)
	}
}

func TestPanicAppendsToOutput(t *testing.T) {
	consts := []bytecode.Const{{Kind: bytecode.ConstInt, Int: 1}, {Kind: bytecode.ConstInt, Int: 0}}
	main := fn(0, 0, 3,
		in(bytecode.PushConst, 0, 0, 0), in(bytecode.PushConst, 1, 0, 0), in(bytecode.DivI, 0, 0, 0),
		in(bytecode.Pop, 0, 0, 0), in(bytecode.RetUnit, 0, 0, 0))
	if got := run(consts, main); got != "panic: divide by zero\n" {
		t.Fatalf("got %q", got)
	}
}

func TestCallDepthLimit(t *testing.T) {
	// main calls itself forever.
	main := fn(0, 0, 2, in(bytecode.Call, 0, 0, 0), in(bytecode.Pop, 0, 0, 0), in(bytecode.RetUnit, 0, 0, 0))
	if got := run(nil, main); got != "panic: call stack overflow\n" {
		t.Fatalf("got %q", got)
	}
}

func TestEqualityAndMaps(t *testing.T) {
	a := MapV(NewMap())
	b := MapV(NewMap())
	a.P.M.Set(Int(1), GoStr("x"))
	a.P.M.Set(Int(2), GoStr("y"))
	b.P.M.Set(Int(2), GoStr("y"))
	b.P.M.Set(Int(1), GoStr("x"))
	if !Equal(a, b) {
		t.Errorf("map equality must ignore insertion order")
	}
	nan := Float(nanValue())
	if Equal(nan, nan) {
		t.Errorf("NaN must not equal itself")
	}
	if !Equal(Float(0), Float(negZero)) {
		t.Errorf("0.0 must equal -0.0")
	}
	l1 := List([]Value{Int(1), Tuple([]Value{Int(2), GoStr("a")})})
	l2 := List([]Value{Int(1), Tuple([]Value{Int(2), GoStr("a")})})
	if !Equal(l1, l2) {
		t.Errorf("structural list equality")
	}
}

func TestMapInsertionOrderAndDeletion(t *testing.T) {
	m := NewMap()
	for i := int64(0); i < 100; i++ {
		m.Set(Int(i), Int(i*i))
	}
	for i := int64(0); i < 100; i += 2 {
		if !m.Del(Int(i)) {
			t.Fatalf("delete %d", i)
		}
	}
	if m.Del(Int(0)) {
		t.Errorf("deleting an absent key must report false")
	}
	m.Set(Int(0), Int(-1)) // re-inserted keys go to the end
	m.Set(Int(1), Int(-2)) // existing keys keep their position
	var keys []int64
	m.Each(func(k, v Value) { keys = append(keys, k.I()) })
	if len(keys) != 51 || keys[0] != 1 || keys[49] != 99 || keys[50] != 0 {
		t.Fatalf("unexpected order: %v", keys)
	}
	if v, _ := m.Get(Int(1)); v.I() != -2 {
		t.Errorf("update lost")
	}
	s := NewMap()
	s.Set(GoStr("ab"), Int(1))
	if v, ok := s.Get(GoStr("ab")); !ok || v.I() != 1 {
		t.Errorf("string keys hash by content")
	}
}

func builtinID(name string) int { return builtinIDs[name] }
