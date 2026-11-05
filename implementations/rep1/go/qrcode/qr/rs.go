package qr

// rsGenerator returns the coefficients of the degree-e generator polynomial
// prod_{i<e}(x - 2^i), highest degree first, without the leading 1
// (so the result has length e).
func rsGenerator(e int) []byte {
	gen := make([]byte, e)
	gen[e-1] = 1 // start with the polynomial "1"
	root := byte(1)
	for i := 0; i < e; i++ {
		// Multiply the current polynomial by (x + root).
		for j := 0; j < e; j++ {
			gen[j] = gfMul(gen[j], root)
			if j+1 < e {
				gen[j] ^= gen[j+1]
			}
		}
		root = gfMul(root, 2)
	}
	return gen
}

// rsRemainder writes into rem (len(gen) bytes) the remainder of
// data(x)*x^len(gen) divided by the generator polynomial gen.
func rsRemainder(data, gen, rem []byte) {
	e := len(gen)
	for i := range rem[:e] {
		rem[i] = 0
	}
	for _, d := range data {
		factor := d ^ rem[0]
		copy(rem[:e-1], rem[1:e])
		rem[e-1] = 0
		if factor == 0 {
			continue
		}
		lf := int(gfLog[factor])
		for j, g := range gen {
			if g != 0 {
				rem[j] ^= gfExp[int(gfLog[g])+lf]
			}
		}
	}
}
