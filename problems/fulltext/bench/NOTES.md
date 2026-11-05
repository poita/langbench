# fulltext performance benchmark

Regenerate with `python3 problems/fulltext/bench/gen_bench.py`; run with
`python3 run_tests.py fulltext --tests-dir problems/fulltext/bench -- <impl>/run.sh`.
Every input stays within the sizes SPEC.md describes for its tests (about 10MB
of text, at most 25 queries, k at most 25); expected outputs come from the
Python reference (`reference/main.py`), with every ranking checked for
reorder-safe score gaps by `gen_tests.check_gaps`.

- **001_paragraph_corpus_throughput** — 4534 paragraph-sized documents (~1.5KB
  each, 8.6MB) cut from eleven long novels, with 24 ordinary name/phrase/boolean
  queries at k 5-20. Ingest-dominated: measures tokenising, folding, Porter
  stemming and building the positional index over many small files, as a search
  engine indexing a large collection of short records would.
- **002_whole_books_heavy_queries** — 23 whole books as 23 documents (8.5MB,
  up to ~190k tokens per document) with 25 queries that combine many frequent
  terms and stop-word phrases (`"of the" OR "in the" ...`) at k 25. Exercises the
  algorithmically hardest parts: long posting lists, positional phrase matching
  with tens of thousands of occurrences per document, BM25 over many atoms, and
  the best-window snippet search on very long documents with dense occurrence
  sets. Broad queries over a book collection are a realistic workload, and this
  is where implementations differ by more than an order of magnitude.
- **003_chapters_mixed_session** — 572 chapter-sized documents (8.2MB) from 22
  books, with 24 mixed queries (character names, quoted phrases, nested
  AND/OR/NOT groups, `%k` changes from 5 to 25). A balanced interactive-search
  session: indexing medium documents plus selective and broad queries.

## Long tier

`python3 bench/gen_bench.py --long` writes `../bench-long/` (about an hour; expected outputs from the reference, gap-checked as above). SPEC.md's query cap was raised from 25 to 20 000 queries per test. Queries are generated from each corpus (names, content words, phrases cut from the text, and the most frequent bigrams and trigrams), each one gap-checked before it is kept.

- `001_paragraph_corpus_throughput`: every book in `corpus/` cut into paragraph documents (8,248 docs, 15.7 MB) with a 6,000-query session, half ordinary name/phrase/boolean queries and half broad frequent-phrase queries, k 5-20. The corpus cannot grow enough to keep this case ingest-dominated (that would take ~100 MB of text), so at this length query evaluation dominates.
- `002_whole_books_heavy_queries`: the same 23 books with 4,000 broad queries (ORs and ANDs of frequent phrases, long ORs of frequent words, NOT clauses) at k 25.
- `003_chapters_mixed_session`: the same 572 chapters with a 16,000-query session, half selective and half broad, `%k` changing between 5 and 25.

Measured on a heavily loaded machine (best of two, wall): 001 9.0 s (Go; Rust 10.6 s), 002 14.2 s (Go; C++ 17.0 s), 003 7.0 s (Go; Rust 9.0 s, C++ 10.3 s; about 5.9 s user for C++ and Rust, so close to 6 s on a quiet machine). Peak RSS at most 205 MB; reference peak 711 MB. bench-long is about 110 MB (input text 32 MB, expected results 78 MB).

The Python implementation passes all three: 249 s, 889 s (002, about 15 minutes) and 241 s, peak RSS at most 504 MB.
