package bigint

// base is the radix of a limb. 10^9 is the largest power of ten whose square
// (plus carries) still fits in a uint64, and it makes decimal conversion a
// matter of slicing the digit string into groups of baseDigits.
const (
	base       = 1_000_000_000
	baseDigits = 9
)

// nat is a natural number: little-endian limbs in base 10^9 with no
// most-significant zero limbs. Zero is the empty slice.
type nat []uint32

// norm strips most-significant zero limbs.
func (z nat) norm() nat {
	i := len(z)
	for i > 0 && z[i-1] == 0 {
		i--
	}
	return z[:i]
}

// natFromUint64 converts a machine word to a nat.
func natFromUint64(v uint64) nat {
	var z nat
	for v > 0 {
		z = append(z, uint32(v%base))
		v /= base
	}
	return z
}

// uint64 returns the value of x and whether it fits in a uint64.
func (x nat) uint64() (uint64, bool) {
	var v uint64
	for i := len(x) - 1; i >= 0; i-- {
		// v*base + limb must not exceed MaxUint64.
		if v > (^uint64(0)-uint64(x[i]))/base {
			return 0, false
		}
		v = v*base + uint64(x[i])
	}
	return v, true
}

// cmp returns -1, 0 or +1 as x <, == or > y.
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
	for i := range x {
		s := x[i] + carry
		if i < len(y) {
			s += y[i]
		}
		if s >= base {
			s -= base
			carry = 1
		} else {
			carry = 0
		}
		z[i] = s
	}
	z[len(x)] = carry
	return z.norm()
}

// sub returns x - y. It requires x >= y.
func (x nat) sub(y nat) nat {
	z := make(nat, len(x))
	var borrow uint32
	for i := range x {
		d := x[i] + base - borrow
		if i < len(y) {
			d -= y[i]
		}
		if d >= base {
			d -= base
			borrow = 0
		} else {
			borrow = 1
		}
		z[i] = d
	}
	return z.norm()
}

// mul returns x * y using schoolbook long multiplication.
func (x nat) mul(y nat) nat {
	if len(x) == 0 || len(y) == 0 {
		return nil
	}
	if len(x) < len(y) {
		x, y = y, x
	}
	z := make(nat, len(x)+len(y))
	for j, yj := range y {
		if yj == 0 {
			continue
		}
		var carry uint64
		row := z[j : j+len(x)]
		for i, xi := range x {
			t := uint64(xi)*uint64(yj) + uint64(row[i]) + carry
			carry = t / base
			row[i] = uint32(t - carry*base)
		}
		z[j+len(x)] = uint32(carry)
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
		t := uint64(xi)*uint64(m) + carry
		carry = t / base
		z[i] = uint32(t - carry*base)
	}
	z[len(x)] = uint32(carry)
	return z.norm()
}

// divLimb returns the quotient and remainder of x / d for a single limb
// 0 < d < base.
func (x nat) divLimb(d uint32) (nat, uint32) {
	q := make(nat, len(x))
	var rem uint64
	for i := len(x) - 1; i >= 0; i-- {
		cur := rem*base + uint64(x[i])
		qi := cur / uint64(d)
		q[i] = uint32(qi)
		rem = cur - qi*uint64(d)
	}
	return q.norm(), uint32(rem)
}

// divmod returns the quotient and remainder of x / y using Knuth's
// Algorithm D (TAOCP vol. 2, 4.3.1). It requires y != 0.
func (x nat) divmod(y nat) (q, r nat) {
	if len(y) == 0 {
		panic("bigint: division by zero")
	}
	if x.cmp(y) < 0 {
		return nil, x
	}
	if len(y) == 1 {
		q, rem := x.divLimb(y[0])
		return q, natFromUint64(uint64(rem))
	}

	// D1: normalise so that the divisor's top limb is >= base/2. Then each
	// quotient-digit estimate is at most 2 too large.
	d := uint32(base / (uint64(y[len(y)-1]) + 1))
	vn := y
	un := make(nat, len(x)+1)
	if d == 1 {
		copy(un, x)
	} else {
		vn = y.mulLimb(d)
		copy(un, x.mulLimb(d))
	}
	n := len(vn)
	m := len(x) - n
	q = make(nat, m+1)
	vTop := uint64(vn[n-1])
	vNext := uint64(vn[n-2])

	for j := m; j >= 0; j-- {
		// D3: estimate the quotient digit from the top two limbs.
		num := uint64(un[j+n])*base + uint64(un[j+n-1])
		qhat := num / vTop
		rhat := num - qhat*vTop
		for qhat >= base || qhat*vNext > rhat*base+uint64(un[j+n-2]) {
			qhat--
			rhat += vTop
			if rhat >= base {
				break
			}
		}

		// D4: multiply and subtract qhat*vn from un[j : j+n+1].
		var carry uint64
		var borrow int64
		for i := 0; i < n; i++ {
			p := qhat*uint64(vn[i]) + carry
			carry = p / base
			t := int64(un[i+j]) - int64(p-carry*base) - borrow
			if t < 0 {
				t += base
				borrow = 1
			} else {
				borrow = 0
			}
			un[i+j] = uint32(t)
		}
		t := int64(un[j+n]) - int64(carry) - borrow
		if t < 0 {
			// D6: qhat was one too large; add the divisor back.
			qhat--
			var c uint32
			for i := 0; i < n; i++ {
				s := un[i+j] + vn[i] + c
				if s >= base {
					s -= base
					c = 1
				} else {
					c = 0
				}
				un[i+j] = s
			}
			t += int64(c)
		}
		un[j+n] = uint32(t) // always 0 here
		q[j] = uint32(qhat)
	}

	// D8: denormalise the remainder.
	r = un[:n].norm()
	if d != 1 {
		r, _ = r.divLimb(d)
	}
	return q.norm(), r
}

// pow returns x**e by binary exponentiation (left-to-right square and
// multiply).
func (x nat) pow(e uint64) nat {
	result := natFromUint64(1)
	for bit := 63; bit >= 0; bit-- {
		if len(result) != 1 || result[0] != 1 {
			result = result.mul(result)
		}
		if e>>uint(bit)&1 == 1 {
			result = result.mul(x)
		}
	}
	return result
}
