// Package fulltext is a small full-text search engine: a positional inverted
// index over plain-text documents, a boolean/phrase query language, BM25
// ranking and best-window snippets.
//
// Typical use:
//
//	eng := fulltext.New([]fulltext.Document{
//		{ID: "note", Text: "The quick brown fox jumps over the lazy dog."},
//	})
//	for _, hit := range eng.Search(`fox AND "lazy dog"`, 10) {
//		fmt.Printf("%s %.4f %s\n", hit.DocID, hit.Score, hit.Snippet)
//	}
//
// The engine is assembled from smaller packages that can be used on their own:
//
//   - fulltext/porter: the Porter stemmer
//   - fulltext/analysis: tokenising, case folding, stop words, term extraction
//   - fulltext/index: the positional inverted index
//   - fulltext/query: the query language parser
//   - fulltext/search: matching, BM25 scoring, ranking and snippets
//   - fulltext/batch: the directory-based batch runner used by the CLI
//
// Query syntax: words and "quoted phrases" are atoms; adjacent atoms mean AND;
// AND, OR and NOT (upper case) and parentheses combine them, with NOT binding
// tightest, then AND, then OR. Parsing never fails; see package query.
package fulltext

import (
	"fulltext/analysis"
	"fulltext/index"
	"fulltext/search"
)

// Document is a piece of text with a unique identifier. Results are ordered by
// id when scores tie, so ids are compared in byte order.
type Document struct {
	ID   string
	Text string
}

// Hit is one search result.
type Hit = search.Hit

// Stats summarises an indexed corpus.
type Stats struct {
	Documents int     // N
	Tokens    int     // total tokens over all documents, stop words included
	Terms     int     // distinct index terms
	AvgDocLen float64 // Tokens / Documents, 0 for an empty corpus
}

// Engine is an immutable searchable corpus. It is safe for concurrent use.
type Engine struct {
	ix       *index.Index
	searcher *search.Searcher
}

// New indexes docs and returns an Engine over them.
func New(docs []Document) *Engine {
	an := analysis.NewAnalyzer()
	b := index.NewBuilder(an)
	for _, d := range docs {
		b.Add(d.ID, d.Text)
	}
	ix := b.Build()
	return &Engine{ix: ix, searcher: search.New(ix, an)}
}

// Search evaluates the query text q and returns at most k hits, best first
// (highest BM25 score, then smallest document id).
func (e *Engine) Search(q string, k int) []Hit {
	return e.searcher.Search(q, k)
}

// Stats returns corpus statistics.
func (e *Engine) Stats() Stats {
	return Stats{
		Documents: e.ix.NumDocs(),
		Tokens:    e.ix.NumTokens(),
		Terms:     e.ix.NumTerms(),
		AvgDocLen: e.ix.AvgDocLen(),
	}
}
