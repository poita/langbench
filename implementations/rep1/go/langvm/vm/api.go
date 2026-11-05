package vm

import "unicode/utf8"

// Panic is the Go panic value used to unwind the host stack when a Vellum
// program panics (SPEC 14.6). Run recovers it.
type Panic struct{ Msg string }

// BuiltinFn implements one built-in function. a is a view of the argument
// values (it may alias the VM value stack: read it, do not retain it past the
// call, and do not write to it). The result is returned; built-ins with no
// result return Unit.
type BuiltinFn func(m *VM, a []Value) Value

var registry = map[string]BuiltinFn{}

// register installs the implementation of the built-in called name.
func register(name string, f BuiltinFn) {
	if _, dup := registry[name]; dup {
		panic("vm: duplicate built-in " + name)
	}
	registry[name] = f
}

// Panic aborts the running program with the given panic message. It does not
// return.
func (m *VM) Panic(msg string) { panic(&Panic{Msg: msg}) }

// WriteRunes appends the UTF-8 encoding of s to the program output.
func (m *VM) WriteRunes(s []rune) {
	for _, r := range s {
		if r < utf8.RuneSelf {
			m.out = append(m.out, byte(r))
		} else {
			m.out = utf8.AppendRune(m.out, r)
		}
	}
}

// WriteByte appends one ASCII byte to the program output.
func (m *VM) writeByte(b byte) { m.out = append(m.out, b) }

// Call1 calls the closure f with one argument and returns its result. It
// re-enters the interpreter loop, so a panic inside unwinds through the caller.
func (m *VM) Call1(f, a Value) Value {
	m.argbuf[0] = a
	return m.invoke(f, 1)
}

// Call2 calls the closure f with two arguments.
func (m *VM) Call2(f, a, b Value) Value {
	m.argbuf[0] = a
	m.argbuf[1] = b
	return m.invoke(f, 2)
}
