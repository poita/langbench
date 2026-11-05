package fulltext

import "slices"

// occurrences is the result of an atom: ascending documents and, for
// docs[i], the ascending start positions pos[starts[i]:starts[i+1]] of the
// atom's occurrences. It has the same layout as postings.
type occurrences = postings

// positions returns the start positions in the i-th document of o.
func (o *occurrences) positions(i int) []int32 { return o.pos[o.starts[i]:o.starts[i+1]] }

// find returns the index of doc in o.docs, or -1.
func (o *occurrences) find(doc int32) int {
	if i, ok := slices.BinarySearch(o.docs, doc); ok {
		return i
	}
	return -1
}

// atomResult is the per-query evaluation of one distinct atom.
type atomResult struct {
	n   int // number of terms
	occ occurrences
}

// resolve computes the occurrences of the atom with the given terms. A term
// missing from the index yields an empty result.
func (ix *Index) resolve(terms []string) *atomResult {
	res := &atomResult{n: len(terms)}
	ps := make([]*postings, len(terms))
	for i, t := range terms {
		id, ok := ix.terms[t]
		if !ok {
			return res
		}
		ps[i] = &ix.posts[id]
	}
	if len(ps) == 1 {
		res.occ = *ps[0] // used directly, not copied
		return res
	}
	res.occ = phrase(ps)
	return res
}

// phrase finds the occurrences of the term sequence whose postings are ps:
// start positions p such that term i is at p+i.
func phrase(ps []*postings) occurrences {
	rare := 0
	for i, p := range ps {
		if len(p.docs) < len(ps[rare].docs) {
			rare = i
		}
	}
	var out occurrences
	cursor := make([]int, len(ps))
	idx := make([]int, len(ps))
	lists := make([][]int32, len(ps))
	var cand []int32
docs:
	for _, d := range ps[rare].docs {
		for i, p := range ps {
			j, ok := slices.BinarySearch(p.docs[cursor[i]:], d)
			cursor[i] += j
			if !ok {
				continue docs
			}
			idx[i] = cursor[i]
		}
		for i, p := range ps {
			lists[i] = p.pos[p.starts[idx[i]]:p.starts[idx[i]+1]]
		}
		cand = append(cand[:0], lists[0]...)
		for i := 1; i < len(ps) && len(cand) > 0; i++ {
			l, q, keep := lists[i], 0, cand[:0]
			for _, c := range cand {
				want := c + int32(i)
				for q < len(l) && l[q] < want {
					q++
				}
				if q == len(l) {
					break
				}
				if l[q] == want {
					keep = append(keep, c)
				}
			}
			cand = keep
		}
		if len(cand) > 0 {
			out.docs = append(out.docs, d)
			out.starts = append(out.starts, int32(len(out.pos)))
			out.pos = append(out.pos, cand...)
		}
	}
	out.starts = append(out.starts, int32(len(out.pos)))
	return out
}
