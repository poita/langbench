package bigint

// mul returns x * y using schoolbook long multiplication, O(len(x)·len(y)).
//
// Each partial product x[i]*y[j] is below 10^18 and the running limb and carry
// each below 10^9, so every intermediate value stays below 2^64.
func (x nat) mul(y nat) nat {
	if len(x) == 0 || len(y) == 0 {
		return nil
	}
	if len(x) < len(y) {
		x, y = y, x // inner loop runs over the longer operand
	}
	z := make(nat, len(x)+len(y))
	for j, yj := range y {
		if yj == 0 {
			continue
		}
		var carry uint64
		m := uint64(yj)
		zj := z[j : j+len(x)]
		for i, xi := range x {
			p := uint64(xi)*m + uint64(zj[i]) + carry
			carry = p / base
			zj[i] = uint32(p - carry*base)
		}
		z[j+len(x)] = uint32(carry) // this limb is untouched so far
	}
	return z.norm()
}

// sqr returns x * x.
func (x nat) sqr() nat { return x.mul(x) }
