package compile_test

import (
	"testing"

	"langvm/bytecode"
	"langvm/vellum"
)

func compileSrc(t *testing.T, src string) *bytecode.Program {
	t.Helper()
	p, err := vellum.Compile([]byte("@module main\n" + src))
	if err != nil {
		t.Fatalf("compile: %v", err)
	}
	return p
}

func ops(f *bytecode.Func) []bytecode.Op {
	out := make([]bytecode.Op, len(f.Code))
	for i, in := range f.Code {
		out[i] = in.Op
	}
	return out
}

func contains(f *bytecode.Func, op bytecode.Op) bool {
	for _, o := range ops(f) {
		if o == op {
			return true
		}
	}
	return false
}

func TestTypedArithmetic(t *testing.T) {
	p := compileSrc(t, "fn add(a: Int, b: Int) -> Int { a + b }\nfn addf(a: Float, b: Float) -> Float { a + b }\nfn main() {}")
	if !contains(p.Funcs[0], bytecode.AddI) || contains(p.Funcs[0], bytecode.AddF) {
		t.Errorf("Int addition must use ADD_I: %v", ops(p.Funcs[0]))
	}
	if !contains(p.Funcs[1], bytecode.AddF) {
		t.Errorf("Float addition must use ADD_F: %v", ops(p.Funcs[1]))
	}
}

func TestConstantPoolDedup(t *testing.T) {
	p := compileSrc(t, "fn main() { print(\"a\"); print(\"a\"); print(\"b\"); let x = 7 + 7; }")
	if len(p.Consts) != 3 {
		t.Fatalf("want 3 constants (\"a\", \"b\", 7), got %d: %+v", len(p.Consts), p.Consts)
	}
}

func TestFusedMatchAndLoopForms(t *testing.T) {
	p := compileSrc(t, `enum E { A, B(Int) }
fn f(e: E, xs: [Int]) -> Int {
    var t = 0;
    for x in xs { t = t + x; }
    match e { A -> t, B(n) -> t + n }
}
fn main() {}`)
	f := p.Funcs[0]
	for _, op := range []bytecode.Op{bytecode.JumpUnlessVariant, bytecode.PushPayload,
		bytecode.SeqLenSlot, bytecode.SeqGetSlot, bytecode.IncLocal} {
		if !contains(f, op) {
			t.Errorf("expected %s in %v", op, ops(f))
		}
	}
}

func TestFunctionMetadata(t *testing.T) {
	p := compileSrc(t, "fn f(a: Int, b: Int) -> Int { let c = a * b; c + 1 }\nfn main() {}")
	f := p.Funcs[0]
	if f.NParams != 2 || f.NSlots < 3 || f.MaxStack < 2 {
		t.Errorf("bad metadata: %+v", f)
	}
	if p.Funcs[p.Main].Name != "main" {
		t.Errorf("Main does not point at main")
	}
}

func TestLambdasGetTheirOwnFunction(t *testing.T) {
	p := compileSrc(t, "fn main() { let k = 3; let f = |x: Int| x + k; print(showInt(f(1))); }")
	n := 0
	for _, f := range p.Funcs {
		if f.Name == "<lambda>" {
			n++
			if !contains(f, bytecode.LoadUpval) {
				t.Errorf("captured variable must be read through LOAD_UPVAL")
			}
		}
	}
	if n != 1 {
		t.Fatalf("want 1 lambda, got %d", n)
	}
	if !contains(p.Funcs[p.Main], bytecode.MakeClosure) {
		t.Errorf("main must create the closure")
	}
}

func TestMethodTable(t *testing.T) {
	p := compileSrc(t, `trait T { fn a(self) -> Int; fn b(self) -> Int { 2 } }
impl T for Int { fn a(self) -> Int { 1 } }
fn main() {}`)
	row := p.Methods[0*p.NumCtors+0] // trait 0, head constructor Int
	if len(row) != 2 {
		t.Fatalf("want 2 entries, got %v", row)
	}
	if p.Funcs[row[0]].Name != "a" || p.Funcs[row[1]].Name != "b" {
		t.Errorf("method table must list the impl method and the default body: %v", row)
	}
}
