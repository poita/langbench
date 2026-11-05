# json — required implementation approach

SPEC.md defines what the program outputs. This note defines how it computes it.
If this note and SPEC.md ever disagree, SPEC.md wins.

## Overall approach

Read all of stdin into one byte buffer. Validate the whole buffer as strict
UTF-8 in one linear pass (rejecting a leading BOM). Parse it with a
single-pass recursive-descent parser that works on bytes and builds an
in-memory value tree. Strings are stored decoded, numbers are stored as their
canonical text, and object members are stored in input order. Stop at the
first error. Then serialise the tree once, in pre-order, into one growable
output buffer. Each object's members are deduplicated and sorted at the point
where the object is written. Finally write the buffer (or `invalid`) with one
write call.

## Required choices

1. **Input and validation.** Read stdin completely into one buffer, then
   check it as RFC 3629 UTF-8 in a single O(n) pass before parsing, or fused
   into the parse as long as every byte is still checked exactly once. A
   standard-library validator may be used only if it is exactly as strict as
   the spec (no overlong forms, no surrogates, nothing above U+10FFFF). After
   this pass, never validate or decode the same bytes as UTF-8 again. Strings
   are kept as bytes known to be valid.
2. **Parser.** Use one forward pass of recursive descent over bytes, with a
   single cursor, dispatching on the first byte of each value. Keep a depth
   counter and check it when a `[` or `{` is opened (depth > 512 → invalid).
   That check bounds recursion, so unclosed `[` runs fail quickly. There is
   no tokenizer pass, no backtracking and no regex over the whole input. The
   whole parse is O(n) in the input size n.
3. **Errors.** Stop at the first violation and report `invalid` by unwinding:
   an error return, a single exception type, or a sticky flag checked after
   every call. Nothing written before the error is printed.
4. **Strings.** Scan each string in runs. Advance over bytes that are not
   `"`, `\` or < 0x20, and copy each run in bulk, not byte by byte. A string
   with no escapes is stored as a reference to (or one bulk copy of) its
   bytes in the input. Escapes are decoded into a per-string byte buffer.
   `\uXXXX` becomes UTF-8, and surrogate pairs are joined. The stored form is
   decoded UTF-8 bytes, the same representation for keys and values.
5. **Numbers.** Validate the lexeme with the grammar and keep it as text. If
   it has no exponent, the canonical form is the input slice itself, with no
   copy needed. If it has an exponent, build the mantissa slice plus the
   normalised exponent (or record the offsets and emit them at write time).
   Never convert to floating point or a big integer. Cost is O(lexeme
   length).
6. **Tree.** Arrays hold their elements in order. Objects hold all members
   in input order, duplicates included, as (key, value) pairs. Children are
   collected into a growable sequence with amortised O(1) append (or a
   shared scratch stack that is copied out once when the container closes).
   Total tree size is O(n).
7. **Key order.** Compare keys directly on their UTF-8 bytes. Find the first
   differing byte with a plain byte-wise (memcmp-style) loop. If there is
   none, the shorter key sorts first. Otherwise step back to the start of the
   character that contains that byte (the same offset in both keys), decode
   the two code points, and compare them with U+E000–U+FFFF ranked above all
   supplementary characters (for example, add 0x110000 to code points in
   E000–FFFF). Do not convert keys to UTF-16 arrays or allocate anything per
   comparison.
8. **Dedup and sort.** At serialisation time, for an object with m members,
   sort an array of small handles (member index, or key reference plus
   index), not the member records themselves. Use a stable sort by key, or
   any sort with the input index as tie-breaker. Then walk each run of equal
   keys and emit only its last member (the last occurrence in the input).
   Run boundaries are found by plain byte equality of adjacent keys. This
   costs O(m log m) key comparisons and uses no hash table. Objects with 0 or
   1 members skip the sort.
9. **Serialisation.** Walk the tree once and append everything to a single
   output buffer, pre-sized to about the input length. Write string escapes
   in runs: copy the bytes that need no escaping in bulk, and emit an escape
   only for `"`, `\` and bytes < 0x20 (lowercase hex for `\u00XX`). The whole
   output costs O(output size) plus the key sorts. It ends with one write of
   the buffer and the trailing `\n`.

Overall: O(n) for validation, parsing and output, plus O(Σ m·log m) key
comparisons for objects, where each comparison costs the length of the
common prefix.

## Left to the implementer

- How the tree nodes look: a tagged union, enum, class hierarchy or parallel
  arrays, and whether nodes are allocated individually, in vectors or from
  an arena.
- Whether decoded strings and number text borrow from the input buffer or
  are copied once.
- Whether UTF-8 validation is a separate pass or fused into the parse.
- Error signalling style (from item 3), and recursion as such, given that
  depth is bounded by 512 (an interpreter with a small default recursion
  limit raises it, since each level costs more than one frame).
- The sort algorithm, as long as it is an O(m log m) comparison sort that
  satisfies item 8. A handle may cache a key prefix to speed up comparison.
- Micro-optimisations: lookup tables for byte classes, unrolled loops,
  output buffer growth policy, reading stdin in chunks or all at once.

## Pitfalls

- Building the canonical text of each subtree as soon as it is parsed and
  then concatenating children's strings into the parent's. That copies every
  byte once per nesting level: O(n·depth), which is pathological at depth
  512. Serialise once from the root into one buffer.
- Pushing string bytes one at a time while decoding or re-escaping long
  strings, instead of copying unescaped runs in bulk. This is several times
  slower on text-heavy input.
- Validating UTF-8 a second time per string (for example converting each
  decoded byte buffer to the language's checked string type), or decoding
  every key to code points or UTF-16 for each comparison.
- Comparing keys character by character with a full decode from the first
  byte, when a byte-prefix comparison would skip shared prefixes such as
  `"user:000…"`.
- Sorting fat member records (key plus a full value node) so that every swap
  moves large structs, or using a generic sort that goes through reflection
  or interface calls per swap. Sort small handles.
- Maintaining a hash map per object during parsing to resolve duplicates,
  then sorting as well. The sort already brings duplicates together.
- Allocating a new string for every number or every escape-free string when
  the input slice would do.
- Writing output piece by piece with unbuffered writes, or growing the output
  by repeated immutable string concatenation (quadratic).
- Using a Unicode-aware `isspace` or `isdigit`, or skipping whitespace with
  anything broader than the four ASCII bytes. This is both wrong and slower.
