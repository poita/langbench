package softfloat

// Div returns a / b.
func Div(a, b uint32) uint32 {
	neg := (a^b)&signMask != 0
	switch {
	case IsNaN(a) || IsNaN(b):
		return QNaN
	case IsInf(a):
		if IsInf(b) {
			return QNaN
		}
		return signBit(neg) | Inf
	case IsInf(b):
		return signBit(neg)
	case IsZero(b):
		if IsZero(a) {
			return QNaN
		}
		return signBit(neg) | Inf
	case IsZero(a):
		return signBit(neg)
	}

	ma, ea := unpack(a).normalize()
	mb, eb := unpack(b).normalize()
	// Both significands are in [2^23, 2^24), so the quotient below lies in
	// (2^37, 2^39) and the dividend (< 2^62) fits in 64 bits.
	num := uint64(ma) << 38
	den := uint64(mb)
	q := num / den
	sig := q << 1
	if num%den != 0 {
		sig |= 1 // sticky
	}
	// value = (q + frac) * 2^(ea-eb-38) = sig * 2^(ea-eb-39).
	return roundPack(neg, ea-eb-39, sig)
}
