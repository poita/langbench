# fulltext: required implementation approach

SPEC.md defines what the program must output. This note defines how it computes
it. Where the two seem to disagree, SPEC.md wins.

Sizes used below: `B` bytes of document text, `T` tokens in the corpus, `N`
documents, `V` distinct terms, `L` tokens in one document, `A` positive atoms
in a query, `k` the result limit.

## Overall approach

A classic in-memory positional inverted index. Read every document whole as
UTF-8 bytes, sort the documents by id and number them `0..N-1` in that order.
Scan each document once with a hand-written tokeniser that records every
token's byte span and maps the raw token to an integer term id through a memo
table, so folding and Porter stemming run once per distinct surface form.
Append each position to its term's postings, which therefore come out sorted by
document and then by position with no sorting step. For each query: lex and
parse into a tree, resolve every atom to a tuple of term ids, compute each
distinct atom's occurrences once (per-document sorted start positions) by
positional merging of postings, evaluate the tree as set algebra over document
bitsets, score the matched documents with BM25 from the occurrence counts,
select the top `k`, and build each emitted snippet from the stored spans and
the cached occurrences with a difference-array sweep. All output goes to one
buffer per file, written once.

## Required choices

1. **Bytes in, byte offsets out.** Keep each document as its original UTF-8
   bytes (or the language's native string when that is UTF-8 or, in an
   interpreted language, its native text type, whose own indices then serve
   as the offsets). Decode code points on the fly inside the tokeniser, with an ASCII fast path for bytes below 0x80. Token
   spans are stored as byte offsets (32-bit integers) in two parallel arrays or
   one array of pairs per document, kept for the whole run. Never build an
   array of code points for a whole document, and never compute code-point
   offsets: a byte-span substring is exactly the code-point-span substring the
   spec describes.
2. **One tokenising pass per document, ever.** The indexing scan is the only
   time a document is tokenised. It yields the span array (whose length is
   `|d|`) and the term-id sequence. Snippets, frequencies and occurrence lists
   are all derived from the index and the stored spans; no later phase
   re-scans, re-tokenises or re-analyses document text, except to copy and
   whitespace-collapse the chosen snippet substring. Ingest is O(B).
3. **Memoised analysis with integer term ids.** Keep one hash map from the raw
   token bytes (before folding) to a term id. On a miss, fold, stem when the
   folded text is all `a`-`z`, then look the term string up in a second map
   from term string to id (assigning the next id when new). Every later
   occurrence of the same raw token costs one hash lookup and no allocation.
   The Porter stemmer works in place on a reusable byte buffer with an end
   index; its steps compare suffixes and move the end, without building
   strings per rule. `terms` in stats.txt is the number of ids assigned
   while indexing. Query phrases are tokenised, folded and stemmed with the
   same functions (the stop-word test uses the folded token text), but their
   terms are only looked up in the term map, never assigned ids; a query term
   absent from the index makes its atom match nothing.
4. **Postings built by appending, indexed by term id.** Postings live in an
   array indexed by term id. Each term's postings hold, per containing
   document in ascending document number, its ascending positions as a
   contiguous run of 32-bit integers. Build them during the single scan by
   appending `(doc, position)`: a term whose last posting belongs to the
   current document just gets the position appended. Either a growable list
   per term or a two-pass count-then-fill flat layout is acceptable. No
   per-document hash maps keyed by term strings, and no sorting of positions.
5. **Documents as dense integers; sets as bitsets.** Ids are sorted once by
   byte comparison, so document number order is id order and the ranking
   tie-break compares numbers. A document set is a bitset of `N` bits (a
   byte-per-document array is an acceptable substitute).
   Evaluate each tree node once: an atom sets the bits of its document list,
   `NOT` complements (masking the tail), `AND`/`OR` combine word by word in
   child order, the empty tree yields the empty set. Cost O(nodes x N/64).
6. **Atom occurrences computed once per query, by positional merge.** Keep a
   per-query map from term-id tuple to the atom's result: its ascending
   document list and, for each of those documents, the ascending start
   positions of its occurrences (frequency is their count). Matching, `df`,
   BM25 frequencies and snippets all read this one result. Discard the map
   when the query is finished; results are not reused across queries.
   - A one-term atom's result is its postings, used directly without copying.
   - A multi-term atom walks the document list of its rarest term, finds the
     same document in each other term's postings (binary search or a forward
     merge cursor), and skips documents missing any term. Within a document it
     intersects shifted position lists: keep starts `p` such that term `i` is
     at `p + i`, by a linear two-pointer merge of sorted lists (or binary
     probes from the shortest list). Cost per candidate document is linear in
     the position lists involved (or `n_min x log n` with probes); never
     quadratic, never via hash sets of positions.
