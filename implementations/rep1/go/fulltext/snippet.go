package fulltext

// windowTokens is the snippet window width W, in tokens.
const windowTokens = 30

// snippet builds the snippet of document doc for the given positive atom
// results: the window of 30 tokens containing the most distinct atoms, then
// the most occurrences, then starting earliest.
func (ix *Index) snippet(doc int, atoms []*atomResult) string {
	spans := ix.spans[doc]
	l := len(spans) / 2
	if l == 0 {
		return ""
	}
	s := ix.bestWindow(doc, l, atoms)
	e := min(s+windowTokens, l) - 1
	return collapseSpace(ix.texts[doc][spans[2*s]:spans[2*e+1]])
}

// bestWindow returns the start of the best window using difference arrays, in
// O(L + occurrences). Window starts range over 0..last = L-30; an occurrence
// of an n-term atom at p lies inside exactly the windows
// [max(0, p+n-30), min(p, last)].
func (ix *Index) bestWindow(doc, l int, atoms []*atomResult) int {
	if l <= windowTokens {
		return 0
	}
	last := l - windowTokens
	total := make([]int32, last+2)
	distinct := make([]int32, last+2)
	any := false
	for _, a := range atoms {
		if a.n > windowTokens {
			continue
		}
		j := a.occ.find(int32(doc))
		if j < 0 {
			continue
		}
		mlo, mhi := -1, -2 // current merged interval for the distinct count
		for _, p := range a.occ.positions(j) {
			lo := max(0, int(p)+a.n-windowTokens)
			hi := min(int(p), last)
			total[lo]++
			total[hi+1]--
			any = true
			if lo > mhi+1 {
				if mlo >= 0 {
					distinct[mlo]++
					distinct[mhi+1]--
				}
				mlo = lo
			}
			mhi = max(mhi, hi)
		}
		if mlo >= 0 {
			distinct[mlo]++
			distinct[mhi+1]--
		}
	}
	if !any {
		return 0
	}
	best, bd, bt := 0, int32(-1), int32(-1)
	var d, t int32
	for s := 0; s <= last; s++ {
		d += distinct[s]
		t += total[s]
		if d > bd || (d == bd && t > bt) {
			best, bd, bt = s, d, t
		}
	}
	return best
}

// collapseSpace copies b to a string, replacing each maximal run of the
// whitespace code points U+0009-U+000D, U+0020 and U+00A0 with one space.
func collapseSpace(b []byte) string {
	out := make([]byte, 0, len(b))
	for i := 0; i < len(b); {
		n := 0
		switch c := b[i]; {
		case c == ' ' || (c >= 9 && c <= 13):
			n = 1
		case c == 0xC2 && i+1 < len(b) && b[i+1] == 0xA0:
			n = 2
		}
		if n == 0 {
			out = append(out, b[i])
			i++
			continue
		}
		for i += n; i < len(b); {
			if c := b[i]; c == ' ' || (c >= 9 && c <= 13) {
				i++
			} else if c == 0xC2 && i+1 < len(b) && b[i+1] == 0xA0 {
				i += 2
			} else {
				break
			}
		}
		out = append(out, ' ')
	}
	return string(out)
}
