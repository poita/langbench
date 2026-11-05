# fulltext

A small, dependency-free full-text search engine in Go: a positional inverted
index over plain-text documents with boolean and phrase queries, BM25 ranking,
Porter stemming and best-window snippets. It comes as a reusable library and
a thin command-line tool that indexes a directory and answers a file of
queries. Only the Go standard library is used; indexing, stemming and ranking
are implemented here.

## Layout

| Package | Responsibility |
|---|---|
| `example.com/fulltext` | `Builder`/`Index`, phrase matching, boolean evaluation, BM25 ranking, snippets, `queries.txt` and corpus-directory handling |
| `example.com/fulltext/analysis` | tokeniser, case/apostrophe folding, stop words, term analysis |
| `example.com/fulltext/porter` | the Porter (1980) stemmer, as in Porter's `porter.c` |
| `example.com/fulltext/query` | query lexer and recursive-descent parser producing a tree |
| `cmd/fulltext` | the command-line tool |

## Build

```
./build.sh            # produces bin/fulltext (runs: go build -o bin/fulltext ./cmd/fulltext)
go test ./...         # unit tests
```

Requires Go 1.27.1 or later.

## Command line

```
./run.sh <input directory> <output directory>
```

The input directory contains `docs/<id>.txt` documents (UTF-8) and
`queries.txt`. The tool writes two files into the output directory:

* `results.txt` — per query, `QUERY <n> <text>`, `HITS <h>`, then one line
  `<rank>\t<id>\t<score>\t<snippet>` per hit (BM25 score with four decimals).
* `stats.txt` — `documents`, `tokens`, `terms` and `avgdl`.

`queries.txt` has one query per line. Blank lines and lines starting with `#`
are ignored; `%k <n>` sets the number of results for the queries after it
(default 10).

### Query language

* a bare word or `"quoted phrase"` — a phrase of stemmed terms that must occur
  adjacently and in order (`well-known` is the phrase `"well known"`);
* `AND`, `OR`, `NOT` (upper case), parentheses; juxtaposition means `AND`;
  `NOT` binds tightest, then `AND`, then `OR`;
* a lone stop word (`the`) matches nothing and is dropped; stop words inside
  phrases count; malformed queries are repaired rather than rejected;
* results are ranked by BM25 (`k1 = 1.2`, `b = 0.75`) summed over the
  non-negated phrases, ties broken by document id.

Text analysis: tokens are runs of ASCII alphanumerics, Latin, Greek and
Cyrillic letters, optionally joined by single apostrophes; case folding only
touches `A`–`Z`; ASCII-only words are Porter-stemmed.

## Library example

```go
package main

import (
	"fmt"

	"example.com/fulltext"
)

func main() {
	b := fulltext.NewBuilder()
	b.Add("note", []byte("The quick brown fox jumps over the lazy dog."))
	b.Add("other", []byte("A slow green turtle."))
	ix := b.Build()

	for _, h := range ix.Search(`fox OR "lazy dog"`, 10) {
		fmt.Printf("%s %.4f %s\n", h.DocID, h.Score, h.Snippet)
	}
	// note 1.1978 The quick brown fox jumps over the lazy dog

	fmt.Print(ix.Stats()) // documents 2, tokens 13, terms ..., avgdl 6.5000
}
```

To load a corpus directory and process a queries file use `fulltext.LoadDir`,
`fulltext.ParseQueryFile` and `(*Index).WriteResults`.

## Design

Documents are tokenised once, at `Build`; token byte spans are kept so
snippets are cut from the original bytes without re-analysis. Terms are
integer ids (raw tokens are memoised so folding and stemming run once per
distinct form). Postings are flat sorted arrays of positions. Per query, each
distinct phrase is resolved once by a positional merge starting from its
rarest term; boolean operators are word-wise bitset operations over document
numbers; snippets use difference arrays so the best 30-token window is found
in O(length + occurrences).
