package fulltext

import (
	"cmp"
	"math"
	"slices"

	"example.com/fulltext/query"
)

// BM25 parameters.
const (
	bm25K1 = 1.2
	bm25B  = 0.75
)

// Hit is one ranked search result.
type Hit struct {
	DocID   string  // document id
	Score   float64 // BM25 score
	Snippet string  // best 30-token window, whitespace collapsed
}

// Search parses queryText and returns the k best matching documents ranked by
// BM25 score (highest first, ties by ascending document id) with snippets.
// A query that parses to the empty tree, and k <= 0, return no hits.
func (ix *Index) Search(queryText string, k int) []Hit {
	return ix.SearchTree(query.Parse(queryText), k)
}

// SearchTree is like Search for an already parsed query.
func (ix *Index) SearchTree(root *query.Node, k int) []Hit {
	if root == nil || k <= 0 {
		return nil
	}
	// Each distinct atom is resolved exactly once; matching, scoring and
	// snippets all read the same result.
	atoms := map[string]*atomResult{}
	for _, a := range query.Atoms(root) {
		atoms[query.Key(a)] = ix.resolve(a)
	}
	matched := ix.eval(root, atoms)

	pos := query.PositiveAtoms(root)
	results := make([]*atomResult, len(pos))
	idf := make([]float64, len(pos))
	nDocs := float64(len(ix.ids))
	for i, a := range pos {
		results[i] = atoms[query.Key(a)]
		df := float64(len(results[i].occ.docs))
		idf[i] = math.Log((nDocs-df+0.5)/(df+0.5) + 1)
	}

	type scored struct {
		doc   int32
		score float64
	}
	var all []scored
	matched.each(func(d int) {
		ratio := 0.0
		if ix.avgdl > 0 {
			ratio = float64(ix.DocLen(d)) / ix.avgdl
		}
		norm := bm25K1 * (1 - bm25B + bm25B*ratio)
		var score float64
		for i, r := range results {
			j := r.occ.find(int32(d))
			if j < 0 {
				continue
			}
			f := float64(len(r.occ.positions(j)))
			score += idf[i] * (f * (bm25K1 + 1)) / (f + norm)
		}
		all = append(all, scored{int32(d), score})
	})
	slices.SortFunc(all, func(a, b scored) int {
		if c := cmp.Compare(b.score, a.score); c != 0 {
			return c
		}
		return cmp.Compare(a.doc, b.doc)
	})
	if len(all) > k {
		all = all[:k]
	}

	hits := make([]Hit, len(all))
	for i, s := range all {
		hits[i] = Hit{DocID: ix.ids[s.doc], Score: s.score, Snippet: ix.snippet(int(s.doc), results)}
	}
	return hits
}
