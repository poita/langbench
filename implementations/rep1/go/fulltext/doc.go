// Package fulltext is an in-memory full-text search engine: a positional
// inverted index over plain-text documents with boolean and phrase queries,
// BM25 ranking and best-window snippets.
//
// Typical use:
//
//	b := fulltext.NewBuilder()
//	b.Add("note", []byte("The quick brown fox jumps over the lazy dog."))
//	ix := b.Build()
//	for _, h := range ix.Search(`fox OR "lazy dog"`, 10) {
//		fmt.Println(h.DocID, h.Score, h.Snippet)
//	}
//
// Text is analysed (see package analysis) by splitting into tokens, folding
// ASCII case and apostrophes, and Porter-stemming ASCII words (package
// porter). Queries (package query) support AND, OR, NOT, parentheses and
// "quoted phrases"; juxtaposition means AND.
//
// The package also implements the batch file formats used by the command-line
// tool: LoadDir reads a corpus directory, ParseQueryFile and WriteResults
// process a queries.txt file and format the ranked answer.
package fulltext
