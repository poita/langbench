# fulltext

A small in-memory full-text search engine in Clojure: a positional inverted
index, a hand-written Porter stemmer, a boolean/phrase query language
(`AND`, `OR`, `NOT`, parentheses, `"quoted phrases"`), BM25 ranking and
best-window snippets. It has no dependencies beyond Clojure itself.

The project has two layers:

- a **library** (`fulltext.core` is the public API), and
- a thin **command-line tool** (`fulltext.main`) that reads a directory of
  `.txt` documents plus a `queries.txt` file and writes `results.txt` and
  `stats.txt`. The exact input/output contract is in the problem's `SPEC.md`.

## Requirements

Java 27 and Clojure 1.12.6 with the `clojure` CLI (tools.deps).

## Build

```sh
./build.sh
```

AOT-compiles the CLI into `classes/` and records the runtime classpath in
`target/classpath.txt`. It can be run from any directory.

## Command line

```sh
./run.sh <input dir> <output dir>
```

The input directory contains `docs/<id>.txt` files (zero or more) and
`queries.txt`. The program writes `results.txt` and `stats.txt` into the
output directory.

`queries.txt` holds one query per line. Blank lines and lines starting with
`#` are ignored; `%k <n>` sets the number of results returned for the queries
that follow (default 10). Example:

```
%k 5
fox
quick brown
"lazy dog" NOT cat
(fox OR wolf) AND jumping
```

`results.txt` has, per query, a `QUERY <n> <text>` line, a `HITS <h>` line
and `h` tab-separated lines `rank, id, BM25 score, snippet`. `stats.txt` holds
`documents`, `tokens`, `terms` and `avgdl`.

Without the scripts: `clojure -M:run <input dir> <output dir>`.

## Library example

```clojure
(require '[fulltext.core :as ft])

(def idx (ft/build-index {"a" "The quick brown fox jumps over the lazy dog."
                          "b" "A fast red fox and a slow brown dog."}))

(ft/search idx "fox AND dog")
;; => [{:rank 1, :id "a", :score 0.3646, :snippet "The quick brown fox jumps over the lazy dog"}
;;     {:rank 2, :id "b", :score 0.3646, :snippet "A fast red fox and a slow brown dog"}]
;; (equal scores are ordered by document id)

(ft/search idx "\"brown fox\" OR lazy" {:k 1})   ; limit results
(ft/parse-query "cat NOT (dog OR bird)")
;; => [:and [[:atom ["cat"]] [:not [:or [[:atom ["dog"]] [:atom ["bird"]]]]]]]
(ft/stats idx)  ;; => {:documents 2 :tokens 18 :terms 13 :avgdl 9.0}
(ft/stem "relational") ;; => "relat"
```

`ft/search` returns maps `{:rank :id :score :snippet}`, best first. Scores are
BM25 (`k1 = 1.2`, `b = 0.75`); ties break on document id.

## Layout

| Namespace | Responsibility |
|-----------|----------------|
| `fulltext.core` | public API facade and the end-to-end `run-directory` |
| `fulltext.analysis` | tokeniser, case folding, stop words, term extraction |
| `fulltext.stemmer` | the Porter stemmer |
| `fulltext.index` | positional inverted index and corpus statistics |
| `fulltext.query` | query lexer, recursive-descent parser, tree utilities |
| `fulltext.matching` | phrase matching by position-list intersection; boolean evaluation |
| `fulltext.scoring` | BM25 |
| `fulltext.snippet` | O(L + occurrences) best-window search and text extraction |
| `fulltext.search` | match → score → rank → snippet for one query |
| `fulltext.corpus` | reading `docs/` and `queries.txt` |
| `fulltext.report` | formatting `results.txt` / `stats.txt` |
| `fulltext.main` | command-line entry point |

## Tests

```sh
clojure -M:test
```

Runs the `clojure.test` suites with the Cognitect test-runner, including
`test.check` properties (phrase matching against a naive scan, the snippet
window search against a brute-force reference) and Porter's 23 531-word
reference vocabulary (`test-resources/porter/`, free for any purpose, from
<https://tartarus.org/martin/PorterStemmer/>).
