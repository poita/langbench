package softfloat

// Sqrt returns the square root of a.
func Sqrt(a uint32) uint32 {
	switch {
	case IsNaN(a):
		return QNaN
	case IsZero(a):
		return a // sqrt(+-0) = +-0
	case a&signMask != 0:
		return QNaN // negative, including -inf
	case IsInf(a):
		return a
	}

	m, e := unpack(a).normalize()
	// value = m * 2^(e-23). Scale the integer m so that the remaining
	// exponent t is even and M = m<<n is below 2^63.
	t := e - 23 - 38
	n := uint(38)
	if t&1 != 0 {
		t--
		n++
	}
	root, rem := isqrt(uint64(m) << n)
	// sqrt(value) = (root + frac) * 2^(t/2) = sig * 2^(t/2-1).
	sig := root << 1
	if rem != 0 {
		sig |= 1 // sticky
	}
	return roundPack(false, t/2-1, sig)
}

// isqrt returns floor(sqrt(x)) and x - floor(sqrt(x))^2 using the restoring
// digit-by-digit method: one result bit per step, at most 32 steps.
func isqrt(x uint64) (root, rem uint64) {
	bit := uint64(1) << 62
	for bit > x {
		bit >>= 2
	}
	for ; bit != 0; bit >>= 2 {
		if x >= root+bit {
			x -= root + bit
			root = root>>1 + bit
		} else {
			root >>= 1
		}
	}
	return root, x
}
