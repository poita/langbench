# fulltext

A small positional full-text search engine written in D, with no dependencies
beyond Phobos. It indexes plain-text documents, evaluates boolean and phrase
queries, and returns BM25-ranked hits with snippets. It is a reusable library
(`fulltext`) plus a thin command-line tool.

* Tokeniser with ASCII case folding and apostrophe handling (Latin, Greek and
  Cyrillic letters, digits)
* The original Porter stemmer (Martin Porter's `porter.c` behaviour)
* Positional inverted index; phrase matching by positional intersection
* Query language: `AND`, `OR`, `NOT`, parentheses, `"phrases"`; juxtaposition
  means `AND`; malformed queries are recovered from, never rejected
* BM25 (`k1 = 1.2`, `b = 0.75`) ranking, ties broken by document id
* Best 30-token-window snippets, found in O(length + occurrences)

## Build

Requires LDC and dub.

```sh
./build.sh          # dub build -b release --compiler=ldc2
```

This produces the `fulltext` executable in this directory.

## Command-line use

```sh
./run.sh <input directory> <output directory>
```

The input directory holds `docs/<id>.txt` (zero or more documents) and
`queries.txt`. `queries.txt` has one query per line; blank lines and lines
starting with `#` are ignored; `%k N` sets the number of hits (default 10) for
the queries after it.

```
# queries.txt
fox
quick brown
%k 3
"lazy dog" OR (cat NOT dog)
```

The tool writes two files into the output directory:

* `results.txt` — per query `QUERY <n> <text>`, `HITS <h>`, then
  `rank<TAB>id<TAB>score<TAB>snippet` lines;
* `stats.txt` — `documents`, `tokens`, `terms` and `avgdl`.

## Library use

```d
import std.stdio;
import fulltext;

void main()
{
    auto index = Index.build([
        Document("fox", "The quick brown fox jumps over the lazy dog."),
        Document("cat", "A cat sat on the mat."),
    ]);
    auto searcher = new Searcher(index);

    foreach (hit; searcher.search(`quick OR "lazy dog"`, 10))
        writefln("%s\t%.4f\t%s", hit.id, hit.score, hit.snippet);
}
```

Use it from another dub project with `dependency "fulltext" path="../fulltext"`
(the `library` configuration is selected automatically).

Layout of the library (`source/fulltext/`):

| Module | Responsibility |
|--------|----------------|
| `analysis` | tokeniser (an input range), folding, stop words |
| `stemmer` | Porter stemmer |
| `index` | positional inverted index, `Occurrences` postings view |
| `query` | lexer, recursive-descent parser, query tree, positive atoms |
| `search` | phrase matching, boolean evaluation, BM25, ranking (`Searcher`) |
| `snippet` | best-window search and snippet extraction |
| `queryfile`, `corpus`, `report` | `queries.txt` parsing, loading `docs/`, output rendering |

Offsets in `Token` are UTF-8 byte offsets into the analysed string.

## Tests

Tests are D `unittest` blocks next to the code (the stemmer is also checked
against a sample of Porter's reference vocabulary in `tests/data/`):

```sh
dub test --compiler=ldc2
```
