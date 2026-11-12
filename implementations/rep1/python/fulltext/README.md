# fulltext

A small, dependency-free full-text search engine in pure Python. It indexes a
directory of plain-text documents, evaluates boolean and phrase queries, and
ranks the matches with BM25, producing a snippet for each result.

* Unicode-aware tokeniser with ASCII-only case folding and apostrophe removal
* The original Porter stemmer (as in Porter's `porter.c`), written from scratch
* Positional inverted index; phrase matching by linear position-list merging
* Query language with `AND`, `OR`, `NOT`, parentheses and `"quoted phrases"`
  (a forgiving parser that never fails)
* BM25 ranking (k1 = 1.2, b = 0.75) with deterministic tie-breaking
* Best-window snippets found in O(length + occurrences)

Requires Python 3.14 and nothing else (pytest only for the tests).

## Build

```sh
./build.sh      # byte-compiles the package; there is nothing else to build
```

No installation is needed: `run.sh` sets `PYTHONPATH` to `src/`. (`pip install .`
also works and provides a `fulltext` console script.)

## Command line

```sh
./run.sh <input dir> <output dir>
# or: PYTHONPATH=src python3 -m fulltext <input dir> <output dir>
```

The input directory holds `docs/<id>.txt` files (zero or more) and a
`queries.txt`. In `queries.txt`, each non-blank line is a query, except `#`
comment lines and `%k N` lines, which set the result limit (default 10) for the
queries that follow. The program writes two files into the output directory:

* `results.txt` — per query: `QUERY <n> <text>`, `HITS <h>`, then one line per
  hit: `rank<TAB>doc id<TAB>score<TAB>snippet`
* `stats.txt` — `documents`, `tokens`, `terms` and `avgdl`

The full format is specified in `problems/fulltext/SPEC.md`.

## Query language

| Syntax | Meaning |
|--------|---------|
| `cat dog`, `cat AND dog` | both words |
| `cat OR dog` | either |
| `NOT cat` | documents without `cat` |
| `(a OR b) c` | grouping; juxtaposition is `AND` |
| `"to be or not"` | phrase: terms adjacent, in order |

`NOT` binds tightest, then `AND`, then `OR`. A single stop word is ignored; a
query that reduces to nothing matches no documents.

## Library

```python
from fulltext import Index, Searcher

index = Index({
    "note": "The quick brown fox jumps over the lazy dog.",
    "pets": "A cat and a dog.",
})
searcher = Searcher(index)

for hit in searcher.search('dog AND NOT "lazy dog"', k=5):
    print(hit.rank, hit.doc_id, f"{hit.score:.4f}", hit.snippet)
# 1 pets 0.2065 A cat and a dog
```

Modules, by responsibility:

| Module | Role |
|--------|------|
| `fulltext.analysis` | tokenising, folding, stop words, term construction |
| `fulltext.stemmer` | `stem(word)` — the Porter stemmer |
| `fulltext.index` | `Index` — postings, document lengths, corpus statistics |
| `fulltext.query` | lexer, parser, query tree (`Atom`, `And`, `Or`, `Not`) |
| `fulltext.matching` | `Matcher` — phrase matching and boolean evaluation |
| `fulltext.scoring` | BM25 |
| `fulltext.snippets` | best-window selection |
| `fulltext.search` | `Searcher.search(query, k)` → `list[Hit]` |
| `fulltext.corpus`, `fulltext.output`, `fulltext.cli` | file I/O, formatting, CLI |

## Tests

```sh
python3 -m pytest        # from this directory
```
