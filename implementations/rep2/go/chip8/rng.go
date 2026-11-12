package chip8

// DefaultSeed is the initial state of the machine's random number generator.
const DefaultSeed uint32 = 0x12345678

// RNG is the 32-bit linear congruential generator used by CXNN.
// The zero value is a valid generator with state 0; use NewRNG for the
// specified default seed.
type RNG struct {
	state uint32
}

// NewRNG returns a generator whose state is seed.
func NewRNG(seed uint32) RNG { return RNG{state: seed} }

// State returns the current generator state.
func (r *RNG) State() uint32 { return r.state }

// Byte advances the generator once and returns the next random byte.
func (r *RNG) Byte() byte {
	r.state = r.state*1103515245 + 12345
	return byte(r.state >> 16)
}
