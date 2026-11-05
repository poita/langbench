# webhooks — required approach

SPEC.md defines what the program does. This note defines how it is built. Where
the two seem to disagree, SPEC.md wins.

## Overall approach

Read all of standard input with one bulk read into a single byte buffer and
walk it line by line, taking lines and fields as views into that buffer.
Hex arguments are decoded in one pass into one byte buffer each. SHA-256 is an
incremental hasher (8-word state, 64-byte block buffer, length counter) whose
compression function works on fixed-size local storage. Every parsed secret is
turned once into an HMAC key object holding the two hasher states after the
ipad and opad blocks; a MAC copies those states and streams the signed content
`id`, `"."`, `ts`, `"."`, `body` through them without building a concatenated
message. A `simulate` block is parsed into arrays of endpoints and events,
expanded into a delivery array (each delivery signed once at creation), and run
through one binary min-heap of `(time, delivery)` pairs. All output is
appended to one output buffer and written at the end.

Sizes below: `L` is the total input size in bytes, `B` a message length in
bytes, `S` the number of secrets in a command or endpoint, `T` the number of
header tokens, `E`/`P` the events/endpoints of a block, `D` its deliveries and
`A` its attempts (`A ≤ 8D`).

## Required choices

1. **Input, O(L).** One bulk read of stdin into a single buffer. Lines are
   found by scanning for `\n`; fields by scanning for single spaces. Lines and
   fields are views (offset/length or slices) into the buffer, not owned
   copies. Validation of each field kind (`<int>`, `<id>`, names, secrets) is a
   single pass over its bytes: a hand-written loop, or one standard-library
   scan with the same effect (for example a byte-class check), never a
   backtracking or per-character re-scan.
2. **Hex decoding, O(n).** Validation (lowercase `0-9a-f`, even length, or
   `-`) and decoding are linear passes into a buffer allocated once at size
   `n/2`: either one hand-written pass via a 256-entry lookup table or range
   checks, or a lowercase-only validation followed by the standard library's
   bulk hex decoder where one exists. No per-byte appends to a growing buffer,
   no substring or integer-parse call per digit pair. Each payload is decoded
   once per line (once per event in a block), never per secret or delivery.
3. **SHA-256, O(B).** An incremental hasher: `update` first tops up a partial
   block, then compresses full 64-byte blocks directly from the caller's bytes
   without copying them, then buffers the tail; `finish` pads per §1.1. The
   compression function uses a 64-entry (or rolling 16-entry) message schedule
   and the eight working variables as local fixed-size storage: no heap
   allocation per block or per hash (in a language without stack arrays, one
   local list per compression call is the equivalent). Arithmetic is unsigned 32-bit; in a
   language without fixed-width integers, mask to 32 bits after each addition
   chain.
4. **HMAC key precomputation.** When a secret is parsed, derive the 64-byte
   padded key once, absorb `key ⊕ ipad` into one hasher and `key ⊕ opad` into
   another, and keep both states. A MAC is: copy the inner state, stream the
   message, finish; copy the outer state, absorb the 32-byte inner digest,
   finish. A MAC over `B` bytes therefore costs `⌈(B+9)/64⌉ + 1` compressions.
   The `hmac` command builds a key object the same way and uses it once.
5. **Streamed signed content.** The signed content is fed to the inner hasher
   as its parts (`id`, `"."`, timestamp text exactly as received, `"."`,
   body). It is never materialised as a new buffer, neither per command nor per
   secret nor per delivery, and `ipad || message` is never concatenated.
6. **sign, O(S·B).** One MAC per secret; the header is built by appending
   `v1,`, the 44-character Base64 and a separator into one buffer (or straight
   into the output buffer).
7. **verify, O(T + S·B).** Split the header into token views. Perform the
   §2.3 checks in order. Then pre-process each token once: find the first
   `,`, require `v1`, Base64-decode the value; tokens that fail, or that do not
   decode to exactly 32 bytes, are marked as never matching. Then for each
   secret in order compute its MAC once and compare it against the
   pre-decoded tokens in order; stop at the first match. The MAC is never
   computed per (secret, token) pair and a token is never decoded per secret.
8. **Base64, O(n).** Table-driven: encoding maps each 3-byte group to 4
   characters through the alphabet string; decoding uses a 256-entry table
   (value or invalid, plus which alphabet a character belongs to) and validates
   the §1.3 rules in the same pass that produces the bytes, into a buffer
   sized up front.
