package jsonvalue

// Equal reports whether a and b are equal under JSON Schema's notion of
// equality: values of different kinds are never equal, numbers are equal when
// they denote the same value (1 equals 1.0), arrays are compared element-wise,
// and objects are compared irrespective of member order.
func Equal(a, b Value) bool {
	if a.kind != b.kind {
		return false
	}
	switch a.kind {
	case Null:
		return true
	case Bool:
		return a.b == b.b
	case NumberKind:
		return a.n.Equal(*b.n)
	case String:
		return a.s == b.s
	case Array:
		if len(a.a) != len(b.a) {
			return false
		}
		for i := range a.a {
			if !Equal(a.a[i], b.a[i]) {
				return false
			}
		}
		return true
	case ObjectKind:
		if a.o == b.o {
			return true
		}
		if len(a.o.keys) != len(b.o.keys) {
			return false
		}
		for i, k := range a.o.keys {
			bv, ok := b.o.Get(k)
			if !ok || !Equal(a.o.vals[i], bv) {
				return false
			}
		}
		return true
	}
	return false
}

// Hash returns a 64-bit hash of v that is consistent with Equal: values that
// are Equal have equal hashes. It runs in time linear in the size of v.
func (v Value) Hash() uint64 {
	switch v.kind {
	case Null:
		return 0x9e3779b97f4a7c15
	case Bool:
		if v.b {
			return 0xc2b2ae3d27d4eb4f
		}
		return 0x165667b19e3779f9
	case NumberKind:
		h := mix(0x27d4eb2f165667c5, uint64(v.n.exp))
		if v.n.Sign() != 0 {
			if v.n.neg {
				h = mix(h, 1)
			}
			for _, w := range v.n.mant.Bits() {
				h = mix(h, uint64(w))
			}
		}
		return h
	case String:
		return hashString(0x85ebca6b, v.s)
	case Array:
		h := uint64(0x1b873593) + uint64(len(v.a))
		for _, e := range v.a {
			h = mix(h, e.Hash())
		}
		return h
	case ObjectKind:
		// Order-independent: sum member hashes.
		var sum uint64
		for i, k := range v.o.keys {
			sum += mix(hashString(0xcc9e2d51, k), v.o.vals[i].Hash())
		}
		return mix(0x2545f4914f6cdd1d, sum+uint64(len(v.o.keys)))
	}
	return 0
}

func mix(h, x uint64) uint64 {
	h ^= x + 0x9e3779b97f4a7c15 + (h << 6) + (h >> 2)
	h *= 0xff51afd7ed558ccd
	h ^= h >> 33
	return h
}

func hashString(seed uint64, s string) uint64 {
	h := seed ^ 0xcbf29ce484222325
	for i := 0; i < len(s); i++ {
		h ^= uint64(s[i])
		h *= 0x100000001b3
	}
	return mix(h, uint64(len(s)))
}
