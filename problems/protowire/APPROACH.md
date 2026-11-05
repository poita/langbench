# protowire — required approach

SPEC.md defines what the program does. This note defines how it is built. Where
the two seem to disagree, SPEC.md wins.

## Overall approach

Read all of standard input with one bulk read and split it into line views.
Tokenize and parse the schema once into an array of message descriptors,
resolving every field's type to a scalar kind or a message index, with fields
sorted by number and two lookup tables per message (number → field slot,
name → field slot). Each request is then handled independently:

- **decode**: convert the hex once into a byte buffer, decode it with a
  recursive-descent reader into a value tree (one slot per schema field),
  then render the canonical text from the tree directly into the output
  buffer.
- **encode**: parse the text with a single-pass recursive-descent parser
  directly into the same value tree, compute every message's encoded size in
  one bottom-up pass (caching it on the node), then write the bytes forward in
  one pass with the length prefixes already known, and hex them into the
  output buffer.

All output goes into one growable buffer that is written once at the end.
Sizes below: `L` is the total input size, `P` the byte length of one decode
payload, `T` the length of one encode text, `F ≤ 64` the fields in a message,
`D ≤ 64` the nesting depth.

## Required choices

1. **Input and output, O(L).** One bulk read of stdin. Requests are views
   (start, end) into that buffer; never copy a line into its own string. The
   whole output is accumulated in one byte buffer and written with one write
   (or one large buffered writer). Each request renders straight into that
   buffer, not into a per-request string that is then copied. A failed request
   truncates the buffer back to the line's start and appends `error`.
2. **Schema compiled once.** Each message descriptor holds its fields as an
   array sorted by field number; a field records its name, number, kind,
   repeated flag, resolved message index, its expected wire type and its
   precomputed tag (value or bytes). Lookups:
   - by number during decode: a hash map from number to slot index, or a
     binary search over the sorted numbers — expected O(1) or O(log F);
   - by name during encode, and for the request's message name: a hash map
     keyed by the name bytes, looked up with a view of the input (no
     per-lookup allocation of a key string; where the runtime makes every
     substring an object, one substring per lookup is the floor).
3. **Value tree.** One node per message instance, holding a slot array with
   one entry per schema field (indexed by the field's position in number
   order). A slot is a compact tagged value: absent, one number (stored as
   a 64-bit integer in a canonical form), one byte string, one child node, or
   a list of numbers / byte strings / child nodes. A slot is a few machine
   words at most: list storage sits behind a single reference (or inside a
   union/enum) created on the first element and grown by amortised doubling,
   not as three always-present list members. On 64-field messages the slot
   array dominates allocation, so slot size matters.
4. **Hex input, O(P).** Validate (lowercase `0-9a-f` only, even length) and
   convert the request hex in one pass with a lookup table, or validate the
   characters and then use a built-in bulk hex-to-bytes conversion, into one
   byte buffer per request.
5. **Decode, O(P) plus output.** One reader over the byte buffer with an
   end bound per message; a sub-message is decoded by recursing on the
   sub-range `[pos, pos+len)` of the same buffer, not a copy. Varints, tags
   and length prefixes are read by hand-written loops enforcing the 10/5/5
   byte limits, tag < 2^32, field number ≥ 1, a valid wire type, and length ≤
   remaining bytes. Unknown fields, wrong-wire-type fields and groups are
   skipped by advancing the position (groups by a recursive skip matching
   end-group numbers). Packed fields are decoded in a loop over their
   sub-range, appending to the list. String payloads are validated as UTF-8
   in one linear pass; string and bytes values are stored as views into the
   decoded buffer (or one copy each). Singular message fields merge by
   decoding further occurrences into the existing child node.
6. **Text rendering, O(output).** Walk the slot array in field-number order and
   append directly to the output buffer: integers by a digit loop or the
   language's cheapest built-in integer-to-decimal conversion (signed or
   unsigned per kind), strings by scanning for bytes that need escaping and
   copying the runs between them in bulk, bytes by a 256-entry (or nibble) hex
   table or a built-in bytes-to-hex conversion. No per-field or per-message
   intermediate strings. Where strings are immutable and there is no growable
   byte buffer, one flat list of pieces joined once per output is the
   equivalent.
7. **Text parsing, O(T).** A single cursor over the request text, recursive on
   `{`, with no separate tokenization pass. Field names are matched as views
   via the name table. Integers are parsed by a digit loop with overflow and
   range checks per kind. String literals without escapes may be stored as
   views of the input; otherwise they are unescaped into one new buffer.
   Bytes literals are converted from hex directly into their final buffer.
   Duplicate field names are detected by a per-slot "seen" flag kept in the
   node (not a separate array allocated per parsed message); it is set even
   when the given value is a default such as `0` or `[]`.
8. **Encoding, O(T), two passes.** First a recursive size pass computes each
   node's encoded size bottom-up and stores it on the node (packed list
   payload sizes may also be cached). Then a write pass emits fields in
   number order into one byte buffer (reserved to the root size), writing each
   sub-message's minimal length prefix from the cached size before recursing.
   Every byte is written once; no sub-message is encoded into a temporary
   buffer, and no length prefix is inserted after the fact. The finished bytes
   are hexed by table (or built-in conversion) straight into the output
   buffer.
9. **Errors are cheap.** Errors propagate by a status return, or by one
   non-allocating mechanism (a preallocated exception or equivalent). The tree
   of a failed request is simply discarded.
10. **Per-request state is not reallocated wholesale.** Scratch buffers (decoded
    bytes, encode buffer) may be reused across requests; nothing proportional
    to the schema is rebuilt per request.

## Left to the implementer

- Container types, struct and enum layout, naming and module structure.
- Hash map type and hash function; hash map versus binary search for number
  lookup; whether very small messages use a linear scan.
- Whether value-tree nodes come from the general allocator, an arena, or a
  pool reset per request; whether string values are views or copies.
- Whether the encode tree stores numbers already converted to wire form
  (zigzagged) or in canonical signed form.
- Recursive versus explicit-stack traversal, and the depth guard value.
- Whether the decoded hex buffer and encode buffer are per request or reused;
  whether packed fixed-width lists are pre-sized from the payload length.
- Micro-optimisations: unrolled varint readers, word-at-a-time ASCII scans in
  UTF-8 validation and escaping, bounds-check elimination.

## Pitfalls

- Splicing each length prefix in front of an already written sub-message
  (inserting into the buffer, rotating the tail) or encoding each sub-message
  into its own temporary buffer and copying it into the parent: each nesting
  level re-copies its subtree, O(T·D) on deep trees.
- Recomputing a sub-message's size at every ancestor (calling a size function
  from inside the write pass without caching): O(T·D) or worse.
- Rendering each message, list or request into its own string and then
  concatenating or joining it into the parent: the text is re-copied at every
  nesting level.
- Allocating an owned key string for every field-name or message-name lookup,
  or for every hex chunk, bool word or identifier.
- Collecting a bytes literal's hex digits into an intermediate string before
  converting them.
- A slot struct with one member per possible kind (number, string, child,
  three lists) allocated for every field of every node: on 64-field messages
  most of the allocation is empty slots.
- Copying the payload of every sub-message or packed field into a new buffer
  before decoding it, instead of decoding the sub-range in place.
- Formatting integers or hex through a general-purpose format-string call per
  value, or writing each output line with a separate unbuffered write.
- Allocating a fresh exception object (with a stack trace) for every malformed
  request.
