package depresolve

import "sort"

// index is the compiled, read-only form of a registry: package names are
// interned to dense ids, versions are packed keys sorted newest first, and
// every requirement carries its precomputed window of candidate indices.
// An index is immutable once built and may be shared by concurrent solvers.
type index struct {
	names []string // package id -> name
	ids   map[string]int32
	vkeys [][]uint64 // package id -> version keys, newest first
	vreqs [][]span   // package id -> per-version span into reqs
	reqs  []creq
}

// span is the slice [start, start+n) of index.reqs.
type span struct{ start, n int32 }

// creq is a compiled requirement: target package, interval, and the window
// [first, last) of candidate indices in the target's newest-first list.
// An empty window has last <= first.
type creq struct {
	pkg         int32
	lo, hi      uint64
	first, last int32
}

func (ix *index) intern(name string) int32 {
	if id, ok := ix.ids[name]; ok {
		return id
	}
	id := int32(len(ix.names))
	ix.names = append(ix.names, name)
	ix.ids[name] = id
	return id
}

// compile resolves a requirement against the final version lists. A name
// that is unknown maps to the sentinel package id len(names), which has no
// versions.
func (ix *index) compile(q Requirement) creq {
	id, ok := ix.ids[q.Name]
	if !ok {
		return creq{pkg: int32(len(ix.names)), lo: q.Range.Lo, hi: q.Range.Hi}
	}
	vk := ix.vkeys[id]
	lo, hi := q.Range.Lo, q.Range.Hi
	first := sort.Search(len(vk), func(j int) bool { return vk[j] < hi })
	last := sort.Search(len(vk), func(j int) bool { return vk[j] < lo })
	if last < first {
		last = first
	}
	return creq{pkg: id, lo: lo, hi: hi, first: int32(first), last: int32(last)}
}

func buildIndex(entries []entry) *index {
	ix := &index{ids: make(map[string]int32)}
	groups := [][]int32{} // package id -> entry numbers
	for i := range entries {
		p := ix.intern(entries[i].name)
		for int(p) >= len(groups) {
			groups = append(groups, nil)
		}
		groups[p] = append(groups[p], int32(i))
	}
	np := len(groups)
	ix.vkeys = make([][]uint64, np)
	ix.vreqs = make([][]span, np)

	// Every package that has versions is interned above; names that occur
	// only in requirements stay unknown and compile to the sentinel.
	total := 0
	for i := range entries {
		total += len(entries[i].reqs)
	}
	ix.reqs = make([]creq, 0, total)

	for p, g := range groups {
		sort.Slice(g, func(a, b int) bool {
			return entries[g[a]].version.Key() > entries[g[b]].version.Key()
		})
		ix.vkeys[p] = make([]uint64, len(g))
		for i, e := range g {
			ix.vkeys[p][i] = entries[e].version.Key()
		}
	}
	// Second pass: all version lists are final, so windows can be computed.
	for p, g := range groups {
		ix.vreqs[p] = make([]span, len(g))
		for i, e := range g {
			start := int32(len(ix.reqs))
			for _, q := range entries[e].reqs {
				ix.reqs = append(ix.reqs, ix.compile(q))
			}
			ix.vreqs[p][i] = span{start, int32(len(entries[e].reqs))}
		}
	}
	return ix
}
