package softfloat

import "math/bits"

// roundPack rounds the value (m + ε) * 2^e to the binary32 grid, where
// ε is a tiny positive amount if sticky is set (and zero otherwise), and
// returns the packed result with the given sign (0 or signMask).
//
// m must be nonzero. If sticky is set, m must carry at least two bits below
// the final rounding position (callers guarantee at least ~6), so that the
// sticky residue can only influence rounding, never the retained bits.
//
// Rounding happens exactly once, directly onto the destination grid (normal
// or denormal), so there is no double rounding.
func roundPack(sign uint32, m uint64, e int, sticky bool) uint32 {
	lead := bits.Len64(m) - 1
	// g is the exponent of the destination unit in the last place.
	g := lead + e - 23
	if g < minExp {
		g = minExp
	}
	s := g - e // number of low bits of m to discard

	var sig uint64
	switch {
	case s <= 0:
		sig = m << uint(-s)
	case s > 64:
		// Everything, including the round bit, lies strictly below half an ulp.
		sig = 0
	default:
		var rem, half uint64
		if s == 64 {
			sig, rem, half = 0, m, 1<<63
		} else {
			sig = m >> uint(s)
			rem = m & (1<<uint(s) - 1)
			half = 1 << uint(s-1)
		}
		if rem > half || (rem == half && (sticky || sig&1 == 1)) {
			sig++
		}
	}

	// sig is in [2^23, 2^24] on normal grids and [0, 2^23] on the denormal
	// grid; both cases pack uniformly, and a carry out of the significand
	// ripples into the exponent field.
	r := uint32(g-minExp)<<23 + uint32(sig)
	if g-minExp >= 0xff || r >= expMask {
		return sign | PosInf
	}
	return sign | r
}
