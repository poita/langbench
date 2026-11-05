package bigint

// A limb is one base-10⁹ digit of a magnitude.
type limb = uint32

const (
	// base is the limb radix. 10⁹ is the largest power of ten whose limb
	// products (plus carries) fit comfortably in 64 bits.
	base = 1_000_000_000
	// baseDigits is the number of decimal digits per limb.
	baseDigits = 9
)

// A nat is a magnitude: little-endian limbs, each below base, with no
// most-significant zero limbs. Zero is the empty (nil) nat.
type nat []limb

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

// add returns x + y.
func (x nat) add(y nat) nat {
	if len(x) < len(y) {
		x, y = y, x
	}
	if len(y) == 0 {
		return x
	}
	z := make(nat, len(x)+1)
	var carry limb
	for i, xi := range x {
		s := xi + carry // both < 2³¹ish, no overflow in uint32
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
	return z.trim()
}

// sub returns x - y. It requires x >= y.
func (x nat) sub(y nat) nat {
	if len(y) == 0 {
		return x
	}
	z := make(nat, len(x))
	var borrow limb
	for i, xi := range x {
		d := int64(xi) - int64(borrow)
		if i < len(y) {
			d -= int64(y[i])
		}
		if d < 0 {
			d += base
			borrow = 1
		} else {
			borrow = 0
		}
		z[i] = limb(d)
	}
	return z.trim()
}

// mul returns x · y using the schoolbook algorithm.
func (x nat) mul(y nat) nat {
	if len(x) == 0 || len(y) == 0 {
		return nil
	}
	// Rows over the shorter operand, columns over the longer one.
	if len(x) > len(y) {
		x, y = y, x
	}
	z := make(nat, len(x)+len(y))
	for i, xi := range x {
		if xi == 0 {
			continue
		}
		a := uint64(xi)
		var carry uint64
		row := z[i : i+len(y)]
		for j, yj := range y {
			t := uint64(row[j]) + a*uint64(yj) + carry
			carry = t / base
			row[j] = limb(t - carry*base)
		}
		// z[i+len(y)] has not been written yet, so it is still zero.
		z[i+len(y)] = limb(carry)
	}
	return z.trim()
}

// divLimb divides x by the single limb d (d != 0), returning the quotient
// and remainder.
func (x nat) divLimb(d limb) (q nat, r limb) {
	if len(x) == 0 {
		return nil, 0
	}
	q = make(nat, len(x))
	var rem uint64
	dd := uint64(d)
	for i := len(x) - 1; i >= 0; i-- {
		cur := rem*base + uint64(x[i])
		qi := cur / dd
		q[i] = limb(qi)
		rem = cur - qi*dd
	}
	return q.trim(), limb(rem)
}

// divMod returns the quotient and remainder of x / y. y must be non-zero.
// The returned values may share storage with x.
func (x nat) divMod(y nat) (q, r nat) {
	if len(y) == 0 {
		panic("bigint: division by zero")
	}
	if x.cmp(y) < 0 {
		return nil, x
	}
	if len(y) == 1 {
		q, rem := x.divLimb(y[0])
		if rem == 0 {
			return q, nil
		}
		return q, nat{rem}
	}
	return x.knuthD(y)
}

// knuthD implements Knuth's Algorithm D (TAOCP vol. 2, 4.3.1) in base 10⁹.
// It requires len(y) >= 2 and x >= y.
func (x nat) knuthD(y nat) (q, r nat) {
	n, m := len(x), len(y)

	// D1: normalise so the divisor's top limb is at least base/2.
	d := limb(base / (uint64(y[m-1]) + 1))
	u := make(nat, n+1)
	v := make(nat, m)
	u[n] = mulLimbInto(u[:n], x, d)
	mulLimbInto(v, y, d) // the normalised divisor has no carry out

	q = make(nat, n-m+1)
	vTop := uint64(v[m-1])
	vNext := uint64(v[m-2])

	for j := n - m; j >= 0; j-- {
		// D3: estimate the quotient limb.
		num := uint64(u[j+m])*base + uint64(u[j+m-1])
		qhat := num / vTop
		rhat := num - qhat*vTop
		for qhat >= base || qhat*vNext > rhat*base+uint64(u[j+m-2]) {
			qhat--
			rhat += vTop
			if rhat >= base {
				break
			}
		}

		// D4: u[j : j+m+1] -= qhat · v, in one fused pass.
		window := u[j : j+m+1]
		var carry uint64
		var borrow int64
		for i, vi := range v {
			p := qhat*uint64(vi) + carry
			carry = p / base
			low := p - carry*base
			t := int64(window[i]) - int64(low) - borrow
			if t < 0 {
				t += base
				borrow = 1
			} else {
				borrow = 0
			}
			window[i] = limb(t)
		}
		t := int64(window[m]) - int64(carry) - borrow
		if t < 0 {
			// D6: qhat was one too large; add v back once.
			t += base
			qhat--
			var c limb
			for i, vi := range v {
				s := window[i] + vi + c
				if s >= base {
					s -= base
					c = 1
				} else {
					c = 0
				}
				window[i] = s
			}
			t += int64(c)
			if t >= base {
				t -= base
			}
		}
		window[m] = limb(t)
		q[j] = limb(qhat)
	}

	// D8: denormalise the remainder.
	r, _ = u[:m].trim().divLimb(d)
	return q.trim(), r
}

// mulLimbInto sets dst = x · f (len(dst) == len(x)) and returns the carry out
// of the top limb.
func mulLimbInto(dst, x nat, f limb) limb {
	var carry uint64
	ff := uint64(f)
	for i, xi := range x {
		p := uint64(xi)*ff + carry
		carry = p / base
		dst[i] = limb(p - carry*base)
	}
	return limb(carry)
}

// pow returns x^e by left-to-right binary exponentiation.
func (x nat) pow(e uint64) nat {
	if e == 0 {
		return nat{1}
	}
	if len(x) == 0 {
		return nil
	}
	if len(x) == 1 && x[0] == 1 {
		return x
	}
	z := x
	for bit := bitLen(e) - 2; bit >= 0; bit-- {
		z = z.mul(z)
		if e>>uint(bit)&1 == 1 {
			z = z.mul(x)
		}
	}
	return z
}

func bitLen(e uint64) int {
	n := 0
	for ; e != 0; e >>= 1 {
		n++
	}
	return n
}
