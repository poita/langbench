package scheme

import (
	"sync"

	"example.com/scheme/bigint"
)

// Value is any Scheme value. The dynamic type is one of Int, *Big, Bool,
// *String, *Symbol, *Pair, Null, Void, *Primitive or *Closure.
//
// Integers are always normalised: a value that fits in an int64 is an Int and
// never a *Big, so two equal integers have the same representation.
type Value interface{}

// Int is a fixnum (an integer that fits in 64 bits).
type Int int64

// Big is an integer outside the int64 range.
type Big struct{ N *bigint.Int }

// Bool is a boolean. Only False is false in conditionals.
type Bool bool

// String is an (immutable) Scheme string.
type String struct{ S string }

// Symbol is an interned identifier; symbols with the same name are the same
// *Symbol, so they can be compared with ==.
type Symbol struct{ Name string }

// Pair is a cons cell.
type Pair struct{ Car, Cdr Value }

// Null is the type of the empty list.
type Null struct{}

// Void is the type of the value returned by define, set!, display, etc.
type Void struct{}

// Frequently used constants.
var (
	True        Value = Bool(true)
	False       Value = Bool(false)
	Nil         Value = Null{}
	Unspecified Value = Void{}
)

var (
	symMu    sync.Mutex
	symTable = map[string]*Symbol{}
)

// Intern returns the unique symbol with the given name.
func Intern(name string) *Symbol {
	symMu.Lock()
	defer symMu.Unlock()
	s, ok := symTable[name]
	if !ok {
		s = &Symbol{Name: name}
		symTable[name] = s
	}
	return s
}

// NewString returns a new string value.
func NewString(s string) *String { return &String{S: s} }

// Cons returns a new pair.
func Cons(car, cdr Value) *Pair { return &Pair{Car: car, Cdr: cdr} }

// List returns a fresh proper list of its arguments.
func List(vs ...Value) Value {
	var l Value = Nil
	for i := len(vs) - 1; i >= 0; i-- {
		l = &Pair{vs[i], l}
	}
	return l
}

// ListToSlice converts a proper list to a slice; ok is false if v is not a
// proper list.
func ListToSlice(v Value) (items []Value, ok bool) {
	for {
		switch p := v.(type) {
		case Null:
			return items, true
		case *Pair:
			items = append(items, p.Car)
			v = p.Cdr
		default:
			return nil, false
		}
	}
}

// IsTrue reports whether v counts as true: everything except #f.
func IsTrue(v Value) bool {
	b, ok := v.(Bool)
	return !ok || bool(b)
}

// NewInteger returns the integer value for n, normalised.
func NewInteger(n int64) Value { return Int(n) }

// NewBig returns the integer value for n, normalised to an Int if it fits.
func NewBig(n *bigint.Int) Value {
	if v, ok := n.Int64(); ok {
		return Int(v)
	}
	return &Big{N: n}
}

// IsProcedure reports whether v is a primitive or a closure.
func IsProcedure(v Value) bool {
	switch v.(type) {
	case *Primitive, *Closure:
		return true
	}
	return false
}

// Primitive is a built-in procedure.
type Primitive struct {
	Name string
	// Min and Max bound the accepted argument count; Max < 0 means no limit.
	Min, Max int
	// Fn implements the procedure. It signals runtime errors with Raise.
	// The args slice must not be retained.
	Fn func(in *Interp, args []Value) Value

	isApply bool
}

// Closure is a user-defined procedure.
type Closure struct {
	lam *lambdaNode
	env *Env
}
