package scheme

import "example.com/scheme/bigint"

// Kind classifies a Value.
type Kind uint8

// The kinds of value.
const (
	KindVoid Kind = iota
	KindNil
	KindBool
	KindInteger
	KindSymbol
	KindString
	KindPair
	KindProcedure
)

// tag is the internal, finer-grained discriminator of a Value.
type tag uint8

const (
	tUnbound tag = iota // sentinel for unbound globals; never a user value
	tVoid
	tNil
	tBool
	tFix  // int64 fixnum, in n
	tBig  // bignum outside the int64 range, ref is *bigint.Int
	tSym  // symbol id in n, name in ref (string)
	tStr  // ref is string
	tPair // ref is *Pair
	tPrim // primitive index in n
	tClosure
)

// Value is a Scheme value. It is a small struct passed by value; fixnums,
// booleans, (), void, symbols and primitives never allocate.
type Value struct {
	t   tag
	n   int64
	ref any
}

// Pair is a heap-allocated cons cell.
type Pair struct {
	car, cdr Value
}

var (
	nilV  = Value{t: tNil}
	voidV = Value{t: tVoid}
	trueV = Value{t: tBool, n: 1}
	falsV = Value{t: tBool, n: 0}
)

func fix(n int64) Value { return Value{t: tFix, n: n} }

func boolV(b bool) Value {
	if b {
		return trueV
	}
	return falsV
}

func cons(a, d Value) Value { return Value{t: tPair, ref: &Pair{a, d}} }

func fromBig(b *bigint.Int) Value {
	if n, ok := b.Int64(); ok {
		return fix(n)
	}
	return Value{t: tBig, ref: b}
}

func toBig(v Value) *bigint.Int {
	if v.t == tFix {
		return bigint.FromInt64(v.n)
	}
	return v.ref.(*bigint.Int)
}

func (v Value) isFalse() bool   { return v.t == tBool && v.n == 0 }
func (v Value) isInt() bool     { return v.t == tFix || v.t == tBig }
func (v Value) pair() *Pair     { return v.ref.(*Pair) }
func (v Value) isProc() bool    { return v.t == tPrim || v.t == tClosure }
func (v Value) str() string     { return v.ref.(string) }
func (v Value) symName() string { return v.ref.(string) }

// ---- Public constructors and accessors ----

// Int returns the integer value n.
func Int(n int64) Value { return fix(n) }

// Str returns a string value.
func Str(s string) Value { return Value{t: tStr, ref: s} }

// Bool returns #t or #f.
func Bool(b bool) Value { return boolV(b) }

// Nil returns the empty list.
func Nil() Value { return nilV }

// Cons returns a new pair.
func Cons(car, cdr Value) Value { return cons(car, cdr) }

// Kind returns the kind of v.
func (v Value) Kind() Kind {
	switch v.t {
	case tNil:
		return KindNil
	case tBool:
		return KindBool
	case tFix, tBig:
		return KindInteger
	case tSym:
		return KindSymbol
	case tStr:
		return KindString
	case tPair:
		return KindPair
	case tPrim, tClosure:
		return KindProcedure
	}
	return KindVoid
}

// Int64 returns v as an int64 if it is an integer that fits.
func (v Value) Int64() (int64, bool) {
	if v.t == tFix {
		return v.n, true
	}
	return 0, false
}

// Truthy reports whether v counts as true (everything except #f).
func (v Value) Truthy() bool { return !v.isFalse() }

// Car returns the first field of a pair.
func (v Value) Car() (Value, bool) {
	if v.t != tPair {
		return Value{}, false
	}
	return v.pair().car, true
}

// Cdr returns the second field of a pair.
func (v Value) Cdr() (Value, bool) {
	if v.t != tPair {
		return Value{}, false
	}
	return v.pair().cdr, true
}

// StringValue returns the contents of a string value, or the name of a
// symbol.
func (v Value) StringValue() (string, bool) {
	if v.t == tStr || v.t == tSym {
		return v.ref.(string), true
	}
	return "", false
}
