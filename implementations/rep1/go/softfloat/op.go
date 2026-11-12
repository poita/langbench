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

// String returns the lowercase mnemonic of op ("add", "sqrt", ...).
func (op Op) String() string {
	if op < 0 || int(op) >= len(opNames) {
		return fmt.Sprintf("Op(%d)", int(op))
	}
	return opNames[op]
}

// ParseOp converts a mnemonic such as "add" into an Op.
func ParseOp(s string) (Op, bool) {
	for i, n := range opNames {
		if n == s {
			return Op(i), true
		}
	}
	return 0, false
}

// Unary reports whether op takes a single operand.
func (op Op) Unary() bool { return op == OpSqrt }

// Apply evaluates op on the operands; b is ignored for unary operations.
// An unknown op returns QNaN.
func Apply(op Op, a, b uint32) uint32 {
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
