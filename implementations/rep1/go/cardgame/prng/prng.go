// Package prng implements the 64-bit xorshift* generator that drives every
// random choice in Spiremark (vault shuffles and random-unit selection).
package prng

const multiplier = 0x2545F4914F6CDD1D

// Rand is a xorshift* generator. The zero value is not usable; use New.
type Rand struct{ state uint64 }

// New returns a generator seeded with seed. A zero seed is replaced by the
// generator's fixed non-zero constant.
func New(seed uint64) *Rand {
	if seed == 0 {
		seed = multiplier
	}
	return &Rand{state: seed}
}

// Next returns the next 64-bit value.
func (r *Rand) Next() uint64 {
	r.state ^= r.state >> 12
	r.state ^= r.state << 25
	r.state ^= r.state >> 27
	return r.state * multiplier
}

// Below returns Next() % n. n must be at least 1.
func (r *Rand) Below(n uint64) uint64 { return r.Next() % n }

// Shuffle permutes k items in place by calling swap(i, j), using the
// specified downward Fisher-Yates walk. Lists of length 0 or 1 consume no
// randomness.
func (r *Rand) Shuffle(k int, swap func(i, j int)) {
	for i := k - 1; i >= 1; i-- {
		j := int(r.Below(uint64(i + 1)))
		swap(i, j)
	}
}
