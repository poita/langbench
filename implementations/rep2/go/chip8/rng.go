package chip8

// RNG constants for the CXNN linear congruential generator.
const (
	// RNGSeed is the initial generator state.
	RNGSeed uint32 = 0x12345678
	rngMul  uint32 = 1103515245
	rngAdd  uint32 = 12345
)

// NextRNG advances the generator state s once and returns the new state and
// the random byte derived from it.
func NextRNG(s uint32) (state uint32, b byte) {
	s = s*rngMul + rngAdd
	return s, byte(s >> 16)
}
