package softfloat

// Mul returns a * b.
func Mul(a, b uint32) uint32 {
	if IsNaN(a) || IsNaN(b) {
		return QNaN
	}
	sign := (a ^ b) & signMask
	if IsInf(a) || IsInf(b) {
		if IsZero(a) || IsZero(b) {
			return QNaN
		}
		return sign | PosInf
	}
	if IsZero(a) || IsZero(b) {
		return sign
	}
	ma, ea := unpack(a)
	mb, eb := unpack(b)
	return roundPack(sign, ma*mb, ea+eb, false) // 24x24 -> 48 bits, exact
}
