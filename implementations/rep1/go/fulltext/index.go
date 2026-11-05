package fulltext

import (
	"slices"
	"strconv"
	"strings"

	"example.com/fulltext/analysis"
)

// postings holds one term's occurrences in flat arrays: documents ascending,
// and for docs[i] the ascending token positions pos[starts[i]:starts[i+1]].
// starts has len(docs)+1 entries once the index is built.
type postings struct {
	docs   []int32
	starts []int32
	pos    []int32
}

// Builder collects documents and builds an Index.
type Builder struct {
	ids   []string
	texts [][]byte
}

// NewBuilder returns an empty Builder.
func NewBuilder() *Builder { return &Builder{} }

// Add registers a document. Ids should be unique; documents are numbered in
// ascending byte order of id. The Builder and the resulting Index keep a
// reference to text (it is not copied), so the caller must not modify it.
func (b *Builder) Add(id string, text []byte) {
	b.ids = append(b.ids, id)
	b.texts = append(b.texts, text)
}

// Index is an immutable positional inverted index. It is safe for concurrent
// use by multiple goroutines.
type Index struct {
	ids    []string  // document ids, ascending
	texts  [][]byte  // original document bytes
	spans  [][]int32 // per document: start,end byte offsets of each token, interleaved
	total  int64     // total tokens
	terms  map[string]int32
	posts  []postings // indexed by term id
	avgdl  float64
	nTerms int
}

// Build tokenises every added document once and returns the index.
func (b *Builder) Build() *Index {
	n := len(b.ids)
	order := make([]int, n)
	for i := range order {
		order[i] = i
	}
	slices.SortStableFunc(order, func(x, y int) int { return strings.Compare(b.ids[x], b.ids[y]) })

	ix := &Index{
		ids:   make([]string, n),
		texts: make([][]byte, n),
		spans: make([][]int32, n),
		terms: make(map[string]int32),
	}
	raw := make(map[string]int32) // raw token bytes -> term id (memo)
	var buf []byte
	for doc, src := range order {
		text := b.texts[src]
		ix.ids[doc] = b.ids[src]
		ix.texts[doc] = text
		spans := make([]int32, 0, len(text)/3)
		var tok int32
		for pos := 0; ; tok++ {
			s, e, ok := analysis.Next(text, pos)
			if !ok {
				break
			}
			pos = e
			id, seen := raw[string(text[s:e])]
			if !seen {
				buf = analysis.StemFolded(analysis.Fold(buf[:0], text[s:e]))
				id, seen = ix.terms[string(buf)]
				if !seen {
					id = int32(len(ix.posts))
					ix.terms[string(buf)] = id
					ix.posts = append(ix.posts, postings{})
				}
				raw[string(text[s:e])] = id
			}
			p := &ix.posts[id]
			if k := len(p.docs); k == 0 || p.docs[k-1] != int32(doc) {
				p.docs = append(p.docs, int32(doc))
				p.starts = append(p.starts, int32(len(p.pos)))
			}
			p.pos = append(p.pos, tok)
			spans = append(spans, int32(s), int32(e))
		}
		ix.spans[doc] = spans
		ix.total += int64(tok)
	}
	for i := range ix.posts {
		p := &ix.posts[i]
		p.starts = append(p.starts, int32(len(p.pos)))
	}
	ix.nTerms = len(ix.posts)
	if n > 0 {
		ix.avgdl = float64(ix.total) / float64(n)
	}
	return ix
}

// NumDocs returns the number of documents.
func (ix *Index) NumDocs() int { return len(ix.ids) }

// DocID returns the id of document number i (0 <= i < NumDocs); numbering
// follows ascending id order.
func (ix *Index) DocID(i int) string { return ix.ids[i] }

// DocLen returns the number of tokens in document number i.
func (ix *Index) DocLen(i int) int { return len(ix.spans[i]) / 2 }

// Stats summarises an index.
type Stats struct {
	Documents int     // number of documents
	Tokens    int64   // total tokens, stop words included
	Terms     int     // distinct terms
	AvgDocLen float64 // mean document length; 0 when there are no documents
}

// Stats returns the index's corpus statistics.
func (ix *Index) Stats() Stats {
	return Stats{Documents: len(ix.ids), Tokens: ix.total, Terms: ix.nTerms, AvgDocLen: ix.avgdl}
}

// String formats the statistics as the four lines of stats.txt.
func (s Stats) String() string {
	return "documents " + strconv.Itoa(s.Documents) + "\n" +
		"tokens " + strconv.FormatInt(s.Tokens, 10) + "\n" +
		"terms " + strconv.Itoa(s.Terms) + "\n" +
		"avgdl " + strconv.FormatFloat(s.AvgDocLen, 'f', 4, 64) + "\n"
}
