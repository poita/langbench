package search

import "fulltext/index"

// matchAtom returns the occurrences of the phrase made of terms: for every
// document where terms[i] is at position p+i for all i, the start positions p.
//
// A single term returns its posting list unchanged. Longer phrases are found by
// a leapfrog intersection of the document lists followed, in each common
// document, by a merge of the position lists shifted by their offsets; the
// work is linear in the lengths of the lists involved.
func matchAtom(ix *index.Index, terms []string) index.Postings {
	lists := make([]index.Postings, len(terms))
	for i, t := range terms {
		p, ok := ix.Postings(t)
		if !ok {
			return index.Postings{}
		}
		lists[i] = p
	}
	if len(lists) == 1 {
		return lists[0]
	}

	var out index.Postings
	cur := make([]int, len(lists)) // cursor into each list's Docs
	pc := make([]int, len(lists))  // cursor into each list's positions in the current doc
	doc := lists[0].Docs[0]
	for {
		agree := true
		for i, l := range lists {
			for cur[i] < len(l.Docs) && l.Docs[cur[i]] < doc {
				cur[i]++
			}
			if cur[i] == len(l.Docs) {
				return out
			}
			if l.Docs[cur[i]] > doc {
				doc, agree = l.Docs[cur[i]], false
			}
		}
		if !agree {
			continue
		}

		first := lists[0].Positions(cur[0])
		for i := range pc {
			pc[i] = 0
		}
		before := len(out.Pos)
	positions:
		for _, p := range first {
			for i := 1; i < len(lists); i++ {
				ps := lists[i].Positions(cur[i])
				want := p + int32(i)
				for pc[i] < len(ps) && ps[pc[i]] < want {
					pc[i]++
				}
				if pc[i] == len(ps) {
					break positions // no later start can match either
				}
				if ps[pc[i]] != want {
					continue positions
				}
			}
			out.Pos = append(out.Pos, p)
		}
		if len(out.Pos) > before {
			out.Docs = append(out.Docs, doc)
			out.Ends = append(out.Ends, int32(len(out.Pos)))
		}
		for i := range cur {
			cur[i]++
			if cur[i] == len(lists[i].Docs) {
				return out
			}
		}
		doc = lists[0].Docs[cur[0]]
	}
}
