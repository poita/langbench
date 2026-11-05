# toml — implementation approach

SPEC.md defines what the output must be. This note fixes how the program
computes it. Below, N is the document size in bytes (at most 8 MB), K the
number of keys in one table, P the number of segments in one key or header
path, and M the size of the output.

## Overall approach

Read all of stdin into one byte buffer and split off the mode line. **Decode**
is a single-pass, hand-written recursive-descent parser that walks the
document bytes once with an integer cursor and builds one tree of table,
array and scalar nodes; each table node carries its own provenance flags
(SPEC.md §1.3), so table resolution is a short walk over hash-map lookups.
The tree is then serialised once, recursively, into one growable output
buffer as compact key-sorted tagged JSON, and written with a single write.
**Encode** parses the tagged JSON once into the same kind of tree (value
nodes keep their `value` text verbatim) and renders canonical TOML into one
growable buffer the same way. Everything is O(N + M) apart from sorting each
table's keys once at output (O(K log K) per table).

## Required choices

1. **Input and output.** Read stdin in bulk (one read-all call or large
   chunks) into one byte buffer; work on the document as a view into it,
   without copying it again. Build the entire output in one growable buffer
   (or a buffered writer with a large buffer) and write it at the end. This
   keeps I/O at O(N + M) with a handful of system calls.
2. **Validation of the byte stream.** Check UTF-8 validity, a leading BOM
   and lone CRs in one linear pass over the bytes (a separate up-front pass
   or folded into the scanners; the standard library's strict UTF-8
   validator/decoder is fine). After that the parser works on bytes (or on
   the decoded text, in a language whose native string is a code-point
   sequence): every grammar rule is ASCII-driven and everything ≥ 0x80 is
   copied through. O(N).
3. **Scanner.** One integer cursor into the buffer; each scanner (whitespace
   and comment, key, the four string forms, scalar token, array, inline
   table) examines bytes in place from the cursor and advances it. Value
   dispatch is on the first byte (`"`, `'`, `[`, `{`, otherwise a bare
   scalar token). Character classes (bare-key bytes, forbidden control bytes,
   digits) are direct byte comparisons or a 256-entry table; digits are ASCII
   only. Nothing is ever rescanned from the start of the document or from
   the start of the line. A bounded search for the next delimiter within the
   current token is an equivalent way to scan a run.
4. **Strings and keys.** A string scanner finds the run of plain bytes up to
   the next quote, backslash, newline or forbidden byte and copies that run
   in one bulk append; when the string has no escapes (and for literal
   strings, always) the value is taken directly as a slice/substring of the
   input. Escapes are decoded into a scratch buffer that is created only when
   the first escape is seen. Multi-line strings handle CRLF→LF, quote runs
   and line-ending backslashes in the same single pass. Bare keys are a slice
   of the input. Each string costs O(its length).
