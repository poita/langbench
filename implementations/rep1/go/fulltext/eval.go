package fulltext

import (
	"math/bits"

	"example.com/fulltext/query"
)

// docSet is a bitset over document numbers.
type docSet []uint64

func (ix *Index) newSet() docSet { return make(docSet, (len(ix.ids)+63)/64) }

// eval computes the set of documents matched by the tree. atoms maps
// query.Key to each atom's result. The empty tree matches nothing.
func (ix *Index) eval(n *query.Node, atoms map[string]*atomResult) docSet {
	set := ix.newSet()
	if n == nil {
		return set
	}
	switch n.Op {
	case query.Atom:
		for _, d := range atoms[query.Key(n.Terms)].occ.docs {
			set[d>>6] |= 1 << (uint(d) & 63)
		}
	case query.Not:
		c := ix.eval(n.Children[0], atoms)
		for i, w := range c {
			set[i] = ^w
		}
		if r := uint(len(ix.ids)) & 63; r != 0 {
			set[len(set)-1] &= 1<<r - 1
		}
	case query.And, query.Or:
		copy(set, ix.eval(n.Children[0], atoms))
		for _, ch := range n.Children[1:] {
			c := ix.eval(ch, atoms)
			for i := range set {
				if n.Op == query.And {
					set[i] &= c[i]
				} else {
					set[i] |= c[i]
				}
			}
		}
	}
	return set
}

// each calls f with every document number in the set, ascending.
func (s docSet) each(f func(doc int)) {
	for i, w := range s {
		for w != 0 {
			f(i<<6 + bits.TrailingZeros64(w))
			w &= w - 1
		}
	}
}
