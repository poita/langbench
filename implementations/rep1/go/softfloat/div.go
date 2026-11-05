package softfloat

// divShift is the number of bits the dividend is shifted left before the
// integer division, giving a quotient of 32 or 33 significant bits.
const divShift = 32

// Div returns a / b.
func Div(a, b uint32) uint32 {
	if IsNaN(a) || IsNaN(b) {
		return QNaN
	}
	sign := (a ^ b) & signMask
	switch {
	case IsInf(a):
		if IsInf(b) {
			return QNaN
		}
		return sign | PosInf
	case IsInf(b):
		return sign
	case IsZero(b):
		if IsZero(a) {
			return QNaN
		}
		return sign | PosInf
	case IsZero(a):
		return sign
	}
	// Normalising both significands to 24 bits guarantees the quotient has at
	// least 32 significant bits, even for denormal operands.
	ma, ea := unpackNorm(a)
	mb, eb := unpackNorm(b)
	num := ma << divShift
	q := num / mb
	r := num % mb
	return roundPack(sign, q, ea-eb-divShift, r != 0)
}
