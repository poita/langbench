package scheme

import "math"

// Integer arithmetic on Values. Fixnum operands take a machine-integer path
// with overflow detection; only on overflow or a bignum operand does the
// computation go through package bigint, and results that fit are demoted
// back to fixnums so every integer has one representation.

func addInt(a, b Value) Value {
	if a.t == tFix && b.t == tFix {
		s := a.n + b.n
		if (a.n^s)&(b.n^s) >= 0 {
			return fix(s)
		}
	}
	return fromBig(toBig(a).Add(toBig(b)))
}

func subInt(a, b Value) Value {
	if a.t == tFix && b.t == tFix {
		d := a.n - b.n
		if (a.n^b.n)&(a.n^d) >= 0 {
			return fix(d)
		}
	}
	return fromBig(toBig(a).Sub(toBig(b)))
}

func mulInt(a, b Value) Value {
	if a.t == tFix && b.t == tFix {
		x, y := a.n, b.n
		if x == 0 || y == 0 {
			return fix(0)
		}
		p := x * y
		if p/y == x && !(x == -1 && y == math.MinInt64) && !(y == -1 && x == math.MinInt64) {
			return fix(p)
		}
	}
	return fromBig(toBig(a).Mul(toBig(b)))
}

func negInt(a Value) Value {
	if a.t == tFix && a.n != math.MinInt64 {
		return fix(-a.n)
	}
	return fromBig(toBig(a).Neg())
}

// quoRemInt returns the truncated quotient and remainder; b must be nonzero.
func quoRemInt(a, b Value) (q, r Value) {
	if a.t == tFix && b.t == tFix && !(a.n == math.MinInt64 && b.n == -1) {
		return fix(a.n / b.n), fix(a.n % b.n)
	}
	qb, rb, _ := toBig(a).QuoRem(toBig(b))
	return fromBig(qb), fromBig(rb)
}

func cmpInt(a, b Value) int {
	if a.t == tFix && b.t == tFix {
		switch {
		case a.n < b.n:
			return -1
		case a.n > b.n:
			return 1
		}
		return 0
	}
	return toBig(a).Cmp(toBig(b))
}

func isZeroInt(a Value) bool { return a.t == tFix && a.n == 0 }
