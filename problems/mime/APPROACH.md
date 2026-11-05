# mime — required approach

SPEC.md defines what the program does; this note defines how it is built. Where
the two seem to disagree, SPEC.md wins.

## Overall approach

A single-threaded, one-message-at-a-time pipeline over byte buffers. Read the
mbox file (or each `.eml` file) with one bulk read and split it into message
slices without copying. For each message in turn: normalise CRLF to LF once
for the whole message into one buffer, build the MIME part tree by recursive
descent over slices (offsets) of that buffer, decode each leaf's transfer
encoding once into a presized buffer, compute its Adler-32 once, render the
dump into one growable output buffer, write the dump and the attachment files
with one write each, append the message's line to the summary buffer, and
drop the message before moving on. `summary.txt` is written once at the end.

Sizes: `N` is a message's byte length, `d` its maximum nesting depth (at most
20), `L` the length of one header field value, `T` the total input size.

## Required choices

1. **Input, O(T).** A directory is listed once, filtered to regular files
   ending in `.eml`, sorted by name as byte strings, and each file is read
   whole with one bulk read when its turn comes. An mbox is read whole once
   and split in one forward scan of its lines (on the raw bytes, where a
   CRLF-only line counts as empty); each message is a slice of the file
   buffer. Never read through a character-at-a-time stream iterator.
2. **Line endings, O(N).** Normalise CRLF → LF for the whole message once,
   in one pass that copies runs between CRs in bulk into a buffer sized to the
   message. Every later step (headers, delimiters, part bodies, transfer
   decoding) works on this LF-only buffer; that is exactly equivalent to the
   spec's per-region line joining because every region boundary is a line
   boundary. `bytes=` reports the raw slice length. No other copy of the
   message's bytes is made for parsing.
