package bigint

import "math/bits"

// nat is an unsigned magnitude: little-endian base-2^32 limbs with no
// leading (most significant) zero limbs. The empty slice is zero.
type nat []uint32

const base = 1 << 32

func (x nat) norm() nat {
	n := len(x)
	for n > 0 && x[n-1] == 0 {
		n--
	}
	return x[:n]
}

func natFromUint64(v uint64) nat {
	switch {
	case v == 0:
		return nil
	case v < base:
		return nat{uint32(v)}
	}
	return nat{uint32(v), uint32(v >> 32)}
}

func natCmp(a, b nat) int {
	if len(a) != len(b) {
		if len(a) < len(b) {
			return -1
		}
		return 1
	}
	for i := len(a) - 1; i >= 0; i-- {
		if a[i] != b[i] {
			if a[i] < b[i] {
				return -1
			}
			return 1
		}
	}
	return 0
}

// natAdd returns a + b in O(len(a)+len(b)).
func natAdd(a, b nat) nat {
	if len(a) < len(b) {
		a, b = b, a
	}
	z := make(nat, len(a)+1)
	var carry uint64
	for i := range a {
		s := uint64(a[i]) + carry
		if i < len(b) {
			s += uint64(b[i])
		}
		z[i] = uint32(s)
		carry = s >> 32
	}
	z[len(a)] = uint32(carry)
	return z.norm()
}

// natSub returns a - b; it requires a >= b.
func natSub(a, b nat) nat {
	z := make(nat, len(a))
	var borrow uint64
	for i := range a {
		d := uint64(a[i]) - borrow
		if i < len(b) {
			d -= uint64(b[i])
		}
		z[i] = uint32(d)
		borrow = (d >> 32) & 1
	}
	return z.norm()
}

// natMul is classical schoolbook multiplication, O(len(a)*len(b)).
func natMul(a, b nat) nat {
	if len(a) == 0 || len(b) == 0 {
		return nil
	}
	z := make(nat, len(a)+len(b))
	for i, ai := range a {
		if ai == 0 {
			continue
		}
		var carry uint64
		for j, bj := range b {
			t := uint64(ai)*uint64(bj) + uint64(z[i+j]) + carry
			z[i+j] = uint32(t)
			carry = t >> 32
		}
		z[i+len(b)] = uint32(carry)
	}
	return z.norm()
}

// natMulAddW returns a*m + c for single-limb m and c.
func natMulAddW(a nat, m, c uint32) nat {
	z := make(nat, len(a)+1)
	carry := uint64(c)
	for i, ai := range a {
		t := uint64(ai)*uint64(m) + carry
		z[i] = uint32(t)
		carry = t >> 32
	}
	z[len(a)] = uint32(carry)
	return z.norm()
}

// natDivW divides a by a single non-zero limb.
func natDivW(a nat, w uint32) (nat, uint32) {
	q := make(nat, len(a))
	var r uint64
	for i := len(a) - 1; i >= 0; i-- {
		cur := r<<32 | uint64(a[i])
		q[i] = uint32(cur / uint64(w))
		r = cur % uint64(w)
	}
	return q.norm(), uint32(r)
}

// natDiv returns the quotient and remainder of a / b using Knuth's
// Algorithm D (TAOCP vol. 2, 4.3.1); b must be non-zero. The cost is
// O((len(a)-len(b)+1) * len(b)).
func natDiv(a, b nat) (q, r nat) {
	if len(b) == 0 {
		panic("bigint: division by zero")
	}
	if natCmp(a, b) < 0 {
		return nil, append(nat(nil), a...)
	}
	if len(b) == 1 {
		q, rem := natDivW(a, b[0])
		return q, natFromUint64(uint64(rem))
	}
	m, n := len(a), len(b)

	// D1: normalise so the top limb of the divisor has its high bit set.
	s := uint(bits.LeadingZeros32(b[n-1]))
	vn := make(nat, n)
	un := make(nat, m+1)
	if s == 0 {
		copy(vn, b)
		copy(un, a)
	} else {
		for i := n - 1; i > 0; i-- {
			vn[i] = b[i]<<s | b[i-1]>>(32-s)
		}
		vn[0] = b[0] << s
		un[m] = a[m-1] >> (32 - s)
		for i := m - 1; i > 0; i-- {
			un[i] = a[i]<<s | a[i-1]>>(32-s)
		}
		un[0] = a[0] << s
	}

	q = make(nat, m-n+1)
	for j := m - n; j >= 0; j-- {
		// D3: estimate the quotient digit.
		num := uint64(un[j+n])<<32 | uint64(un[j+n-1])
		qhat := num / uint64(vn[n-1])
		rhat := num % uint64(vn[n-1])
		for qhat >= base || qhat*uint64(vn[n-2]) > (rhat<<32|uint64(un[j+n-2])) {
			qhat--
			rhat += uint64(vn[n-1])
			if rhat >= base {
				break
			}
		}
		// D4: multiply and subtract.
		var borrow int64
		for i := 0; i < n; i++ {
			p := qhat * uint64(vn[i])
			t := int64(un[i+j]) - borrow - int64(p&0xFFFFFFFF)
			un[i+j] = uint32(t)
			borrow = int64(p>>32) - (t >> 32)
		}
		t := int64(un[j+n]) - borrow
		un[j+n] = uint32(t)
		q[j] = uint32(qhat)
		// D5/D6: the estimate was one too large; add the divisor back.
		if t < 0 {
			q[j]--
			var carry uint64
			for i := 0; i < n; i++ {
				t2 := uint64(un[i+j]) + uint64(vn[i]) + carry
				un[i+j] = uint32(t2)
				carry = t2 >> 32
			}
			un[j+n] += uint32(carry)
		}
	}

	// D8: denormalise the remainder.
	r = make(nat, n)
	if s == 0 {
		copy(r, un[:n])
	} else {
		for i := 0; i < n; i++ {
			r[i] = un[i]>>s | un[i+1]<<(32-s)
		}
	}
	return q.norm(), r.norm()
}
