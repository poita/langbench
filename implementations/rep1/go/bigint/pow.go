package bigint

// pow returns x**e by binary exponentiation (square-and-multiply, scanning the
// exponent from its most significant bit).
func (x nat) pow(e uint64) nat {
	if e == 0 {
		return nat{1}
	}
	if len(x) == 0 {
		return nil
	}
	z := nat{1}
	for bit := uint64(1) << 63; bit != 0; bit >>= 1 {
		if bit > e && z.cmp(nat{1}) == 0 {
			continue // skip leading zero bits
		}
		z = z.sqr()
		if e&bit != 0 {
			z = z.mul(x)
		}
	}
	return z
}
