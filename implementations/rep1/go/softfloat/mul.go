package softfloat

// Mul returns a * b.
func Mul(a, b uint32) uint32 {
	neg := (a^b)&signMask != 0
	switch {
	case IsNaN(a) || IsNaN(b):
		return QNaN
	case IsInf(a) || IsInf(b):
		if IsZero(a) || IsZero(b) {
			return QNaN
		}
		return signBit(neg) | Inf
	case IsZero(a) || IsZero(b):
		return signBit(neg)
	}

	ma, ea := unpack(a).normalize()
	mb, eb := unpack(b).normalize()
	// Exact 48-bit product: value = p * 2^(ea+eb-46).
	p := uint64(ma) * uint64(mb)
	return roundPack(neg, ea+eb-46, p)
}
