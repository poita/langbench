package bigint

// base is the limb radix: the largest power of ten whose limb products fit
// comfortably in 64 bits.
const (
	base       = 1_000_000_000
	baseDigits = 9
)

// nat is an unsigned magnitude: little-endian limbs in [0, base) with no
// most-significant zero limbs. Zero is the empty (nil) nat.
type nat []uint32

// trim removes most-significant zero limbs.
func (x nat) trim() nat {
	n := len(x)
	for n > 0 && x[n-1] == 0 {
		n--
	}
	return x[:n]
}

// cmp compares two normalised magnitudes, returning -1, 0 or 1.
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

// natFromUint64 returns the magnitude of v.
func natFromUint64(v uint64) nat {
	var z nat
	for v != 0 {
		z = append(z, uint32(v%base))
		v /= base
	}
	return z
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
	return z.trim()
}

// sub returns x - y; it requires x >= y.
func (x nat) sub(y nat) nat {
	z := make(nat, len(x))
	var borrow uint32
	i := 0
	for ; i < len(y); i++ {
		d := x[i] + base - y[i] - borrow
		if d >= base {
			d -= base
			borrow = 0
		} else {
			borrow = 1
		}
		z[i] = d
	}
	for ; i < len(x); i++ {
		d := x[i] + base - borrow
		if d >= base {
			d -= base
			borrow = 0
		} else {
			borrow = 1
		}
		z[i] = d
	}
	return z.trim()
}

// mul returns x * y using schoolbook multiplication. Rows run over the limbs
// of the shorter operand so that the inner loop is the long one.
func (x nat) mul(y nat) nat {
	if len(x) == 0 || len(y) == 0 {
		return nil
	}
	if len(x) < len(y) {
		x, y = y, x
	}
	// x is the longer operand.
	z := make(nat, len(x)+len(y))
	for i, yi := range y {
		if yi == 0 {
			continue
		}
		m := uint64(yi)
		row := z[i : i+len(x)+1]
		var carry uint64
		for j, xj := range x {
			t := uint64(row[j]) + uint64(xj)*m + carry
			carry = t / base
			row[j] = uint32(t - carry*base)
		}
		row[len(x)] = uint32(carry) // still zero before this row
	}
	return z.trim()
}

// divModSmall divides x by the single limb d (non-zero), returning the
// quotient and remainder.
func (x nat) divModSmall(d uint32) (nat, uint32) {
	q := make(nat, len(x))
	var rem uint64
	dd := uint64(d)
	for i := len(x) - 1; i >= 0; i-- {
		cur := rem*base + uint64(x[i])
		qi := cur / dd
		q[i] = uint32(qi)
		rem = cur - qi*dd
	}
	return q.trim(), uint32(rem)
}

// divMod returns the quotient and remainder of u / v; v must be non-zero.
// The results may share storage with u.
func (u nat) divMod(v nat) (q, r nat) {
	if len(v) == 0 {
		panic("bigint: division by zero")
	}
	if u.cmp(v) < 0 {
		return nil, u
	}
	if len(v) == 1 {
		q, rem := u.divModSmall(v[0])
		return q, natFromUint64(uint64(rem))
	}
	return u.divModKnuth(v)
}

// divModKnuth is Knuth's Algorithm D (TAOCP vol. 2, 4.3.1) in base 10⁹.
// It requires len(v) >= 2 and u >= v.
func (u nat) divModKnuth(v nat) (nat, nat) {
	n := len(v)
	m := len(u) - n

	// D1: normalise so the divisor's top limb is at least base/2.
	d := uint64(base / (uint64(v[n-1]) + 1))
	un := make([]uint32, len(u)+1)
	vn := make([]uint32, n)
	var carry uint64
	for i, w := range u {
		t := uint64(w)*d + carry
		carry = t / base
		un[i] = uint32(t - carry*base)
	}
	un[len(u)] = uint32(carry)
	carry = 0
	for i, w := range v {
		t := uint64(w)*d + carry
		carry = t / base
		vn[i] = uint32(t - carry*base)
	}

	q := make(nat, m+1)
	vTop := uint64(vn[n-1])
	vSecond := uint64(vn[n-2])

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

		// D4: multiply and subtract qhat*v from the window un[j..j+n].
		window := un[j : j+n+1]
		var mc uint64 // product carry
		var borrow int64
		for i := 0; i < n; i++ {
			p := qhat*uint64(vn[i]) + mc
			mc = p / base
			lo := int64(p - mc*base)
			s := int64(window[i]) - lo - borrow
			if s < 0 {
				s += base
				borrow = 1
			} else {
				borrow = 0
			}
			window[i] = uint32(s)
		}
		s := int64(window[n]) - int64(mc) - borrow
		if s < 0 {
			// D6: qhat was one too large; add the divisor back.
			qhat--
			var c uint32
			for i := 0; i < n; i++ {
				t := window[i] + vn[i] + c
				if t >= base {
					t -= base
					c = 1
				} else {
					c = 0
				}
				window[i] = t
			}
			s += base + int64(c)
			if s >= base {
				s -= base
			}
		}
		window[n] = uint32(s)
		q[j] = uint32(qhat)
	}

	// D8: the remainder is the low n limbs, un-normalised.
	r, _ := nat(un[:n]).trim().divModSmall(uint32(d))
	return q.trim(), r
}
