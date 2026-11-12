package bigint

// base is the radix of a limb: 10^9, the largest power of ten that fits in a
// uint32, with products of two limbs (plus carries) fitting in a uint64.
const (
	base       = 1_000_000_000
	baseDigits = 9
)

// nat is a natural number: little-endian limbs in base 10^9 with no most
// significant zero limbs. Zero is the empty (or nil) slice.
type nat []uint32

// norm strips most significant zero limbs.
func (z nat) norm() nat {
	n := len(z)
	for n > 0 && z[n-1] == 0 {
		n--
	}
	return z[:n]
}

// natFromUint64 converts a machine word to a nat.
func natFromUint64(x uint64) nat {
	var z nat
	for x != 0 {
		z = append(z, uint32(x%base))
		x /= base
	}
	return z
}

// uint64 returns the value of x and whether it fits in a uint64.
func (x nat) uint64() (uint64, bool) {
	var v uint64
	for i := len(x) - 1; i >= 0; i-- {
		if v > (^uint64(0)-uint64(x[i]))/base {
			return 0, false
		}
		v = v*base + uint64(x[i])
	}
	return v, true
}

// cmp compares x and y, returning -1, 0 or +1.
func (x nat) cmp(y nat) int {
	if len(x) != len(y) {
		if len(x) < len(y) {
			return -1
		}
		return 1
	}
	for i := len(x) - 1; i >= 0; i-- {
		if x[i] != y[i] {
			if x[i] < y[i] {
				return -1
			}
			return 1
		}
	}
	return 0
}

// add returns x + y.
func (x nat) add(y nat) nat {
	if len(x) < len(y) {
		x, y = y, x
	}
	z := make(nat, len(x)+1)
	var carry uint32
	i := 0
	for ; i < len(y); i++ {
		s := x[i] + y[i] + carry // < 2·10^9+1 < 2^32
		if s >= base {
			s -= base
			carry = 1
		} else {
			carry = 0
		}
		z[i] = s
	}
	for ; i < len(x); i++ {
		s := x[i] + carry
		if s >= base {
			s -= base
			carry = 1
		} else {
			carry = 0
		}
		z[i] = s
	}
	z[i] = carry
	return z.norm()
}

// sub returns x - y. It requires x >= y.
func (x nat) sub(y nat) nat {
	z := make(nat, len(x))
	var borrow uint32
	i := 0
	for ; i < len(y); i++ {
		d := x[i] - y[i] - borrow // wraps around on underflow
		if x[i] < y[i]+borrow {
			d += base
			borrow = 1
		} else {
			borrow = 0
		}
		z[i] = d
	}
	for ; i < len(x); i++ {
		if x[i] < borrow {
			z[i] = x[i] + base - borrow
			borrow = 1
		} else {
			z[i] = x[i] - borrow
			borrow = 0
		}
	}
	if borrow != 0 {
		panic("bigint: nat.sub underflow")
	}
	return z.norm()
}

// mulLimb returns x * m for a single limb m < base.
func (x nat) mulLimb(m uint32) nat {
	if len(x) == 0 || m == 0 {
		return nil
	}
	z := make(nat, len(x)+1)
	var carry uint64
	for i, xi := range x {
		p := uint64(xi)*uint64(m) + carry
		z[i] = uint32(p % base)
		carry = p / base
	}
	z[len(x)] = uint32(carry)
	return z.norm()
}

// divLimb returns x / d and x % d for a single limb 0 < d < base.
func (x nat) divLimb(d uint32) (q nat, r uint32) {
	q = make(nat, len(x))
	var rem uint64
	for i := len(x) - 1; i >= 0; i-- {
		cur := rem*base + uint64(x[i])
		q[i] = uint32(cur / uint64(d))
		rem = cur % uint64(d)
	}
	return q.norm(), uint32(rem)
}
