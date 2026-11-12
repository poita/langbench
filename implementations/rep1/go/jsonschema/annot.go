package jsonschema

// annots holds the evaluation annotations used by unevaluatedItems and
// unevaluatedProperties: which array indices and which object members a schema
// has evaluated. Index sets are kept compactly: a prefix [0,prefix), a suffix
// [from,∞), and an explicit bitmap for scattered indices (from "contains").
type annots struct {
	prefix  int
	hasFrom bool
	from    int
	bits    []bool
	props   map[string]struct{}
}

func (a *annots) markPrefix(n int) {
	if n > a.prefix {
		a.prefix = n
	}
}

func (a *annots) markFrom(i int) {
	if !a.hasFrom || i < a.from {
		a.hasFrom, a.from = true, i
	}
}

func (a *annots) markIndex(i, length int) {
	if a.bits == nil {
		a.bits = make([]bool, length)
	}
	if i < len(a.bits) {
		a.bits[i] = true
	}
}

func (a *annots) markProp(name string) {
	if a.props == nil {
		a.props = make(map[string]struct{})
	}
	a.props[name] = struct{}{}
}

func (a *annots) itemEvaluated(i int) bool {
	return i < a.prefix || (a.hasFrom && i >= a.from) || (i < len(a.bits) && a.bits[i])
}

func (a *annots) propEvaluated(name string) bool {
	_, ok := a.props[name]
	return ok
}

// merge adds everything in o to a.
func (a *annots) merge(o *annots) {
	a.markPrefix(o.prefix)
	if o.hasFrom {
		a.markFrom(o.from)
	}
	if len(o.bits) > 0 {
		if len(a.bits) < len(o.bits) {
			nb := make([]bool, len(o.bits))
			copy(nb, a.bits)
			a.bits = nb
		}
		for i, b := range o.bits {
			if b {
				a.bits[i] = true
			}
		}
	}
	for k := range o.props {
		a.markProp(k)
	}
}
