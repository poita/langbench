package search

import (
	"strings"

	"fulltext/analysis"
	"fulltext/index"
)

// WindowSize is W, the number of tokens in a snippet window.
const WindowSize = 30

// occurrence list of one positive atom inside one document.
type occurrences struct {
	starts []int32 // start positions, ascending
	n      int     // number of terms in the atom
}

// bestWindow returns the start of the best window of a document of length
// docLen: most distinct atoms inside, then most occurrences inside, then the
// smallest start. It runs in O(docLen + total occurrences) using difference
// arrays over the window starts.
func bestWindow(docLen int, atoms []occurrences) int {
	const W = WindowSize
	if docLen <= W {
		return 0
	}
	nStarts := docLen - W + 1 // window starts 0 .. docLen-W
	distinct := make([]int32, nStarts+1)
	total := make([]int32, nStarts+1)
	any := false
	for _, a := range atoms {
		if a.n > W {
			continue // can never fit inside a window
		}
		last := -1 // highest window start already counted for this atom
		for _, p32 := range a.starts {
			p := int(p32)
			// Windows s containing the occurrence: s <= p and p+n-1 <= s+W-1.
			lo, hi := p+a.n-W, p
			if lo < 0 {
				lo = 0
			}
			if hi > nStarts-1 {
				hi = nStarts - 1
			}
			if lo > hi {
				continue
			}
			any = true
			total[lo]++
			total[hi+1]--
			// Occurrences are sorted, so lo and hi never decrease; the new
			// part of this atom's coverage is (last, hi].
			from := lo
			if last+1 > from {
				from = last + 1
			}
			if from <= hi {
				distinct[from]++
				distinct[hi+1]--
				last = hi
			}
		}
	}
	if !any {
		return 0
	}
	best, bestD, bestT := 0, int32(-1), int32(-1)
	var d, t int32
	for s := 0; s < nStarts; s++ {
		d += distinct[s]
		t += total[s]
		if d > bestD || (d == bestD && t > bestT) {
			best, bestD, bestT = s, d, t
		}
	}
	return best
}

// snippet renders the window of doc starting at token s: the original text from
// the first byte of token s to the last byte of the window's last token, with
// every run of whitespace collapsed to one space.
func snippet(doc *index.Doc, s int) string {
	if doc.Len == 0 {
		return ""
	}
	endTok := s + WindowSize
	if endTok > doc.Len {
		endTok = doc.Len
	}
	start, _ := doc.TokenSpan(s)
	_, end := doc.TokenSpan(endTok - 1)
	text := doc.Text[start:end]

	var sb strings.Builder
	sb.Grow(len(text))
	inSpace := false
	for _, r := range text {
		if analysis.IsSpace(r) {
			if !inSpace {
				sb.WriteByte(' ')
			}
			inSpace = true
			continue
		}
		inSpace = false
		sb.WriteRune(r)
	}
	return sb.String()
}
