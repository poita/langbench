package sat

// lit is an internal literal: variable v (0-based) is 2v when positive and
// 2v+1 when negated. Flipping the lowest bit negates the literal.
type lit int32

const litUndef lit = -1

func mkLit(v int, negated bool) lit {
	l := lit(v) << 1
	if negated {
		l |= 1
	}
	return l
}

func (l lit) neg() lit      { return l ^ 1 }
func (l lit) variable() int { return int(l >> 1) }
func (l lit) negated() bool { return l&1 == 1 }

// fromDimacs converts a non-zero DIMACS literal to an internal literal.
func fromDimacs(x int) lit {
	if x < 0 {
		return mkLit(-x-1, true)
	}
	return mkLit(x-1, false)
}

// Truth values stored per literal.
const (
	valTrue  int8 = 1
	valFalse int8 = -1
	valUndef int8 = 0
)