9. **Simulation data.** Endpoints and events live in arrays and are referred to
   by index everywhere after parsing. Each endpoint holds its HMAC key objects
   (item 4, built once at parse time), its filter (a wildcard flag or the list
   of up to 16 type strings, matched by direct comparison), its parsed script
   as an array of small integers, a cursor and a disabled flag. Each event
   holds its id, timestamp text, parsed timestamp, type and payload decoded
   once. Duplicate ids are detected with two hash sets per block, one for
   endpoint ids and one for event ids (the two namespaces are independent).
   Once a block line is invalid, the remaining lines up to `end` are only
   compared against `end`, not parsed. Deliveries are created only after a
   valid `end`, in
   event-then-endpoint order into one array of records holding event index,
   endpoint index, attempt count, last time, status and the signature header.
10. **Signing in the simulator, O(Σ S·B) over deliveries.** Each delivery is
    signed exactly once, when it is created, with every endpoint secret (item
    6). Signatures are never recomputed per attempt and are not memoised or
    shared between deliveries, even when two endpoints have equal secrets.
11. **Scheduler, O((D + A) log D).** One binary min-heap whose elements are
    plain `(time, delivery index)` pairs (two integers, or one packed key;
    where every value is an object, a tuple or one packed integer), ordered
    lexicographically. Its backing array is reserved for `D` elements
    (a delivery has at most one pending attempt) and push/pop work in place by
    sift-up/sift-down. The heap starts with every delivery's first attempt
    (heapify, or `D` pushes); each step pops one element, processes it per
    §4.4, and pushes at most one retry using the fixed delay table.
12. **Attempt records.** Each processed attempt appends a compact record
    (delivery index, attempt number, time, script response) to one array with
    amortised growth or reserved capacity. Records hold indices, not copies of
    id strings.
13. **Output, O(output size).** One output buffer for the whole run (or one
    large buffered writer). The `sim A D` line is written after the run, then
    the attempt and delivery lines are produced from the records: ids copied
    from the stored id bytes, integers formatted straight into the buffer,
    fixed words from constants. No intermediate string per line or per block
    that is then copied again, and no flush per line.

## Left to the implementer

- Container types, struct layout, naming and module structure; whether the
  simulator stores the signature header as text or as the raw 32-byte MACs and
  encodes them at output time.
- The exact form of the SHA-256 round loop: unrolling, a rolling 16-word
  schedule, word loads by shifts or by a byte-swapping load, index or pointer
  style, bounds-check elimination.
- Whether lines are pre-split into an array of views or scanned lazily, and
  whether the input buffer is decoded to text first (all grammars are ASCII).
- The heap implementation: hand-written or a standard-library binary-heap
  priority queue, provided elements are `(time, delivery)` values rather
  than references to per-attempt objects and the complexity above holds.
- In verify, whether MAC computation is skipped entirely when no token is a
  32-byte `v1` candidate (the output is `no-match` either way).
- Integer formatting routine and hex/Base64 table layout.
- Whether the filter is matched by string comparison or by interned type ids.

## Pitfalls

- Reading stdin one character at a time through a locked or synchronised
  stream (for example via a character iterator over the standard input
  stream): with megabyte-sized inputs this alone costs several times the
  hashing work. Read in large chunks or all at once.
- A heap whose pop shrinks the backing array and whose push then grows it
  again, in languages where appending to a shrunk array view reallocates and
  copies the whole array: every push becomes O(D) and the scheduler O(D·A).
  Keep an explicit length over reserved storage.
- Finding the next attempt by sorting or linearly scanning all pending
  attempts each step, or by re-sorting the whole attempt list.
- Building `ipad || message` or `id.ts.body` as a new buffer for every MAC,
  copying a multi-kilobyte body once per secret; recomputing the key pads for
  every MAC instead of reusing the precomputed states.
- In verify, computing a MAC for every (secret, token) pair or re-decoding the
  token for every secret.
- Assembling output by concatenating many temporary strings per line,
  formatting every integer into its own heap string, building a block's
  output as one string and then copying it into the main output, or growing
  an immutable string by repeated concatenation.
- Storing per-attempt or per-delivery copies of id strings, or boxed objects
  with pointers, in large arrays: under a tracing garbage collector these
  arrays are rescanned on every collection and allocation churn dominates.
- Allocating the SHA-256 message schedule or block buffer on the heap per
  block or per hash, or using a general arbitrary-precision integer path
  without masking.
- Re-rendering the timestamp from its parsed integer for signing instead of
  using the received text, or re-parsing secrets or re-decoding payloads per
  delivery.
- Signing deliveries while the block is still being read: a later invalid
  line makes the whole block `error`, so that work is wasted.
