# inflate — required approach

SPEC.md defines what the program does; this note defines how it is built. Where
the two seem to disagree, SPEC.md wins.

## Overall approach

Read all of standard input in one bulk read, convert the hex digits into a
byte array in one linear pass, and decode that array with a table-driven
DEFLATE decoder: an LSB-first bit buffer, canonical Huffman codes turned into
two-level lookup tables (a root table indexed by the next few stream bits plus
second-level subtables for longer codes), and a single preallocated output
byte array that back-references copy within. On success, convert the output to
hex in one pass into a preallocated buffer and write it with a single write;
on any malformation, stop at once and print `error`.

Sizes below: `I` is the compressed stream length in bytes (the hex line has
`2I` digits), `O` the decompressed length (at most 1 MiB), `B` the number of
blocks. The whole decode is O(I + O + B·T), where `T` is the per-block table
cost bounded in item 5.

## Required choices

1. **Input.** Read stdin in one bulk read (or a loop of large reads into one
   growing buffer with geometric growth). Trim surrounding whitespace, then
   decode hex digits two at a time into a byte array preallocated to `I`
   bytes, using a 256-entry lookup table or simple range arithmetic per digit.
   No per-byte appends through a growth check, no per-pair substring
   allocation, no regex or character-by-character stream reads. A standard
   library bulk hex decoder that does exactly this is allowed.
2. **Bit reader.** Keep a 64-bit (or wider) bit buffer plus a count of valid
   bits, filled from the byte array least-significant byte first; refill
   only when the count falls below what the next operation needs (at least
   32 bits after a refill, so one Huffman code plus its extra bits never needs
   a second refill). Past the end of the data, refill with zero bits so a code
   lookup may *peek* beyond the stream, but track the number of real bits so
   that *consuming* a bit that does not exist is detected (SPEC error 1).
   Fixed-width fields (header bits, extra bits, HLIT/HDIST/HCLEN, 3-bit
   code-length lengths, LEN/NLEN) are taken from the buffer with a mask and
   shift, never one bit at a time. The consumed position is always derivable
   as (bytes loaded × 8 − bits still buffered); the trailing-data check after
   the final block (SPEC error 10) uses it: rounding the consumed bit count up
   to whole bytes must reach the end of the data.
3. **Huffman decode, O(1) per symbol for codes up to the root width.** Each
   code is a lookup table indexed by the next `R` bits of the bit buffer
   (bit-reversed codes, since Huffman codes are MSB-first and the buffer is
   LSB-first). An entry packs the symbol (or subtable offset) and the code
   length; the decoder consumes exactly that many bits. Codes longer than `R`
   go through one second-level subtable, indexed by the next bits after the
   root, sized to the longest code sharing that root prefix. Use `R = 10` for
   literal/length tables and `R = 8` for distance tables; the code-length
   code (max length 7) is a single-level table. A zero/sentinel entry means
   "not a code" and is an error (SPEC error 7) — this is how incomplete
   single-code tables reject the bit `1`.
4. **Table construction.** From the lengths: count codes per length, compute
   the Kraft balance (over-subscribed, complete, incomplete, empty) in O(15),
   validate per SPEC, then assign canonical codes in increasing symbol order
   and fill the root table by striding (`entry` written at `rev, rev + 2^len,
   …`) and subtables likewise. Precompute nothing per symbol beyond the
   reversed code. Bit reversal is a small loop or a reverse table; either is
   fine.
5. **Per-block table cost, T = O(n_sym + 2^R + subtable entries).** Dynamic
   blocks rebuild three tables each; with thousands of blocks this cost is
   paid thousands of times. Tables live in buffers allocated once and reused
   across blocks; only the `2^R` root entries plus the subtable entries
   actually used are (re)written for each block. Never size a single-level
   table to the longest code (up to 2^15 entries) and never clear or
   allocate a 2^15-entry table per block.
6. **Fixed-code tables.** Build the fixed literal/length and distance tables
   once, lazily on the first BTYPE=1 block or at start-up, and reuse them for
   every fixed block. Symbols 286/287 and distance 30/31 are present in the
   tables and rejected when decoded.
