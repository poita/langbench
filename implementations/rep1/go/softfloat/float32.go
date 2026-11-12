package softfloat

import "math/bits"

// Bit-field layout of a binary32 value.
const (
	signMask = 0x80000000
	expMask  = 0x7f800000
	fracMask = 0x007fffff
	implicit = 0x00800000 // implicit leading significand bit of normal numbers

	// QNaN is the canonical quiet NaN returned for every NaN result.
	QNaN uint32 = 0x7fc00000
	// Inf is positive infinity.
	Inf uint32 = expMask
)

// IsNaN reports whether a is a NaN (quiet or signaling, either sign).
func IsNaN(a uint32) bool { return a&^signMask > expMask }

// IsInf reports whether a is an infinity of either sign.
func IsInf(a uint32) bool { return a&^signMask == expMask }

// IsZero reports whether a is a zero of either sign.
func IsZero(a uint32) bool { return a&^signMask == 0 }

// Neg returns a with its sign bit flipped (also for NaNs).
func Neg(a uint32) uint32 { return a ^ signMask }

// unpacked is a finite binary32 value as sign, biased exponent and raw
// significand: value = (-1)^neg * sig * 2^(exp-150). Denormals have exp 1
// and no implicit bit, so exp is always in [1, 254].
type unpacked struct {
	neg bool
	exp int
	sig uint32
}

func unpack(a uint32) unpacked {
	u := unpacked{neg: a&signMask != 0, exp: int(a&expMask) >> 23, sig: a & fracMask}
	if u.exp == 0 {
		u.exp = 1
	} else {
		u.sig |= implicit
	}
	return u
}

// normalize returns the significand shifted so that bit 23 is set (the value
// must be nonzero) and the matching unbiased exponent, so that
// |value| = m * 2^(e-23) with m in [2^23, 2^24).
func (u unpacked) normalize() (m uint32, e int) {
	s := bits.LeadingZeros32(u.sig) - 8
	return u.sig << uint(s), u.exp - 127 - s
}

func signBit(neg bool) uint32 {
	if neg {
		return signMask
	}
	return 0
}
