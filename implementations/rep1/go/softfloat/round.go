package softfloat

import "math/bits"

// roundPack rounds sig * 2^e to the nearest binary32 value (ties to even,
// gradual underflow, overflow to infinity) and packs it with the given sign.
//
// sig must be nonzero and below 2^63. If bits were discarded while forming
// sig, the caller must have folded them into its least significant bit (a
// sticky bit), and that bit must lie well below the rounding position, which
// holds for all callers (they provide at least 30 significant bits).
//
// This is the only place where rounding happens.
func roundPack(neg bool, e int, sig uint64) uint32 {
	sign := signBit(neg)

	// Normalise so the leading bit is bit 62; then the leading bit has
	// unbiased exponent e+62.
	lz := bits.LeadingZeros64(sig) - 1
	sig <<= uint(lz)
	e -= lz
	be := e + 62 + 127 // biased exponent of the leading bit

	if be >= 0xff {
		return sign | Inf
	}

	// Keep 24 bits for normal results; denormals keep fewer, aligned to the
	// 2^-149 grid.
	shift := 39
	if be < 1 {
		shift += 1 - be
	}

	var q uint64
	if shift >= 64 {
		// Magnitude below half of the smallest denormal.
		return sign
	}
	q = sig >> uint(shift)
	rem := sig & (1<<uint(shift) - 1)
	half := uint64(1) << uint(shift-1)
	if rem > half || (rem == half && q&1 == 1) {
		q++
	}

	var r uint64
	if be < 1 {
		r = q // a carry to 2^23 yields 0x00800000, the smallest normal
	} else {
		// q includes the implicit bit, so adding it to (be-1)<<23 bumps
		// the exponent field to be; a carry out of q bumps it again.
		r = uint64(be-1)<<23 + q
	}
	if r >= expMask {
		return sign | Inf
	}
	return sign | uint32(r)
}

// shiftRightJam shifts x right by n bits, setting the least significant bit
// of the result if any nonzero bit was shifted out.
func shiftRightJam(x uint64, n int) uint64 {
	switch {
	case n <= 0:
		return x
	case n >= 64:
		if x != 0 {
			return 1
		}
		return 0
	}
	r := x >> uint(n)
	if x&(1<<uint(n)-1) != 0 {
		r |= 1
	}
	return r
}
