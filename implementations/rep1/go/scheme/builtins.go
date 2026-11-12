package scheme

import (
	"unicode/utf8"
)

// DefinePrimitive binds name in the global environment to a primitive
// procedure accepting between min and max arguments (max < 0: any number).
func (in *Interp) DefinePrimitive(name string, min, max int, fn func(in *Interp, args []Value) Value) {
	in.Define(name, &Primitive{Name: name, Min: min, Max: max, Fn: fn})
}

func (in *Interp) installBuiltins() {
	def := in.DefinePrimitive

	// Integer arithmetic.
	def("+", 0, -1, func(_ *Interp, a []Value) Value {
		checkIntegers(a)
		var acc Value = Int(0)
		for _, x := range a {
			acc = numAdd(acc, x)
		}
		return acc
	})
	def("*", 0, -1, func(_ *Interp, a []Value) Value {
		checkIntegers(a)
		var acc Value = Int(1)
		for _, x := range a {
			acc = numMul(acc, x)
		}
		return acc
	})
	def("-", 1, -1, func(_ *Interp, a []Value) Value {
		checkIntegers(a)
		if len(a) == 1 {
			return numSub(Int(0), a[0])
		}
		acc := a[0]
		for _, x := range a[1:] {
			acc = numSub(acc, x)
		}
		return acc
	})
	def("quotient", 2, 2, func(_ *Interp, a []Value) Value {
		q, _ := divide(a)
		return q
	})
	def("remainder", 2, 2, func(_ *Interp, a []Value) Value {
		_, r := divide(a)
		return r
	})
	compare := func(name string, ok func(c int) bool) {
		def(name, 2, -1, func(_ *Interp, a []Value) Value {
			checkIntegers(a)
			for i := 0; i+1 < len(a); i++ {
				if !ok(numCmp(a[i], a[i+1])) {
					return False
				}
			}
			return True
		})
	}
	compare("=", func(c int) bool { return c == 0 })
	compare("<", func(c int) bool { return c < 0 })
	compare(">", func(c int) bool { return c > 0 })
	compare("<=", func(c int) bool { return c <= 0 })
	compare(">=", func(c int) bool { return c >= 0 })

	// Pairs and lists.
	def("cons", 2, 2, func(_ *Interp, a []Value) Value { return &Pair{a[0], a[1]} })
	def("car", 1, 1, func(_ *Interp, a []Value) Value { return pairArg(a[0]).Car })
	def("cdr", 1, 1, func(_ *Interp, a []Value) Value { return pairArg(a[0]).Cdr })
	def("list", 0, -1, func(_ *Interp, a []Value) Value { return List(a...) })
	def("null?", 1, 1, func(_ *Interp, a []Value) Value { _, ok := a[0].(Null); return Bool(ok) })
	def("pair?", 1, 1, func(_ *Interp, a []Value) Value { _, ok := a[0].(*Pair); return Bool(ok) })

	// Predicates and equivalence.
	def("not", 1, 1, func(_ *Interp, a []Value) Value { return Bool(!IsTrue(a[0])) })
	def("number?", 1, 1, func(_ *Interp, a []Value) Value { return Bool(isInteger(a[0])) })
	def("boolean?", 1, 1, func(_ *Interp, a []Value) Value { _, ok := a[0].(Bool); return Bool(ok) })
	def("string?", 1, 1, func(_ *Interp, a []Value) Value { _, ok := a[0].(*String); return Bool(ok) })
	def("symbol?", 1, 1, func(_ *Interp, a []Value) Value { _, ok := a[0].(*Symbol); return Bool(ok) })
	def("procedure?", 1, 1, func(_ *Interp, a []Value) Value { return Bool(IsProcedure(a[0])) })
	def("eq?", 2, 2, func(_ *Interp, a []Value) Value { return Bool(isEq(a[0], a[1])) })
	def("equal?", 2, 2, func(_ *Interp, a []Value) Value { return Bool(isEqual(a[0], a[1])) })

	// Control.
	in.global.global[Intern("apply")] = &Primitive{
		Name: "apply", Min: 2, Max: -1, isApply: true,
		Fn: func(in *Interp, a []Value) Value {
			f, args := spreadApply(a)
			return in.apply(f, args)
		},
	}
	def("error", 0, -1, func(_ *Interp, a []Value) Value {
		Raise(ErrUser)
		return nil
	})

	// Strings and symbols.
	def("string-append", 0, -1, func(_ *Interp, a []Value) Value {
		n := 0
		for _, x := range a {
			n += len(stringArg(x).S)
		}
		buf := make([]byte, 0, n)
		for _, x := range a {
			buf = append(buf, x.(*String).S...)
		}
		return NewString(string(buf))
	})
	def("string-length", 1, 1, func(_ *Interp, a []Value) Value {
		return Int(utf8.RuneCountInString(stringArg(a[0]).S))
	})
	def("number->string", 1, 1, func(_ *Interp, a []Value) Value {
		checkIntegers(a)
		return NewString(Write(a[0]))
	})
	def("symbol->string", 1, 1, func(_ *Interp, a []Value) Value {
		s, ok := a[0].(*Symbol)
		if !ok {
			Raise(ErrType)
		}
		return NewString(s.Name)
	})

	// Output.
	def("display", 1, 1, func(in *Interp, a []Value) Value {
		in.writeOut(appendValue(nil, a[0], true))
		return Unspecified
	})
	def("newline", 0, 0, func(in *Interp, a []Value) Value {
		in.writeOut([]byte{'\n'})
		return Unspecified
	})
}

func checkIntegers(a []Value) {
	for _, x := range a {
		if !isInteger(x) {
			Raise(ErrType)
		}
	}
}

func divide(a []Value) (Value, Value) {
	checkIntegers(a)
	if numSign(a[1]) == 0 {
		Raise(ErrDivisionByZero)
	}
	return numQuoRem(a[0], a[1])
}

func pairArg(v Value) *Pair {
	p, ok := v.(*Pair)
	if !ok {
		Raise(ErrType)
	}
	return p
}

func stringArg(v Value) *String {
	s, ok := v.(*String)
	if !ok {
		Raise(ErrType)
	}
	return s
}

// isEq implements eq?: integers by value, everything else by identity.
func isEq(a, b Value) bool {
	if x, ok := a.(*Big); ok {
		y, ok := b.(*Big)
		return ok && x.N.Cmp(y.N) == 0
	}
	return a == b
}

// isEqual implements equal?: structural on pairs and strings.
func isEqual(a, b Value) bool {
	for {
		switch x := a.(type) {
		case *Pair:
			y, ok := b.(*Pair)
			if !ok || !isEqual(x.Car, y.Car) {
				return false
			}
			a, b = x.Cdr, y.Cdr
			continue
		case *String:
			y, ok := b.(*String)
			return ok && x.S == y.S
		}
		return isEq(a, b)
	}
}
