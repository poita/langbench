package vm

import (
	"math"
	"testing"

	"langvm/builtins"
)

func call(name string, args ...Value) Value {
	f, ok := registry[name]
	if !ok {
		panic("no builtin " + name)
	}
	return f(New(), args)
}

func callVM(m *VM, name string, args ...Value) Value { return registry[name](m, args) }

// panicMsg runs the built-in and returns the panic message ("" if none).
func panicMsg(name string, args ...Value) (msg string, panicked bool) {
	defer func() {
		if r := recover(); r != nil {
			p, ok := r.(*Panic)
			if !ok {
				panic(r)
			}
			msg, panicked = p.Msg, true
		}
	}()
	call(name, args...)
	return "", false
}

func wantPanic(t *testing.T, want, name string, args ...Value) {
	t.Helper()
	msg, ok := panicMsg(name, args...)
	if !ok {
		t.Errorf("%s: expected panic %q, got none", name, want)
	} else if msg != want {
		t.Errorf("%s: panic %q, want %q", name, msg, want)
	}
}

func gs(v Value) string { return string(v.P.S) }

func wantStr(t *testing.T, got Value, want string) {
	t.Helper()
	if got.P.Kind != KStr || string(got.P.S) != want {
		t.Errorf("got %q, want %q", string(got.P.S), want)
	}
}

func wantInt(t *testing.T, got Value, want int64) {
	t.Helper()
	if got.N != want {
		t.Errorf("got %d, want %d", got.N, want)
	}
}

func wantBool(t *testing.T, got Value, want bool) {
	t.Helper()
	if got.B() != want {
		t.Errorf("got %v, want %v", got.B(), want)
	}
}

func strList(ss ...string) Value {
	vs := make([]Value, len(ss))
	for i, s := range ss {
		vs[i] = GoStr(s)
	}
	return List(vs)
}

func intList(ns ...int64) Value {
	vs := make([]Value, len(ns))
	for i, n := range ns {
		vs[i] = Int(n)
	}
	return List(vs)
}

func listInts(v Value) []int64 {
	var out []int64
	for _, x := range v.P.V {
		out = append(out, x.N)
	}
	return out
}

func listStrs(v Value) []string {
	out := []string{}
	for _, x := range v.P.V {
		out = append(out, string(x.P.S))
	}
	return out
}

func eqStrs(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func eqInts(a, b []int64) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func fbits(f float64) uint64 { return math.Float64bits(f) }

func TestRegistryMatchesSpecs(t *testing.T) {
	if len(builtins.Specs) != 132 {
		t.Errorf("Specs has %d entries, want 132", len(builtins.Specs))
	}
	names := map[string]bool{}
	for _, s := range builtins.Specs {
		names[s.Name] = true
		if registry[s.Name] == nil {
			t.Errorf("builtin %s has no implementation", s.Name)
		}
	}
	for n := range registry {
		if !names[n] {
			t.Errorf("registered %s is not in builtins.Specs", n)
		}
	}
	if len(registry) != len(builtins.Specs) {
		t.Errorf("registry has %d entries, Specs %d", len(registry), len(builtins.Specs))
	}
}

func TestOutput(t *testing.T) {
	m := New()
	callVM(m, "emit", GoStr("a"))
	callVM(m, "print", GoStr("héllo"))
	callVM(m, "print", GoStr(""))
	if string(m.out) != "ahéllo\n\n" {
		t.Errorf("output %q", m.out)
	}
	func() {
		defer func() {
			p := recover().(*Panic)
			if p.Msg != "boom" {
				t.Errorf("panic msg %q", p.Msg)
			}
		}()
		callVM(m, "panic", GoStr("boom"))
	}()
}
