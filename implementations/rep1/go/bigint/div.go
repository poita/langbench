package bigint

// divMod returns the quotient and remainder of u / v using Knuth's
// Algorithm D (TAOCP vol. 2, §4.3.1). v must be non-zero.
func (u nat) divMod(v nat) (q, r nat) {
	n := len(v)
	switch {
	case n == 0:
		panic("bigint: nat division by zero")
	case u.cmp(v) < 0:
		return nil, append(nat(nil), u...)
	case n == 1:
		q, rl := u.divLimb(v[0])
		return q, natFromUint64(uint64(rl))
	}

	// D1: normalise so that the top limb of the divisor is >= base/2.
	d := uint32(base / (uint64(v[n-1]) + 1))
	vn := v.mulLimbN(d, n)
	un := u.mulLimbN(d, len(u)+1)

	m := len(u) - n
	q = make(nat, m+1)
	vTop := uint64(vn[n-1])
	vSecond := uint64(vn[n-2])

	for j := m; j >= 0; j-- {
		// D3: estimate the quotient digit from the top two limbs.
		num := uint64(un[j+n])*base + uint64(un[j+n-1])
		qhat := num / vTop
		rhat := num % vTop
		for qhat >= base || qhat*vSecond > rhat*base+uint64(un[j+n-2]) {
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

		// D5/D6: if the subtraction went negative, qhat was one too large;
		// add the divisor back.
		if t < 0 {
			qhat--
			t += base
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
			if t >= base {
				t -= base
			}
		}
		un[j+n] = uint32(t)
		q[j] = uint32(qhat)
	}

	// D8: the remainder is the normalised un[0:n] divided by d.
	r, _ = nat(un[:n]).norm().divLimb(d)
	return q.norm(), r
}

// mulLimbN returns x * m as a nat of exactly size limbs (not normalised).
// The product must fit in size limbs.
func (x nat) mulLimbN(m uint32, size int) nat {
	z := make(nat, size)
	var carry uint64
	for i, xi := range x {
		p := uint64(xi)*uint64(m) + carry
		carry = p / base
		z[i] = uint32(p - carry*base)
	}
	if carry != 0 {
		z[len(x)] = uint32(carry)
	}
	return z
}
