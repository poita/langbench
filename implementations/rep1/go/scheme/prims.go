package scheme

import (
	"strconv"
	"unicode/utf8"
)

// primDef describes a primitive. max < 0 means variadic. Arity has already
// been checked when fn is called; fn type-checks every argument before
// computing anything. The args slice is a view of the shared argument stack
// and must not be retained.
type primDef struct {
	name     string
	min, max int
	fn       func(in *Interp, args []Value) Value
}

// primApplyIdx is the index of `apply`, which the evaluator handles itself so
// that the call it makes is a proper tail call.
const primApplyIdx = 22

var primTable []primDef

func init() {
	primTable = []primDef{
		{"+", 0, -1, primAdd},
		{"*", 0, -1, primMul},
		{"-", 1, -1, primSub},
		{"quotient", 2, 2, primQuotient},
		{"remainder", 2, 2, primRemainder},
		{"=", 2, -1, compareChain(func(c int) bool { return c == 0 })},
		{"<", 2, -1, compareChain(func(c int) bool { return c < 0 })},
		{">", 2, -1, compareChain(func(c int) bool { return c > 0 })},
		{"<=", 2, -1, compareChain(func(c int) bool { return c <= 0 })},
		{">=", 2, -1, compareChain(func(c int) bool { return c >= 0 })},
		{"cons", 2, 2, func(_ *Interp, a []Value) Value { return cons(a[0], a[1]) }},
		{"car", 1, 1, primCar},
		{"cdr", 1, 1, primCdr},
		{"list", 0, -1, primList},
		{"null?", 1, 1, func(_ *Interp, a []Value) Value { return boolV(a[0].t == tNil) }},
		{"pair?", 1, 1, func(_ *Interp, a []Value) Value { return boolV(a[0].t == tPair) }},
		{"not", 1, 1, func(_ *Interp, a []Value) Value { return boolV(a[0].isFalse()) }},
		{"number?", 1, 1, func(_ *Interp, a []Value) Value { return boolV(a[0].isInt()) }},
		{"boolean?", 1, 1, func(_ *Interp, a []Value) Value { return boolV(a[0].t == tBool) }},
		{"string?", 1, 1, func(_ *Interp, a []Value) Value { return boolV(a[0].t == tStr) }},
		{"symbol?", 1, 1, func(_ *Interp, a []Value) Value { return boolV(a[0].t == tSym) }},
		{"procedure?", 1, 1, func(_ *Interp, a []Value) Value { return boolV(a[0].isProc()) }},
		{"apply", 2, -1, nil}, // primApplyIdx; handled by the evaluator
		{"eq?", 2, 2, func(_ *Interp, a []Value) Value { return boolV(eq(a[0], a[1])) }},
		{"equal?", 2, 2, func(_ *Interp, a []Value) Value { return boolV(equal(a[0], a[1])) }},
		{"error", 0, -1, func(*Interp, []Value) Value { throw(ErrUser); return Value{} }},
		{"string-append", 0, -1, primStringAppend},
		{"string-length", 1, 1, primStringLength},
		{"number->string", 1, 1, primNumberToString},
		{"symbol->string", 1, 1, primSymbolToString},
		{"display", 1, 1, func(in *Interp, a []Value) Value {
			in.out = appendValue(in.out, a[0], true)
			return voidV
		}},
		{"newline", 0, 0, func(in *Interp, _ []Value) Value {
			in.out = append(in.out, '\n')
			return voidV
		}},
	}
	if primTable[primApplyIdx].name != "apply" {
		panic("primApplyIdx out of sync with primTable")
	}
}

func checkInts(args []Value) {
	for _, a := range args {
		if !a.isInt() {
			throw(ErrType)
		}
	}
}

func primAdd(_ *Interp, args []Value) Value {
	checkInts(args)
	acc := fix(0)
	for _, a := range args {
		acc = addInt(acc, a)
	}
	return acc
}

func primMul(_ *Interp, args []Value) Value {
	checkInts(args)
	acc := fix(1)
	for _, a := range args {
		acc = mulInt(acc, a)
	}
	return acc
}

func primSub(_ *Interp, args []Value) Value {
	checkInts(args)
	if len(args) == 1 {
		return negInt(args[0])
	}
	acc := args[0]
	for _, a := range args[1:] {
		acc = subInt(acc, a)
	}
	return acc
}

func primQuotient(_ *Interp, args []Value) Value {
	checkInts(args)
	if isZeroInt(args[1]) {
		throw(ErrDivisionByZero)
	}
	q, _ := quoRemInt(args[0], args[1])
	return q
}

func primRemainder(_ *Interp, args []Value) Value {
	checkInts(args)
	if isZeroInt(args[1]) {
		throw(ErrDivisionByZero)
	}
	_, r := quoRemInt(args[0], args[1])
	return r
}

func compareChain(ok func(int) bool) func(*Interp, []Value) Value {
	return func(_ *Interp, args []Value) Value {
		checkInts(args)
		for i := 0; i+1 < len(args); i++ {
			if !ok(cmpInt(args[i], args[i+1])) {
				return falsV
			}
		}
		return trueV
	}
}

func primCar(_ *Interp, a []Value) Value {
	if a[0].t != tPair {
		throw(ErrType)
	}
	return a[0].pair().car
}

func primCdr(_ *Interp, a []Value) Value {
	if a[0].t != tPair {
		throw(ErrType)
	}
	return a[0].pair().cdr
}

func primList(_ *Interp, args []Value) Value {
	l := nilV
	for i := len(args) - 1; i >= 0; i-- {
		l = cons(args[i], l)
	}
	return l
}

func primStringAppend(_ *Interp, args []Value) Value {
	total := 0
	for _, a := range args {
		if a.t != tStr {
			throw(ErrType)
		}
		total += len(a.str())
	}
	buf := make([]byte, 0, total)
	for _, a := range args {
		buf = append(buf, a.str()...)
	}
	return Str(string(buf))
}

func primStringLength(_ *Interp, a []Value) Value {
	if a[0].t != tStr {
		throw(ErrType)
	}
	return fix(int64(utf8.RuneCountInString(a[0].str())))
}

func primNumberToString(_ *Interp, a []Value) Value {
	switch a[0].t {
	case tFix:
		return Str(strconv.FormatInt(a[0].n, 10))
	case tBig:
		return Str(toBig(a[0]).String())
	}
	throw(ErrType)
	return Value{}
}

func primSymbolToString(_ *Interp, a []Value) Value {
	if a[0].t != tSym {
		throw(ErrType)
	}
	return Str(a[0].symName())
}

// eq implements eq?: integers by numeric value, everything else by identity.
func eq(a, b Value) bool {
	if a.isInt() || b.isInt() {
		return a.isInt() && b.isInt() && cmpInt(a, b) == 0
	}
	if a.t != b.t {
		return false
	}
	switch a.t {
	case tNil, tVoid:
		return true
	case tBool, tSym, tPrim:
		return a.n == b.n
	case tPair:
		return a.pair() == b.pair()
	case tClosure:
		return a.ref.(*Closure) == b.ref.(*Closure)
	case tStr:
		return a.str() == b.str() // unspecified by the language; never tested
	}
	return false
}

// equal implements equal?; it iterates along cdrs and recurses on cars.
func equal(a, b Value) bool {
	for a.t == tPair && b.t == tPair {
		pa, pb := a.pair(), b.pair()
		if pa == pb {
			return true
		}
		if !equal(pa.car, pb.car) {
			return false
		}
		a, b = pa.cdr, pb.cdr
	}
	if a.t == tStr && b.t == tStr {
		return a.str() == b.str()
	}
	return eq(a, b)
}
