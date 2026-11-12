# fulltext

A small, dependency-free full-text search engine in C++20: a positional inverted
index with Porter stemming, a boolean/phrase query language, BM25 ranking and
best-window snippets. It ships as a reusable library (`fulltext::fulltext`) and
a thin command-line tool that indexes a directory of `.txt` files and answers a
file of queries.

Everything (tokeniser, stemmer, index, parser, ranking) is implemented from
scratch on top of the C++ standard library; GoogleTest is used for tests only.

## Build

Requires a C++20 compiler and CMake ≥ 3.20 (tests additionally need GoogleTest).

```sh
./build.sh            # Release build into ./build
# or, by hand:
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j
ctest --test-dir build   # run the unit tests
```

`-DFULLTEXT_BUILD_TESTS=OFF` skips the tests (and the GoogleTest requirement).

## Command-line use

```
fulltext <input directory> <output directory>      # or: ./run.sh <in> <out>
```

Input layout:

```
<input>/docs/<id>.txt    the documents (UTF-8); id = file name minus ".txt"
<input>/queries.txt      one query per line; `# comment`, blank lines, `%k <n>`
```

Output (written into `<output>`): `results.txt` — per query, `QUERY n text`,
`HITS h`, then `rank<TAB>id<TAB>score<TAB>snippet` lines — and `stats.txt`
(`documents`, `tokens`, `terms`, `avgdl`). The full contract is in the
problem's `SPEC.md`.

Query language: bare words and `"quoted phrases"`; `AND` (also implied by
juxtaposition), `OR`, `NOT` (upper case), parentheses. `NOT` binds tightest,
then `AND`, then `OR`. Malformed queries are recovered from, never rejected.

## Library layout

| Header | Responsibility |
|--------|----------------|
| `fulltext/utf8.hpp`     | UTF-8 decoding, the spec's whitespace set, stripping |
| `fulltext/stemmer.hpp`  | Porter stemmer (`porter_stem`) |
| `fulltext/analyzer.hpp` | tokenise → fold → stem, stop words |
| `fulltext/index.hpp`    | `Index`, `PostingList`, corpus statistics |
| `fulltext/query.hpp`    | query lexer/parser, `Query` tree, positive atoms |
| `fulltext/matcher.hpp`  | positional phrase matching, boolean evaluation |
| `fulltext/bm25.hpp`     | BM25 idf and term score |
| `fulltext/snippet.hpp`  | best-window search (difference arrays) and rendering |
| `fulltext/searcher.hpp` | `Searcher`: parse → match → score → rank → snippets |
| `fulltext/corpus.hpp`   | loading `<input>/docs` |
| `fulltext/batch.hpp`    | `queries.txt` parsing, `results.txt`/`stats.txt` output |

Design notes: documents are numbered in id order, so ranking ties break on the
internal number. Phrases are matched by merging position lists shifted by term
offset (linear in the lists involved); each distinct atom is matched once per
query and that result serves matching, `df`, `tf` and snippets. Only matched
documents are scored and only emitted ones get snippets.

## Library example

```cpp
#include <iostream>
#include "fulltext/index.hpp"
#include "fulltext/searcher.hpp"

int main() {
  using namespace fulltext;
  Index index = Index::build({
      {"fox",  "The quick brown fox jumps over the lazy dog."},
      {"cats", "Cats are running around the house."},
  });

  Searcher searcher(index);
  SearchResult r = searcher.search("\"lazy dog\" OR cat NOT house", /*k=*/5);

  for (const Hit& h : r.hits)
    std::cout << h.id << '\t' << h.score << '\t' << h.snippet << '\n';
}
```

Link with `target_link_libraries(your_target PRIVATE fulltext::fulltext)` after
`add_subdirectory(fulltext)`.

## Tests

`ctest --test-dir build` runs GoogleTest suites for each module (UTF-8,
stemmer, analyser, index, parser, matcher, snippets, searcher, batch I/O).
The stemmer suite also checks Porter's reference vocabulary when
`FULLTEXT_PORTER_DIR` (default `../problems/fulltext/corpus/porter`) exists, and
skips that test otherwise.
