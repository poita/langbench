# fulltext

A small, dependency-free full-text search engine in Rust. It builds a
positional inverted index over a directory of plain-text documents, evaluates
boolean and phrase queries against it, ranks matches with BM25 and returns a
best-window snippet for each hit.

* Unicode-aware tokenizer (ASCII case folding only; Latin, Greek and Cyrillic letters)
* Porter (1980) stemmer, hand-written, matching Martin Porter's `porter.c`
* Positional index; phrase matching by merge-intersection of position lists
* Query language: phrases (`"quick brown"`), `AND`, `OR`, `NOT`, parentheses,
  juxtaposition as `AND`, and forgiving error recovery
* BM25 (`k1 = 1.2`, `b = 0.75`) ranking with id tie-breaking
* Snippets chosen in O(length + occurrences) with difference arrays

## Build

```sh
cargo build --release      # or ./build.sh
cargo test                 # unit, integration and doc tests
```

Requires Rust 1.96 or later; there are no dependencies.

## Command-line usage

```sh
fulltext <input dir> <output dir>      # or ./run.sh <input dir> <output dir>
```

The input directory contains `docs/<id>.txt` files (zero or more) and
`queries.txt`. In `queries.txt`, each line is a query, a `# comment`, a blank
line, or a `%k <n>` directive that sets the result limit (default 10) for the
queries that follow. The program writes two files into the output directory:

* `results.txt` — per query: `QUERY <n> <text>`, `HITS <h>`, then one
  `rank<TAB>id<TAB>score<TAB>snippet` line per hit;
* `stats.txt` — `documents`, `tokens`, `terms` and `avgdl`.

## Library usage

```rust
use fulltext::{Index, Searcher};

fn main() {
    let index = Index::build(vec![
        ("fox", "The quick brown fox jumps over the lazy dog."),
        ("reply", "A quick reply."),
    ]);
    let searcher = Searcher::new(&index);

    for hit in searcher.search("quick AND NOT \"brown fox\"", 10) {
        println!("{}\t{:.4}\t{}", hit.id, hit.score, hit.snippet);
    }
}
```

`Index::from_directory` loads a corpus from disk, and
`fulltext::report::{run_queries, stats}` produce the exact file contents the CLI
writes.

## Layout

| Module | Responsibility |
|--------|----------------|
| `analysis` | tokenising, folding, stop words, term production |
| `stemmer` | Porter stemmer |
| `index` | documents and positional inverted index |
| `query` | query lexer and recursive-descent parser |
| `search` | phrase matching, boolean evaluation, BM25, ranking |
| `snippet` | best-window selection and rendering |
| `report` | `queries.txt` handling, `results.txt` / `stats.txt` formatting |

`tests/porter.rs` checks the stemmer against Porter's vocabulary when the
`problems/fulltext/corpus/porter` files are present next to the project, and
skips itself otherwise.