3. **Part tree, O(N·d).** One recursive function parses a part from a slice:
   it scans header lines from the start, stopping at the end of the header
   block (it never splits or scans the body to parse headers), then dispatches
   on the effective type. A multipart body is scanned once, line by line
   (byte search for LF), comparing only lines that begin with `--` against the
   boundary bytes; each child is the slice between delimiters (less one
   trailing LF), passed down without copying. A `message/rfc822` child is the
   decoded body (by SPEC's guarantee this is the identity, so the same slice).
   Parts are numbered in pre-order with a counter as they are created and kept
   in a flat pre-order list (or equivalent), so `[structure]` is one pass.
   Each nesting level scans only its own body, so total work is O(N·d).
4. **Header fields.** Each field's unfolded bytes are the concatenation of its
   lines' contents (a slice when the field is one line); they are decoded from
   UTF-8 once. The lower-cased, stripped name is computed once at parse time
   and stored with the field; header lookup compares against the stored name.
5. **Text representation.** All header and body text is held as the
   language's native string type (UTF-8 bytes, or the native text type where
   the language's string is not a byte string), never as arrays of 32-bit code
   points built by the program. Scanning for syntax works on bytes (or on the
   native string's characters): every syntactic character in SPEC is ASCII, and no byte of a UTF-8 multi-byte sequence is ASCII, so byte
   scanning is exact. The `chars` count
   is the number of code points, counted while decoding (or by counting
   non-continuation bytes).
6. **Charset decoding, O(n).** One function per table writes UTF-8 directly
   into a buffer presized for the worst case (3 bytes per input byte for the
   single-byte tables), copying runs of bytes below 0x80 in bulk. The UTF-8 decoder implements the
   maximal-subpart rule by hand with the table from SPEC, copying runs of
   valid input rather than re-encoding each code point; a standard-library
   UTF-8 decoder is used instead only where it is known to follow the same
   replacement rule, as SPEC allows.
7. **Transfer decoding, O(n), one pass, presized output.** Base64 uses a
   256-entry lookup table (byte → sextet or "skip"), accumulates sextets in an
   integer and emits three bytes per four, then handles the 2- or 3-character
   tail (a single leftover character is discarded); output capacity `3·n/4 + 3` is reserved up front. Quoted-printable
   reserves the input length and copies runs without `=` in bulk. Identity
   encodings (`7bit`, `8bit`, `binary`, unknown) use the slice itself as the
   content, with no copy. Both decoders are written by hand, as SPEC requires.
8. **Adler-32, once per leaf, deferred modulo.** Compute it once when the leaf
   is built and store it; the `[structure]` and `[attachments]` lines reuse
   the stored value. Accumulate `a` and `b` in unsigned 32-bit (or wider)
   integers and reduce modulo 65521 only every 5552 bytes and at the end (the
   standard zlib bound that keeps `b` from overflowing). The result is
   identical to the per-byte formula.
9. **Header-value algorithms, O(L) per field** (plus decoded output):
   - Encoded-word recognition is attempted only where the two bytes `=?`
     occur, and is a forward scan to the third `?` and the closing `=`; Q and
     B decoding write into one presized byte buffer, then one `decode` call.
   - `decode_unstructured` / `decode_display` record items as (kind, start,
     end) ranges into the value, or decoded strings for encoded words and
     quoted strings, and concatenate once into one output buffer; whitespace
     and literal runs are ranges, not strings grown a character at a time.
   - Structured values split segments in one pass with the quoted-string
     scanner; parameter names and values are slices until a decoded copy is
     needed. RFC 2231 assembly groups segments by base name and orders them by
     numeric index (a small sort per parameter).
   - Address lists tokenise each field once into a token list where each
     token holds its kind, its text (a slice of the value where no unescaping
     or decoding is needed) and its start offset; elements are split by one
     pass with the angle counter; the phrase is the substring from the first
     token's start offset to the `<`, decoded once. Never re-tokenise per
     element or rebuild substrings by repeated concatenation.
   - Dates strip comments and tokenise in one pass, match month and zone
     names against small fixed tables, and compute the epoch and its UTC
     rendering with the closed-form `days_from_civil` and its inverse, using
     flooring division; no calendar, time-zone or regular-expression library
     and no loops over years or days.
10. **Output, O(output size).** Build each `messages/NNNN.txt` in one growable
    byte buffer and write it with one call; append the summary line to a
    summary buffer. `esc` scans for characters that need escaping and copies
    the unescaped runs between them in bulk (in UTF-8, U+0080–U+009F are the
    two-byte sequences `C2 80`–`C2 9F`). Body lines are found by scanning the
    text for LF and escaped straight into the buffer. Numbers are appended as
    digits (zero-padded where required) without building intermediate strings
    per field. Attachment content is written straight from the part's
    content buffer or slice. Create `messages/` once and `parts/NNNN/` once
    for each message that has attachments.
11. **One message at a time, one thread.** Parse, render and write a message
    before parsing the next, so memory stays at the input plus one message's
    tree. No threads, worker pools or asynchronous I/O.

## Left to the implementer

- Container types, the part record's layout (struct, class or tagged union),
  whether children are indices or references, naming and module structure.
- Whether the tree stores offsets into the message buffer or slice/view
  objects; whether a single-line field is borrowed or copied.
- How parameters are held (small ordered list or map) as long as the
  first-occurrence and RFC 2231 precedence rules hold.
- Whether line and byte searches use a library search primitive or a manual
  loop; whether the UTF-8 decoder has an extra ASCII fast path.
- Number formatting via the standard formatter or hand-written digit code, as
  long as it appends into the output buffer.
- Whether the mbox separator scan materialises a line list or scans on the
  fly; whether the multipart scan records delimiter positions first or
  recurses as it finds them.
- Loop-level micro-optimisations (bounds-check elimination, unrolling,
  lookup tables for hex digits or escapes) that keep the algorithms above.

## Pitfalls

- Appending decoded bytes one at a time to a dynamic array whose append is a
  runtime call (garbage-collected slices, unreserved vectors) in the base64,
  quoted-printable or CRLF passes; reserve the output size and write by
  index or bulk copy.
- Decoding base64 in two passes (first collecting the filtered sextets into a
  new array, then converting) instead of one table-driven pass.
- Computing Adler-32 twice per leaf (once for `[structure]`, once for
  `[attachments]`), and reducing modulo 65521 on every byte; on
  attachment-heavy input the checksum then becomes a leading cost.
- Storing header and body text as 32-bit code-point arrays and converting back
  to UTF-8 for output: four times the memory traffic plus a conversion per
  string.
- Recomputing a field's stripped, lower-cased name on every header lookup or
  every comparison, allocating each time.
- Building `decode_unstructured` items by appending one character at a time to
  per-item heap strings, or copying every token's text into a new string.
- Splitting a whole part (header and body) into a line array just to find the
  end of its header, or building a full line array of the same bytes twice
  (once for headers, once for delimiters) at every nesting level.
- Copying each child part's bytes into a new buffer before recursing, or
  re-normalising line endings separately for every part.
- Parsing every message into memory before writing any output: memory grows
  with the whole mailbox and the allocator or collector does several times
  more work.
- Reading files through character-by-character stream iterators, or writing
  output through a stream that is flushed per line; one bulk read and one
  write per file.
- Per-line or per-character formatted printing and string concatenation
  temporaries (`"| " + esc(line) + "\n"` producing three new strings per line)
  instead of appending into one buffer.
