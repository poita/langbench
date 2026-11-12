package softfloat

// guardBits is the number of extra low bits kept when aligning addends.
const guardBits = 30

// Add returns a + b.
func Add(a, b uint32) uint32 {
	switch {
	case IsNaN(a) || IsNaN(b):
		return QNaN
	case IsInf(a) && IsInf(b):
		if a != b {
			return QNaN
		}
		return a
	case IsInf(a):
		return a
	case IsInf(b):
		return b
	case IsZero(a) && IsZero(b):
		return a & b & signMask // -0 only if both are -0
	case IsZero(a):
		return b
	case IsZero(b):
		return a
	}

	x, y := unpack(a), unpack(b)
	// Make x the operand of larger magnitude.
	if x.exp < y.exp || (x.exp == y.exp && x.sig < y.sig) {
		x, y = y, x
	}

	big := uint64(x.sig) << guardBits
	small := shiftRightJam(uint64(y.sig)<<guardBits, x.exp-y.exp)

	var sum uint64
	if x.neg == y.neg {
		sum = big + small
	} else {
		sum = big - small
		if sum == 0 {
			return 0 // exact cancellation gives +0
		}
	}
	return roundPack(x.neg, x.exp-150-guardBits, sum)
}

// Sub returns a - b. It rounds identically to Add(a, Neg(b)).
func Sub(a, b uint32) uint32 { return Add(a, Neg(b)) }
