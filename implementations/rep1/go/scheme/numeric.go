package scheme

import (
	"math"

	"example.com/scheme/bigint"
)

func isInteger(v Value) bool {
	switch v.(type) {
	case Int, *Big:
		return true
	}
	return false
}

func toBig(v Value) *bigint.Int {
	switch v := v.(type) {
	case Int:
		return bigint.New(int64(v))
	case *Big:
		return v.N
	}
	panic("scheme: not an integer")
}

func numAdd(a, b Value) Value {
	if x, ok := a.(Int); ok {
		if y, ok := b.(Int); ok {
			s := x + y
			if (x^s)&(y^s) >= 0 { // no signed overflow
				return s
			}
		}
	}
	return NewBig(toBig(a).Add(toBig(b)))
}

func numSub(a, b Value) Value {
	if x, ok := a.(Int); ok {
		if y, ok := b.(Int); ok {
			d := x - y
			if (x^y)&(x^d) >= 0 {
				return d
			}
		}
	}
	return NewBig(toBig(a).Sub(toBig(b)))
}

func numMul(a, b Value) Value {
	if x, ok := a.(Int); ok {
		if y, ok := b.(Int); ok {
			if x == 0 || y == 0 {
				return Int(0)
			}
			p := x * y
			if p/y == x && !(x == -1 && y == math.MinInt64) && !(y == -1 && x == math.MinInt64) {
				return p
			}
		}
	}
	return NewBig(toBig(a).Mul(toBig(b)))
}

func numCmp(a, b Value) int {
	if x, ok := a.(Int); ok {
		if y, ok := b.(Int); ok {
			switch {
			case x < y:
				return -1
			case x > y:
				return 1
			}
			return 0
		}
	}
	return toBig(a).Cmp(toBig(b))
}

func numSign(a Value) int {
	switch a := a.(type) {
	case Int:
		switch {
		case a < 0:
			return -1
		case a > 0:
			return 1
		}
		return 0
	case *Big:
		return a.N.Sign()
	}
	return 0
}

// numQuoRem divides truncating toward zero; b must be non-zero.
func numQuoRem(a, b Value) (Value, Value) {
	if x, ok := a.(Int); ok {
		if y, ok := b.(Int); ok && !(x == math.MinInt64 && y == -1) {
			return x / y, x % y
		}
	}
	q, r := toBig(a).QuoRem(toBig(b))
	return NewBig(q), NewBig(r)
}
