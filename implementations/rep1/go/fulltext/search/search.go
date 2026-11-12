// Package search evaluates parsed queries against an [index.Index]: positional
// phrase matching, boolean set algebra, BM25 scoring, ranking and snippets.
package search

import (
	"math"
	"math/bits"
	"sort"

	"fulltext/analysis"
	"fulltext/index"
	"fulltext/query"
)

// BM25 parameters.
const (
	K1 = 1.2
	B  = 0.75
)

// Hit is one ranked result.
type Hit struct {
	// DocID is the identifier of the matching document.
	DocID string
	// Score is the BM25 score (0 when the query has no positive atom).
	Score float64
	// Snippet is the best-window excerpt of the document.
	Snippet string
}

// Searcher answers queries over one index. It is safe for concurrent use.
type Searcher struct {
	ix       *index.Index
	analyzer *analysis.Analyzer
	avgdl    float64
}

// New returns a Searcher over ix. Queries are analysed with a, which should be
// the analyzer the index was built with.
func New(ix *index.Index, a *analysis.Analyzer) *Searcher {
	return &Searcher{ix: ix, analyzer: a, avgdl: ix.AvgDocLen()}
}

// Search parses q and returns its top k hits, best first. Ties in score are
// broken by document id, smallest first.
func (s *Searcher) Search(q string, k int) []Hit {
	return s.Run(query.Parse(q, s.analyzer), k)
}

// Run evaluates an already parsed query; see [Searcher.Search]. The empty tree
// (nil) matches no document.
func (s *Searcher) Run(root *query.Node, k int) []Hit {
	if root == nil || k <= 0 {
		return nil
	}
	n := s.ix.NumDocs()

	// Each distinct atom is matched exactly once.
	matches := make(map[string]index.Postings)
	for _, a := range root.Atoms() {
		matches[a.Key()] = matchAtom(s.ix, a.Terms)
	}

	matched := s.eval(root, matches, n)
	positive := root.PositiveAtoms()
	plists := make([]index.Postings, len(positive))
	idf := make([]float64, len(positive))
	for i, a := range positive {
		plists[i] = matches[a.Key()]
		df := float64(plists[i].Len())
		idf[i] = math.Log((float64(n)-df+0.5)/(df+0.5) + 1)
	}

	// Score the matched documents. Matched documents are visited in ascending
	// index order, so a cursor per atom finds that atom's frequency.
	type scored struct {
		doc   int32
		score float64
	}
	var cands []scored
	cur := make([]int, len(positive))
	for w, word := range matched {
		for ; word != 0; word &= word - 1 {
			doc := int32(w*64 + bits.TrailingZeros64(word))
			length := float64(s.ix.Doc(int(doc)).Len)
			norm := 0.0
			if s.avgdl != 0 {
				norm = length / s.avgdl
			}
			score := 0.0
			for i, pl := range plists {
				for cur[i] < len(pl.Docs) && pl.Docs[cur[i]] < doc {
					cur[i]++
				}
				if cur[i] == len(pl.Docs) || pl.Docs[cur[i]] != doc {
					continue
				}
				f := float64(len(pl.Positions(cur[i])))
				score += idf[i] * (f * (K1 + 1)) / (f + K1*(1-B+B*norm))
			}
			cands = append(cands, scored{doc, score})
		}
	}
	sort.Slice(cands, func(i, j int) bool {
		if cands[i].score != cands[j].score {
			return cands[i].score > cands[j].score
		}
		return cands[i].doc < cands[j].doc
	})
	if len(cands) > k {
		cands = cands[:k]
	}

	hits := make([]Hit, len(cands))
	for i, c := range cands {
		doc := s.ix.Doc(int(c.doc))
		occ := make([]occurrences, 0, len(positive))
		for j, pl := range plists {
			if idx := pl.Find(c.doc); idx >= 0 {
				occ = append(occ, occurrences{starts: pl.Positions(idx), n: len(positive[j].Terms)})
			}
		}
		hits[i] = Hit{DocID: doc.ID, Score: c.score, Snippet: snippet(doc, bestWindow(doc.Len, occ))}
	}
	return hits
}

// eval computes the set of documents matched by a tree, as a bitset over the
// n document indexes. The empty tree is handled by the caller.
func (s *Searcher) eval(node *query.Node, matches map[string]index.Postings, n int) []uint64 {
	words := (n + 63) / 64
	switch node.Kind {
	case query.Atom:
		set := make([]uint64, words)
		for _, d := range matches[node.Key()].Docs {
			set[d>>6] |= 1 << (uint(d) & 63)
		}
		return set
	case query.Not:
		set := s.eval(node.Children[0], matches, n)
		for i := range set {
			set[i] = ^set[i]
		}
		if r := uint(n) & 63; r != 0 {
			set[words-1] &= 1<<r - 1
		}
		return set
	}
	set := s.eval(node.Children[0], matches, n)
	for _, c := range node.Children[1:] {
		other := s.eval(c, matches, n)
		for i := range set {
			if node.Kind == query.And {
				set[i] &= other[i]
			} else {
				set[i] |= other[i]
			}
		}
	}
	return set
}