7. **Literal/length/distance decoding.** After a literal/length lookup,
   branch: literal → store the byte; 256 → end of block; 257..285 → base and
   extra-bit count from the two 29-entry constant tables, then a distance
   lookup and its base/extra from the two 30-entry tables. All four tables
   are constant arrays, not computed per symbol and not maps.
8. **Output buffer.** One contiguous byte array for the whole stream, which
   is also the back-reference window (no separate circular window: the spec
   allows distances back to any earlier output, and the output fits in
   memory). Preallocate it (1 MiB is the maximum; reserving that, or growing
   geometrically, are both fine) and write through an index. A literal is one
   store and an index increment, plus at most one integer capacity
   comparison; the per-symbol path never calls a general-purpose append or
   reserve routine. Writes stay bounds-safe even if a stream would exceed the
   preallocation (grow, or check before writing).
9. **Back-reference copy, O(length).** Check `distance <= written` before
   copying. If `distance >= length` the source and destination do not
   overlap: copy with one block/slice copy. Otherwise copy forward byte by
   byte (or, equivalently, in non-overlapping chunks of `distance` bytes,
   doubling), so a distance of 1 replicates the last byte. Ensure capacity
   once per copy, not once per byte.
10. **Stored blocks.** After the 3 header bits, discard bits up to the next
    byte boundary (nothing if already aligned), read LEN and NLEN as two
    16-bit fields and check them, then derive the byte position from the
    consumed bit count, check that `LEN` bytes remain (else SPEC error 1),
    copy them with one bulk copy, and restart the bit reader (empty buffer)
    at the byte after them. Never route stored bytes through the bit buffer
    one byte at a time.
11. **Errors.** Detect each SPEC error at the point it occurs and abandon
    decoding immediately (exception, error return or flag checked in the
    loop); do not decode the rest of the stream after an error. Error checks
    are integer comparisons in the hot loop, not extra passes.
12. **Output.** Convert the output bytes to hex with a 16-character (or
    512-byte pair) lookup table into one buffer of exactly `2·O + 1` bytes,
    and write it with one call. No per-byte formatting routine or per-byte
    write.

## Left to the implementer

- Exact entry packing (bit fields in a 16- or 32-bit integer, parallel arrays,
  small structs), as long as a lookup is one array index.
- Whether the bit buffer refills byte by byte or with an unaligned 8-byte
  load, and the exact refill threshold.
- Whether the output buffer is reserved at 1 MiB up front or grown
  geometrically; whether the overlapping copy is byte by byte or chunked.
- The mechanism for reporting errors, function and module structure, naming,
  whether the fixed tables are built eagerly or lazily.
- How whitespace at the ends of the input is skipped.
- Micro-optimisations such as decoding two literals per lookup, unchecked
  indexing where the language offers it safely, or branch layout — none is
  required.

## Pitfalls

- Single-level tables sized `2^maxLength` (up to 32768 entries), allocated
  or zero-filled for every dynamic block. A stream of thousands of small
  dynamic blocks turns this into tens of megabytes of memory traffic.
- Falling back to bit-by-bit canonical decoding for every code longer than a
  small root table. On literal-heavy data with a wide alphabet, many codes are
  longer than 9 bits, and the slow path then dominates; use a subtable.
- Building the decoded input or the output with a general-purpose dynamic
  array append (or a reserve call) per byte in a tight loop, or growing the
  input read buffer by concatenating fixed-size chunks to a new array each
  time.
- Computing the trailing-data check or the stored-block byte position from
  the bytes loaded into the bit buffer rather than the bits actually
  consumed: the buffer reads ahead, so whole bytes it has loaded but not
  consumed are still trailing data.
- Reading the bit stream with a bounds-checked per-bit or per-byte fetch for
  every peek instead of keeping bits in a register-sized buffer.
- Copying a non-overlapping back-reference byte by byte through a generic
  append, or ensuring capacity per copied byte.
- Allocating new tables, length arrays or symbol lists per block when fixed-
  size buffers (at most 286 + 30 lengths, at most a few thousand table
  entries) can be reused.
- Formatting each output byte with a general-purpose number formatter or
  writing output in many small writes.
- Converting the hex input with a per-pair string slice and integer parse.
