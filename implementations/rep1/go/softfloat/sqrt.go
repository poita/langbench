package softfloat

import "math/bits"

// sqrtShift is the (even) number of bits the radicand is scaled left by so
// that the integer root has at least 30 significant bits.
const sqrtShift = 36

// Sqrt returns the square root of a. The square root of a negative number
// (including -infinity) is NaN; sqrt(-0) = -0.
func Sqrt(a uint32) uint32 {
	switch {
	case IsNaN(a):
		return QNaN
	case IsZero(a):
		return a
	case a&signMask != 0:
		return QNaN
	case IsInf(a):
		return a
	}
	m, e := unpackNorm(a)
	if e&1 != 0 { // make the exponent even
		m <<= 1
		e--
	}
	n := m << sqrtShift // < 2^61
	e -= sqrtShift
	root, rem := isqrt(n)
	return roundPack(0, root, e/2, rem != 0)
}

// isqrt returns floor(sqrt(n)) and n - floor(sqrt(n))^2 using the classic
// digit-by-digit (restoring) method.
func isqrt(n uint64) (root, rem uint64) {
	if n == 0 {
		return 0, 0
	}
	bit := uint64(1) << uint((bits.Len64(n)-1)&^1) // highest power of 4 <= n
	for ; bit != 0; bit >>= 2 {
		if n >= root+bit {
			n -= root + bit
			root = root>>1 + bit
		} else {
			root >>= 1
		}
	}
	return root, n
}
