# fulltext

A small full-text search engine in Go, standard library only. It builds a
positional inverted index over plain-text documents, evaluates boolean and
phrase queries, ranks matches with BM25 and returns a best-window snippet for
each hit. The indexing, Porter stemming and ranking are all implemented here.

It ships as a library (import path `fulltext`) and a thin command-line tool
that runs a batch of queries over a directory of documents.

## Build

Requires Go 1.27.1.

```sh
./build.sh          # builds bin/fulltext with plain `go build`
go test ./...       # runs the unit tests
```

## Command-line use

```sh
./run.sh <input directory> <output directory>
```

The input directory holds `docs/<id>.txt` (zero or more documents; the id is
the file name without `.txt`) and `queries.txt`. The tool writes `results.txt`
and `stats.txt` into the output directory (created if missing) and exits 0.

`queries.txt` has one query per line. Blank lines and lines starting with `#`
are ignored, and `%k <n>` sets the result limit (default 10) for the queries
after it.

`results.txt` has a block per query:

```
QUERY <number> <query text>
HITS <h>
<rank>\t<document id>\t<score, 4 decimals>\t<snippet>
```

`stats.txt` has four lines: `documents`, `tokens`, `terms` and `avgdl`.

Example, with `docs/note.txt` = `The quick brown fox jumps over the lazy dog.` and
`queries.txt` = `fox`:

```
QUERY 1 fox
HITS 1
1	note	0.2877	The quick brown fox jumps over the lazy dog
```

### Query language

- A word or a `"quoted phrase"` is an atom; a phrase matches its terms
  adjacently, stop words included. A single stop word is ignored.
- `AND`, `OR`, `NOT` (upper case) and parentheses combine atoms. `NOT` binds
  tightest, then `AND`, then `OR`; juxtaposition means `AND`.
- Parsing never fails: malformed queries are recovered from by dropping what
  cannot be used, and a query with nothing left matches no document.

## Library use

```go
package main

import (
	"fmt"

	"fulltext"
)

func main() {
	eng := fulltext.New([]fulltext.Document{
		{ID: "note", Text: "The quick brown fox jumps over the lazy dog."},
		{ID: "pets", Text: "Dogs and cats."},
	})
	for _, hit := range eng.Search(`dog OR "lazy dog"`, 10) {
		fmt.Printf("%s %.4f %s\n", hit.DocID, hit.Score, hit.Snippet)
	}
	fmt.Println(eng.Stats().Terms, "terms")
}
```

## Layout

| Package | Responsibility |
|---------|----------------|
| `fulltext` | `Engine`: index documents, `Search`, `Stats` |
| `fulltext/porter` | the Porter stemmer (`porter.c` semantics) |
| `fulltext/analysis` | tokeniser, ASCII case folding, apostrophes, stop words, terms |
| `fulltext/index` | positional inverted index (`Builder`, `Index`, `Postings`) |
| `fulltext/query` | query lexer and recursive-descent parser, `Node` tree |
| `fulltext/search` | phrase matching, set algebra, BM25, ranking, snippets |
| `fulltext/batch` | `queries.txt` parsing, document loading, output files |
| `cmd/fulltext` | the command-line entry point |

### How it works

- Phrases are matched by intersecting the document lists of their terms and
  then merging the position lists shifted by term offset: linear in the lists
  involved. Each distinct atom is matched once per query, and that result serves
  boolean matching, document frequency and BM25 frequencies.
- Boolean evaluation is set algebra over bitsets of document indexes; only the
  matched documents are scored.
- The best snippet window (30 tokens: most distinct atoms, then most
  occurrences, then earliest) is found in O(length + occurrences) with
  difference arrays over window starts, and only for the emitted hits.
