package softfloat

// guardBits is the number of extra low-order bits the larger operand is
// shifted left by in Add, giving the aligned smaller operand room for bits
// below its own LSB. 24 + 32 + carry still fits comfortably in 64 bits.
const guardBits = 32

// Add returns a + b.
func Add(a, b uint32) uint32 {
	if IsNaN(a) || IsNaN(b) {
		return QNaN
	}
	if IsInf(a) {
		if IsInf(b) && a != b {
			return QNaN
		}
		return a
	}
	if IsInf(b) {
		return b
	}
	if IsZero(a) {
		if IsZero(b) {
			return a & b // -0 only if both are -0
		}
		return b
	}
	if IsZero(b) {
		return a
	}

	// Order by magnitude so that the subtraction below never goes negative.
	if a&^signMask < b&^signMask {
		a, b = b, a
	}
	ma, ea := unpack(a)
	mb, eb := unpack(b)
	sign := a & signMask

	big := ma << guardBits
	small := mb << guardBits
	var sticky bool
	if d := uint(ea - eb); d >= 64 {
		small, sticky = 0, true
	} else if d > 0 {
		sticky = small&(1<<d-1) != 0
		small >>= d
	}

	var sum uint64
	if a^b < signMask { // same sign: effective addition
		sum = big + small
	} else {
		sum = big - small
		if sticky {
			// The true subtrahend is small + (0,1); borrow one unit so that
			// the residue stays a positive fraction.
			sum--
		}
		if sum == 0 && !sticky {
			return 0 // exact cancellation gives +0
		}
	}
	return roundPack(sign, sum, ea-guardBits, sticky)
}

// Sub returns a - b.
func Sub(a, b uint32) uint32 { return Add(a, Neg(b)) }
