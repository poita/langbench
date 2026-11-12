// Package index implements an in-memory positional inverted index.
//
// An [Index] is built once from a set of documents with a [Builder] and is
// immutable afterwards, so it may be shared freely between goroutines.
package index

import (
	"sort"

	"fulltext/analysis"
)

// Postings is a positional posting list: the documents that contain a term (or
// a phrase) and, for each, the sorted positions at which it occurs.
//
// Documents are referred to by their dense index in the [Index], which is
// their rank in document-id order. The fields are exported so that other
// packages can produce Postings for phrases; treat them as read-only.
type Postings struct {
	// Docs lists the document indexes in ascending order.
	Docs []int32
	// Ends[i] is the end offset into Pos of the positions of Docs[i]; the
	// positions of Docs[i] start at Ends[i-1] (0 for i = 0).
	Ends []int32
	// Pos holds the positions of every document, concatenated in Docs order,
	// ascending within each document.
	Pos []int32
}

// Len returns the number of documents in the list (the document frequency).
func (p Postings) Len() int { return len(p.Docs) }

// Positions returns the positions in the i-th document of the list.
func (p Postings) Positions(i int) []int32 {
	lo := int32(0)
	if i > 0 {
		lo = p.Ends[i-1]
	}
	return p.Pos[lo:p.Ends[i]]
}

// Find returns the list index of document doc, or -1 if it is not in the list.
func (p Postings) Find(doc int32) int {
	i := sort.Search(len(p.Docs), func(i int) bool { return p.Docs[i] >= doc })
	if i < len(p.Docs) && p.Docs[i] == doc {
		return i
	}
	return -1
}

// Doc is an indexed document.
type Doc struct {
	// ID is the document identifier.
	ID string
	// Text is the original text.
	Text string
	// Len is the number of tokens in the document, stop words included.
	Len int

	spans []int32 // start,end byte offsets of every token
}

// TokenSpan returns the half-open byte range of Text occupied by the token at
// position pos.
func (d *Doc) TokenSpan(pos int) (start, end int) {
	return int(d.spans[2*pos]), int(d.spans[2*pos+1])
}

// Index is an immutable positional inverted index.
type Index struct {
	docs   []Doc
	terms  map[string]*Postings
	tokens int
}

// NumDocs returns N, the number of documents.
func (ix *Index) NumDocs() int { return len(ix.docs) }

// Doc returns the document with the given dense index; documents are ordered by
// id (byte order).
func (ix *Index) Doc(i int) *Doc { return &ix.docs[i] }

// NumTokens returns the total number of tokens over all documents.
func (ix *Index) NumTokens() int { return ix.tokens }

// NumTerms returns the number of distinct terms.
func (ix *Index) NumTerms() int { return len(ix.terms) }

// AvgDocLen returns the mean document length, or 0 for an empty index.
func (ix *Index) AvgDocLen() float64 {
	if len(ix.docs) == 0 {
		return 0
	}
	return float64(ix.tokens) / float64(len(ix.docs))
}

// Postings returns the posting list of term, and whether the term is indexed.
func (ix *Index) Postings(term string) (Postings, bool) {
	p, ok := ix.terms[term]
	if !ok {
		return Postings{}, false
	}
	return *p, true
}

// Builder accumulates documents and produces an [Index].
type Builder struct {
	analyzer *analysis.Analyzer
	docs     []Doc
}

// NewBuilder returns a Builder that analyses documents with a.
func NewBuilder(a *analysis.Analyzer) *Builder { return &Builder{analyzer: a} }

// Add registers a document. Ids are expected to be unique.
func (b *Builder) Add(id, text string) {
	b.docs = append(b.docs, Doc{ID: id, Text: text})
}

// Build analyses every added document and returns the index. The builder may
// not be reused afterwards.
func (b *Builder) Build() *Index {
	sort.SliceStable(b.docs, func(i, j int) bool { return b.docs[i].ID < b.docs[j].ID })
	ix := &Index{docs: b.docs, terms: make(map[string]*Postings)}
	for di := range ix.docs {
		d := &ix.docs[di]
		toks := b.analyzer.Analyze(d.Text)
		d.Len = len(toks)
		d.spans = make([]int32, 0, 2*len(toks))
		ix.tokens += len(toks)
		for pos, t := range toks {
			d.spans = append(d.spans, int32(t.Start), int32(t.End))
			p := ix.terms[t.Term]
			if p == nil {
				p = new(Postings)
				ix.terms[t.Term] = p
			}
			if n := len(p.Docs); n == 0 || p.Docs[n-1] != int32(di) {
				p.Docs = append(p.Docs, int32(di))
				p.Ends = append(p.Ends, int32(len(p.Pos)))
			}
			p.Pos = append(p.Pos, int32(pos))
			p.Ends[len(p.Ends)-1] = int32(len(p.Pos))
		}
	}
	b.docs = nil
	return ix
}
