package bigint

import "math/bits"

// base is the limb radix. 10⁹ is the largest power of ten whose limb products
// (plus a limb and a carry) fit comfortably in 64 bits.
const (
	base       = 1000000000
	baseDigits = 9
)

// nat is a natural number: little-endian limbs in [0, base) with no
// most-significant zero limbs. Zero is the empty (or nil) slice.
type nat []uint32

// norm strips most-significant zero limbs.
func (z nat) norm() nat {
	i := len(z)
	for i > 0 && z[i-1] == 0 {
		i--
	}
	return z[:i]
}

// cmpNat returns -1, 0 or +1 comparing x and y. Both must be normalised.
func cmpNat(x, y nat) int {
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

// addNat returns x + y.
func addNat(x, y nat) nat {
	if len(x) < len(y) {
		x, y = y, x
	}
	z := make(nat, len(x)+1)
	var carry uint32
	i := 0
	for ; i < len(y); i++ {
		s := x[i] + y[i] + carry // < 2*base, fits in uint32
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

// subNat returns x - y. It requires x >= y.
func subNat(x, y nat) nat {
	z := make(nat, len(x))
	var borrow uint32
	i := 0
	for ; i < len(y); i++ {
		d := x[i] - y[i] - borrow // wraps if negative
		if d >= base {            // wrapped (base < 2^31, so wrap is >= 2^31)
			d += base
			borrow = 1
		} else {
			borrow = 0
		}
		z[i] = d
	}
	for ; i < len(x); i++ {
		d := x[i] - borrow
		if d >= base {
			d += base
			borrow = 1
		} else {
			borrow = 0
		}
		z[i] = d
	}
	return z.norm()
}

// mulNat returns x * y using the schoolbook method. The shorter operand drives
// the outer loop so that the inner loop is the long one.
func mulNat(x, y nat) nat {
	if len(x) == 0 || len(y) == 0 {
		return nil
	}
	if len(x) > len(y) {
		x, y = y, x
	}
	z := make(nat, len(x)+len(y))
	for i, xi := range x {
		if xi == 0 {
			continue
		}
		row := z[i : i+len(y)+1]
		m := uint64(xi)
		var carry uint64
		for j, yj := range y {
			t := uint64(row[j]) + m*uint64(yj) + carry
			carry = t / base
			row[j] = uint32(t - carry*base)
		}
		row[len(y)] = uint32(carry) // slot above the row is still zero
	}
	return z.norm()
}

// divShort divides x by the single limb d (0 < d < base) and returns the
// quotient and remainder.
func divShort(x nat, d uint32) (nat, uint32) {
	q := make(nat, len(x))
	var rem uint64
	dd := uint64(d)
	for i := len(x) - 1; i >= 0; i-- {
		cur := rem*base + uint64(x[i])
		qi := cur / dd
		q[i] = uint32(qi)
		rem = cur - qi*dd
	}
	return q.norm(), uint32(rem)
}

// divNat returns the quotient and remainder of u / v. It requires v != 0.
func divNat(u, v nat) (q, r nat) {
	if cmpNat(u, v) < 0 {
		return nil, u
	}
	if len(v) == 1 {
		q, rem := divShort(u, v[0])
		if rem == 0 {
			return q, nil
		}
		return q, nat{rem}
	}
	return knuthD(u, v)
}

// knuthD implements Knuth's Algorithm D in base 10⁹. It requires
// len(v) >= 2 and u >= v.
func knuthD(u, v nat) (q, r nat) {
	n := len(v)
	m := len(u) - n

	// D1: normalise so the divisor's top limb is at least base/2.
	d := uint64(base / (uint64(v[n-1]) + 1))
	un := make([]uint32, len(u)+1)
	vn := make([]uint32, n)
	var carry uint64
	for i, x := range u {
		t := uint64(x)*d + carry
		carry = t / base
		un[i] = uint32(t - carry*base)
	}
	un[len(u)] = uint32(carry)
	carry = 0
	for i, x := range v {
		t := uint64(x)*d + carry
		carry = t / base
		vn[i] = uint32(t - carry*base)
	}
	// carry == 0: the top limb of v times d stays below base.

	vTop := uint64(vn[n-1])
	vSecond := uint64(vn[n-2])
	q = make(nat, m+1)

	for j := m; j >= 0; j-- {
		// D3: estimate the quotient limb.
		num := uint64(un[j+n])*base + uint64(un[j+n-1])
		qhat := num / vTop
		rhat := num - qhat*vTop
		for qhat >= base || qhat*vSecond > rhat*base+uint64(un[j+n-2]) {
			qhat--
			rhat += vTop
			if rhat >= base {
				break
			}
		}

		// D4: multiply and subtract qhat*vn from the window, fused.
		win := un[j : j+n+1]
		var c uint64
		var borrow uint32
		for i, vi := range vn {
			p := qhat*uint64(vi) + c
			c = p / base
			lo := uint32(p - c*base)
			t := win[i] - lo - borrow // wraps if negative
			if t >= base {
				t += base
				borrow = 1
			} else {
				borrow = 0
			}
			win[i] = t
		}
		top := int64(win[n]) - int64(c) - int64(borrow)
		if top < 0 {
			// D6: qhat was one too large; add the divisor back.
			qhat--
			var cr uint32
			for i, vi := range vn {
				s := win[i] + vi + cr
				if s >= base {
					s -= base
					cr = 1
				} else {
					cr = 0
				}
				win[i] = s
			}
			top += int64(cr) + base // the carry out cancels the borrow
			top %= base
		}
		win[n] = uint32(top)
		q[j] = uint32(qhat)
	}

	// D8: the remainder is the low n limbs of un, divided by d.
	r, _ = divShort(nat(un[:n]).norm(), uint32(d))
	return q.norm(), r
}

// powNat returns x**e by left-to-right binary exponentiation.
func powNat(x nat, e uint64) nat {
	if e == 0 {
		return nat{1}
	}
	if len(x) == 0 {
		return nil
	}
	z := x
	for i := bits.Len64(e) - 2; i >= 0; i-- {
		z = mulNat(z, z)
		if e>>uint(i)&1 == 1 {
			z = mulNat(z, x)
		}
	}
	return z
}
