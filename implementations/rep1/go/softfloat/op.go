package softfloat

import "fmt"

// Op identifies an arithmetic operation.
type Op int

// The supported operations.
const (
	OpAdd Op = iota
	OpSub
	OpMul
	OpDiv
	OpSqrt
)

var opNames = [...]string{"add", "sub", "mul", "div", "sqrt"}

// String returns the lowercase mnemonic of the operation ("add", "sqrt", ...).
func (o Op) String() string {
	if o < 0 || int(o) >= len(opNames) {
		return fmt.Sprintf("Op(%d)", int(o))
	}
	return opNames[o]
}

// Unary reports whether the operation takes a single operand.
func (o Op) Unary() bool { return o == OpSqrt }

// ParseOp converts a mnemonic such as "mul" to an Op.
func ParseOp(s string) (Op, error) {
	for i, n := range opNames {
		if n == s {
			return Op(i), nil
		}
	}
	return 0, fmt.Errorf("softfloat: unknown operation %q", s)
}

// Eval applies op to the operands. The second operand is ignored for unary
// operations. An invalid Op yields QNaN.
func Eval(op Op, a, b uint32) uint32 {
	switch op {
	case OpAdd:
		return Add(a, b)
	case OpSub:
		return Sub(a, b)
	case OpMul:
		return Mul(a, b)
	case OpDiv:
		return Div(a, b)
	case OpSqrt:
		return Sqrt(a)
	}
	return QNaN
}
