# fulltext: required approach

SPEC.md defines what the program must output; this note defines how it computes
it. Where the two seem to disagree, SPEC.md wins.

Sizes: `B` bytes of document text, `N` documents, `L` tokens in one document,
`A` positive atoms in a query, `k` the result limit.

## Algorithm

A positional inverted index. Each document is analysed once (tokenise, fold,
Porter-stem) and its term positions are added to a map from term to postings:
for each containing document, the sorted positions of the term. Each query is
parsed by recursive descent into a tree; each distinct atom is matched against
the index, giving its documents and, per document, its occurrence start
positions. The tree is evaluated as set algebra over document sets, the matched
documents are scored with BM25, the top `k` are ranked, and a snippet is built
for each emitted document.

## Required rules

1. **Phrases match by positional intersection** of the terms' position lists,
   shifted by their offsets, in documents containing all the terms: linear in
   the position lists involved (or with O(1) or O(log n) lookups). No nested
   scans of one position list per element of another.
2. **Each distinct atom is matched once per query**, and that result serves
   matching, `df` and the BM25 frequencies.
3. **Only matched documents are scored**, and snippets are built only for the
   emitted documents, from the occurrence positions in the postings.
4. **The best snippet window is found in O(L + occurrences)**, for example with
   difference arrays over window starts and one prefix-sum sweep. No evaluation
   of every window against every atom.

## Complexity

Indexing is O(B). For a query, phrase matching is linear in the postings of its
atoms' terms; set evaluation is O(N) per tree node; scoring is O(matched × A);
ranking is O(matched log matched) at most; and each snippet is O(L +
occurrences in the document).
