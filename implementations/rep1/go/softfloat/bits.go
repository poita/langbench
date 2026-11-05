package softfloat

import "math/bits"

// Layout of a binary32 bit pattern.
const (
	signMask = 0x80000000
	expMask  = 0x7f800000
	fracMask = 0x007fffff
	hidden   = 0x00800000 // implicit leading significand bit of normal numbers

	// QNaN is the canonical quiet NaN returned for every NaN result.
	QNaN uint32 = 0x7fc00000
	// PosInf is +infinity.
	PosInf uint32 = 0x7f800000
	// NegInf is -infinity.
	NegInf uint32 = 0xff800000
)

// minExp is the exponent of the least significant bit of a denormal, i.e. the
// spacing of the denormal grid is 2^minExp.
const minExp = -149

// IsNaN reports whether x encodes a NaN (quiet or signaling, either sign).
func IsNaN(x uint32) bool { return x&^signMask > expMask }

// IsInf reports whether x encodes +infinity or -infinity.
func IsInf(x uint32) bool { return x&^signMask == expMask }

// IsZero reports whether x encodes +0 or -0.
func IsZero(x uint32) bool { return x&^signMask == 0 }

// Neg returns x with its sign bit flipped (also for NaNs, zeros, infinities).
func Neg(x uint32) uint32 { return x ^ signMask }

// unpack decodes a finite, nonzero operand into an integer significand m and
// exponent e such that |x| = m * 2^e. Normal numbers have m in [2^23, 2^24);
// denormals have m < 2^23 and e = minExp.
func unpack(x uint32) (m uint64, e int) {
	be := int(x & expMask >> 23)
	f := uint64(x & fracMask)
	if be == 0 {
		return f, minExp
	}
	return f | hidden, be - 150
}

// unpackNorm is like unpack but shifts m left so that its top bit is bit 23,
// adjusting e to compensate. The operand must be finite and nonzero.
func unpackNorm(x uint32) (m uint64, e int) {
	m, e = unpack(x)
	n := 23 - (bits.Len64(m) - 1)
	return m << uint(n), e - n
}