5. **Scalar tokens.** A bare scalar is scanned once to its delimiter (with the
   date-space-time lookahead of §1.3) and classified by its shape: `true` /
   `false`; date-like (`DDDD-`) or time-like (`DD:`); otherwise number.
   Integers are accumulated digit by digit into a 64-bit value with an
   overflow check (any base), tracking the magnitude so that
   −9223372036854775808 is accepted; the check is on the value, never on
   the digit count (leading zeros are legal in the prefixed bases). Floats are validated by the grammar scanner,
   their underscores removed, and converted with the platform's correctly
   rounded decimal→binary conversion (strtod or the language's equivalent);
   the 17-digit text uses the standard `%.16e`-style formatter of SPEC.md
   §1.2. Date-times are validated by indexing the fixed-width fields
   directly and canonicalised textually (separator, fraction trimming,
   offset); no date library and no calendar arithmetic. O(token length).
6. **Tree representation.** A table node holds a hash map from decoded key
   (a byte string) to child node, plus its flags: explicit, implicit,
   dotted, inline/sealed. An array node holds a growable list of children
   plus a flag saying whether it was created by `[[…]]`. A scalar node holds
   its type and either its canonical text or its typed value (string bytes,
   int64, double, bool, date-time text). There is one tree; the parse tree
   is the output tree, never converted into a second representation.
7. **Table resolution.** The parser keeps a pointer to the current table. A
   `[header]` or `[[header]]` resolves its path from the root, one map lookup
   per segment (entering the last element of an array of tables), applying
   rules 2–6 of §1.3 using the flags on the nodes it meets. A key/value pair
   resolves its dotted segments from the current table, again one lookup per
   segment, and inserts the value with a single lookup-or-insert that also
   detects duplicates. Cost O(P) expected per statement. Sealing an inline
   table when it closes marks it and its dotted sub-tables created inside
   it; already-sealed nested inline tables are not walked again.
8. **Tagged JSON writer (decode output).** A recursive walk of the tree
   appending to the single output buffer. Each table's keys are collected
   once and sorted once by plain byte-wise comparison of their UTF-8 bytes
   (which equals code-point order), or by the native comparison where
   strings are code-point sequences. JSON string escaping copies unescaped
   runs in bulk and handles only `"`, `\` and bytes below 0x20 specially;
   bytes ≥ 0x80 are copied through. Type names and punctuation are appended
   as constant strings. O(M + Σ K log K).
9. **Encode input.** The tagged JSON is parsed once, left to right, in a
   single pass that builds the tree of item 6 directly (a reader in the
   scanner style of item 3, or a JSON decoder that builds these nodes as it
   parses): JSON strings without escapes can be taken as slices of the
   input, and an object that closes with exactly the `type` and `value`
   string members becomes a compact value node (type tag + text) rather than
   a two-entry map. There is exactly one
   tree, and the `value` texts are kept as strings and emitted verbatim —
   integers, floats and booleans are never converted to numbers and
   formatted back.
10. **Canonical TOML writer (encode output).** One recursive pass per table:
    sort its keys once, emit the pairs (third kind of §2.2) inline, then the
    sub-tables and arrays of tables with their headers. The dotted path of a
    table is built once when descending (parent path + `.` + rendered key)
    and passed down. "Has anything been written yet" is the output buffer's
    length. Classification (sub-table / array of tables / inline) is a check
    of the node kind and, for arrays, one scan of the elements, done once per
    member and reused by both passes over the sorted keys. Bare-key
    detection and basic-string quoting scan the key or string once and copy
    unescaped runs in bulk. O(M + Σ K log K).

Overall: O(N + M + Σ K log K) time and O(N) memory, with a small constant
number of allocations per node. Runtime memory-management (GC) settings stay
at their defaults.

## Left to the implementer

- Exact container types (any hash map, or an ordered tree map if that is the
  idiomatic keyed container; then the output walk needs no extra sort),
  node layout (tagged union, class hierarchy, variant, index arena), field
  names and module structure.
- Whether scalars store canonical text at parse time or typed values
  formatted at output time.
- Whether UTF-8/CR/BOM validation is a separate pre-pass or folded into the
  scanners; whether `error` is signalled with exceptions, panics, result
  values or error flags.
- Recursion versus explicit stacks for arrays and inline tables (nesting is
  at most a few hundred levels; raise recursion limits where the language
  needs it).
- Micro-optimisations: lookup tables, pre-sizing buffers and maps, interning
  type-name strings, fast integer-to-decimal formatting.

## Pitfalls

- Reading stdin one character at a time through a character-stream
  iterator or unbuffered `getc`-style calls: locking and per-character
  overhead dominates the whole run (several times the cost of parsing).
- Searching for a delimiter with an unbounded "find from here" over the
  rest of the document (for example looking for the next backslash or
  quote beyond the end of the current string or line): when the delimiter
  is absent, every string scans to the end of the buffer and decode becomes
  quadratic in N.
- In encode mode, parsing the JSON into a generic tree and then converting
  it into a second typed tree, and especially re-parsing integer and float
  texts into numbers only to format them back; the texts are emitted
  verbatim.
- In encode mode, keeping every value node as a general-purpose hash map
  with `type`/`value` entries that is looked up by name again at output.
- Building a parse tree and then copying it into a separate "public" value
  tree before output.
- Tracking table flags in a separate structure keyed by absolute key paths
  that is re-walked from the root for every key/value pair, instead of
  storing the flags on the table nodes and resolving pairs from the current
  table.
- Creating a fresh growable buffer for every string or key even when it has
  no escapes, or appending byte by byte where a run can be copied in bulk.
- Building output by repeated concatenation of immutable strings, building
  per-node strings that are joined up the recursion, or issuing one write
  per node.
- Sorting keys with a comparator that decodes code points, compares
  UTF-16 units or uses locale collation; or re-sorting a table's keys more
  than once per output.
- Using regular expressions with backtracking alternatives, or trying several
  scalar grammars in turn on substrings, where one shape-based dispatch on
  the token suffices; using `\d`-style or Unicode-aware digit predicates
  (also a correctness bug).
