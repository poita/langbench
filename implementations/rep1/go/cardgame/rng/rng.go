// Package rng implements the 64-bit xorshift* generator that Spiremark uses
// for shuffling and for random selection.
package rng

const multiplier = 0x2545F4914F6CDD1D

// Rand is a xorshift* generator. The zero value is not usable; call New.
type Rand struct {
	state uint64
}

// New returns a generator seeded with seed. A zero seed is replaced by the
// fixed constant required by the specification.
func New(seed uint64) *Rand {
	if seed == 0 {
		seed = multiplier
	}
	return &Rand{state: seed}
}

// Next returns the next 64-bit value.
func (r *Rand) Next() uint64 {
	s := r.state
	s ^= s >> 12
	s ^= s << 25
	s ^= s >> 27
	r.state = s
	return s * multiplier
}

// Below returns a value in [0, n) for n >= 1.
func (r *Rand) Below(n uint64) uint64 { return r.Next() % n }

// Shuffle permutes the n elements addressed by swap, consuming no randomness
// when n < 2. It is the Fisher-Yates variant fixed by the specification.
func (r *Rand) Shuffle(n int, swap func(i, j int)) {
	for i := n - 1; i >= 1; i-- {
		j := int(r.Below(uint64(i + 1)))
		swap(i, j)
	}
}
