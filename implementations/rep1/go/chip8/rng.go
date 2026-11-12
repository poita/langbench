package chip8

// Seed is the initial state of the machine's random number generator.
const Seed uint32 = 0x12345678

// rng is the 32-bit linear congruential generator used by CXNN.
type rng struct{ state uint32 }

// next advances the generator once and returns the next random byte.
func (r *rng) next() byte {
	r.state = r.state*1103515245 + 12345
	return byte(r.state >> 16)
}