7. **BM25 scoring over matched documents only.** Compute `idf` once per
   positive atom from its `df`. For each matched document, sum the atom
   contributions in positive-atom-list order, finding `f(a, d)` in the atom's
   result by binary search on its document list or by a per-query dense
   array of length `N`. Cost O(matched x A x log df) or O(matched x A).
8. **Top-k by partial selection.** Collect `(score, doc number)` for matched
   documents and take the first `k` under (score descending, doc number
   ascending) with a partial sort, a bounded heap, or a full sort of this
   small array. Snippets are produced only for the `k` emitted documents.
9. **Best window by difference arrays, O(L + occurrences).** For an emitted
   document with `L > 30` and a non-empty occurrence set, let
   `last = L - 30`. Each occurrence at `p` of an atom of `n <= 30` terms is
   inside exactly the windows `s` in `[max(0, p + n - 30), min(p, last)]`
   (atoms of more than 30 terms are skipped: they fit no window). Add `+1/-1` to a "total" difference array of length `last + 2` for every
   such interval. For "distinct atoms", merge each atom's intervals (they
   arrive in ascending order, so merging is a single pass) and add `+1/-1`
   once per merged interval to a second difference array. One prefix-sum
   sweep over `s = 0..last` then picks the maximum of (distinct, total) with
   the first `s` winning ties. Cost O(L + occurrences in the document) per
   emitted document, independent of `A`.
10. **Snippet text from the stored spans.** Slice the original bytes from the
    start of token `s` to the end of token `min(s + 30, L) - 1` and copy them
    into the output, collapsing each run of the seven whitespace code points
    (U+00A0 is the byte pair C2 A0) to one space in a single pass.
11. **Whole-file I/O and buffered output.** Read each document and
    `queries.txt` with one whole-file read. Append every output line to one
    growable buffer per file (or one buffered writer) and write each file
    once. Format scores with the standard fixed four-decimal formatter.

## Left to the implementer

- Hash map implementations and hash functions; whether the two analysis maps
  share storage; how the term-id tuple key of the per-query atom map is built.
- Postings layout (list of per-document records versus flat offset arrays),
  struct layout, and integer widths, as long as positions are compact
  integers in contiguous arrays.
- Whether doc-set and difference-array buffers are reused across nodes,
  queries and snippets; using a bitset or a byte array for document sets.
- Binary search versus merge cursors when locating a document in a postings
  list, and linear merge versus probing in phrase intersection.
- Partial sort, heap or full sort for top-k; how the query tree is
  represented (nodes with child lists, or an index-based arena).
- Module structure, naming, and micro-optimisations such as reserving
  capacity, a lookup table for token characters, or a fast path for
  tokens without upper case or apostrophes in folding.

## Pitfalls

- Re-tokenising and re-stemming a document for every snippet, then finding
  atom occurrences by comparing term strings along the token sequence. On long
  documents with `k = 25` this repeats the whole ingest hundreds of times and
  costs an order of magnitude.
- Choosing the best window by evaluating every start `s` against every atom,
  whether by prefix-count arrays, by sliding pointers, or by binary searching
  each atom's positions at each `s`: O(L x A) to O(L x A x log occ) per
  snippet instead of O(L + occ). Likewise running a separate O(L) fill and
  sweep per atom instead of merging each atom's intervals.
- Converting documents to arrays of code points (32-bit characters), at index
  time or per snippet: four times the memory traffic and an O(B) copy each
  time.
- Allocating a fresh string for every token's folded text, stemming every
  token instead of every distinct form, or a stemmer that builds new strings
  at each step.
- Keying per-document position maps or the global postings by term strings
  and hashing every token's string two or three times; resolve to an integer
  term id once.
- Computing an atom's occurrences several times per query (for matching, for
  frequencies, for snippets), or counting occurrences and discarding the
  positions only to recompute them for the snippet.
- Phrase matching with a hash set of positions per term per document, or by
  nested loops over two position lists.
- Representing document sets as hash sets or sorted lists of document id
  strings, and building `NOT` by enumerating every id string.
- Building output with repeated concatenation of immutable strings (quadratic
  copying), or many small unbuffered writes.
