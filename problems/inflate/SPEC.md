# inflate — DEFLATE decoder (RFC 1951)

Decompress a raw DEFLATE stream and print the result, or report that the
stream is malformed. This document is self-contained: everything needed to
implement the decoder is below. RFC 1951 is the authoritative background, but
where this document makes a decision about behaviour that RFC 1951 leaves
open, this document wins.

Write the decoder yourself: don't use a DEFLATE, zlib or gzip decompressor from
a library, the standard library or the language.

## I/O format

**Input (stdin):** a single line containing lowercase hexadecimal digits
(`0-9a-f`), two per byte, no separators, followed by a newline. The line may
be empty (zero bytes of stream). The digits decode to the raw DEFLATE stream:
there is no zlib (RFC 1950) or gzip (RFC 1952) wrapper, no checksum, no
length field. Input is guaranteed to be well-formed hex of even length; you
do not need to handle anything else. Leading/trailing whitespace may be
ignored.

**Output (stdout):** exactly one line, then a newline:

- on success, the decompressed bytes as lowercase hexadecimal, two digits per
  byte, no separators (an empty result is an empty line); or
- the word `error` if the stream is malformed in any of the ways listed under
  *Error conditions* below.

Exit with status 0 in both cases. Print nothing else on stdout.

### Examples

Input:
```
0300
```
Output (an empty line — a fixed-Huffman block containing only end-of-block):
```

```

Input (one stored block holding the byte `41`):
```
010100feff41
```
Output:
```
41
```

Input (fixed-Huffman block: literals `a`,`b`,`c`, then a copy of length 6 at
distance 3, then end-of-block):
```
4b4c4a862000
```
Output:
```
616263616263616263
```

Input (fixed-Huffman block whose first symbol is length code 257 with
distance code 0, i.e. a copy of 3 bytes from distance 1 while nothing has
been output yet):
```
030200
```
Output:
```
error
```

## Bit-level conventions

The stream is a sequence of bytes. Bits are consumed starting from the least
significant bit of each byte. Multi-bit *numeric* fields (block header bits,
extra bits, stored-block lengths, HLIT/HDIST/HCLEN, code-length values) are
read least-significant-bit first, so a field spanning several bits has its
first bit read as bit 0 of the value. *Huffman codes* are the exception: they
are packed most-significant-bit first, i.e. the first bit read is the first
(leftmost) bit of the code.

## Stream structure

The stream is a sequence of blocks. Each block starts with a 3-bit header:

- `BFINAL` (1 bit): 1 if this is the last block.
- `BTYPE` (2 bits): 0 = stored, 1 = fixed Huffman, 2 = dynamic Huffman,
  3 = invalid (error).

Blocks are not byte-aligned except where stated. Back-references may refer
to bytes produced by earlier blocks. After the block with `BFINAL = 1` ends,
the remaining bits of the current byte (if any) are ignored; **any whole byte
after that is an error** (see *Error conditions*).

### Stored block (BTYPE = 0)

After the 3 header bits, skip to the next byte boundary (discard the
remaining bits of the current byte; if the header ended exactly on a byte
boundary nothing is discarded). The values of the discarded bits are not
checked and may be nonzero. Then read `LEN` (16 bits, little-endian) and
`NLEN` (16 bits, little-endian). `NLEN` must equal the one's complement of
`LEN` (`LEN ^ NLEN == 0xFFFF`), otherwise error. Then copy the next `LEN`
bytes verbatim to the output. `LEN` may be 0. The next block starts at the
byte after the copied data.

### Compressed blocks (BTYPE = 1 or 2)

A compressed block is a sequence of symbols from the *literal/length*
alphabet (0..285), each encoded with a Huffman code:

- 0..255: a literal byte, appended to the output.
- 256: end of block.
- 257..285: a length code. The length is the base value plus `extra` further
  bits (read as a number, LSB first):

  | sym | extra | base | sym | extra | base | sym | extra | base |
  |-----|-------|------|-----|-------|------|-----|-------|------|
  | 257 | 0 | 3  | 267 | 1 | 15 | 277 | 4 | 67  |
  | 258 | 0 | 4  | 268 | 1 | 17 | 278 | 4 | 83  |
  | 259 | 0 | 5  | 269 | 2 | 19 | 279 | 4 | 99  |
  | 260 | 0 | 6  | 270 | 2 | 23 | 280 | 4 | 115 |
  | 261 | 0 | 7  | 271 | 2 | 27 | 281 | 5 | 131 |
  | 262 | 0 | 8  | 272 | 2 | 31 | 282 | 5 | 163 |
  | 263 | 0 | 9  | 273 | 3 | 35 | 283 | 5 | 195 |
  | 264 | 0 | 10 | 274 | 3 | 43 | 284 | 5 | 227 |
  | 265 | 1 | 11 | 275 | 3 | 51 | 285 | 0 | 258 |
  | 266 | 1 | 13 | 276 | 3 | 59 |     |   |     |

  Symbol 284 with all 5 extra bits set gives length 258; that is legal (it
  encodes the same length as symbol 285). Symbols 286 and 287 exist in the
  fixed code but are invalid if decoded (error).

  A length code is immediately followed by a *distance* symbol (0..29) from
  the distance alphabet, encoded with the distance Huffman code, followed by
  its extra bits:

  | sym | extra | base | sym | extra | base | sym | extra | base |
  |-----|-------|------|-----|-------|------|-----|-------|------|
  | 0 | 0 | 1  | 10 | 4 | 33  | 20 | 9  | 1025  |
  | 1 | 0 | 2  | 11 | 4 | 49  | 21 | 9  | 1537  |
  | 2 | 0 | 3  | 12 | 5 | 65  | 22 | 10 | 2049  |
  | 3 | 0 | 4  | 13 | 5 | 97  | 23 | 10 | 3073  |
  | 4 | 1 | 5  | 14 | 6 | 129 | 24 | 11 | 4097  |
  | 5 | 1 | 7  | 15 | 6 | 193 | 25 | 11 | 6145  |
  | 6 | 2 | 9  | 16 | 7 | 257 | 26 | 12 | 8193  |
  | 7 | 2 | 13 | 17 | 7 | 385 | 27 | 12 | 12289 |
  | 8 | 3 | 17 | 18 | 8 | 513 | 28 | 13 | 16385 |
  | 9 | 3 | 25 | 19 | 8 | 769 | 29 | 13 | 24577 |

  Distance symbols 30 and 31 exist in the fixed code but are invalid if
  decoded (error). Distances range from 1 to 32768.

  The pair (length, distance) means: copy `length` bytes starting `distance`
  bytes back from the current end of the output. The copy may overlap the
  region being written (distance < length): bytes are copied one at a time,
  so a distance of 1 replicates the last byte `length` times. `distance` must
  not exceed the number of bytes output so far in the whole stream (across
  all blocks), otherwise error. There is no 32 KiB window limit beyond the
  32768 maximum encodable distance itself.

The block ends when symbol 256 is decoded.

### Huffman codes

A code is defined by a code length (in bits, 0 = symbol unused, otherwise
1..15) for each symbol of an alphabet. Codes are assigned canonically:
shorter codes sort before longer ones and, within one length, symbols in
increasing order get increasing code values (RFC 1951 section 3.2.2):

```
count[len] = number of symbols with that length (count[0] = 0)
code = 0
for len in 1..15:
    code = (code + count[len-1]) << 1
    next_code[len] = code
for each symbol in increasing order with length L != 0:
    code_of(symbol) = next_code[L]; next_code[L] += 1
```

Let the *Kraft sum* of a length set be `sum over used symbols of 2^-len`.
The set is *complete* when the sum is exactly 1, *over-subscribed* when it
is greater than 1 and *incomplete* when it is less than 1.

### Fixed Huffman block (BTYPE = 1)

Uses these fixed code lengths:

- literal/length: symbols 0..143 → 8 bits, 144..255 → 9 bits, 256..279 → 7
  bits, 280..287 → 8 bits;
- distance: symbols 0..31 → 5 bits.

Both sets are complete. Symbols 286, 287 and distance symbols 30, 31 have
codes but decoding one of them is an error.

### Dynamic Huffman block (BTYPE = 2)

After the 3 header bits:

1. `HLIT` (5 bits): number of literal/length code lengths minus 257.
2. `HDIST` (5 bits): number of distance code lengths minus 1.
3. `HCLEN` (4 bits): number of code-length-code lengths minus 4.
4. `HCLEN + 4` values of 3 bits each: the code lengths (0..7) of the
   *code-length alphabet* (symbols 0..18), given in this symbol order:
   `16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15`.
   Symbols not covered get length 0.
5. Using the code-length code, decode `HLIT + 257 + HDIST + 1` code lengths
   as one contiguous sequence (literal/length lengths first, then distance
   lengths). Code-length symbols mean:
   - 0..15: that literal length value;
   - 16: repeat the previous length 3..6 times (2 extra bits + 3);
   - 17: length 0 repeated 3..10 times (3 extra bits + 3);
   - 18: length 0 repeated 11..138 times (7 extra bits + 11).
   A repeat may run from the literal/length part into the distance part.
   A 16 as the very first entry (no previous length) is an error. A repeat
   that would produce more than `HLIT + 257 + HDIST + 1` lengths in total is
   an error.
6. Build the literal/length code (from the first `HLIT + 257` lengths) and
   the distance code (from the remaining `HDIST + 1` lengths) and decode the
   block's symbols as described above.

Validity rules for a dynamic block (each violation is an error):

- `HLIT + 257` must be at most 286 and `HDIST + 1` at most 30
  (i.e. `HLIT <= 29` and `HDIST <= 29`).
- The code-length code (symbols 0..18) must be **complete**.
- The literal/length code must give symbol 256 a nonzero length, and its
  length set must be complete, *except* that a set consisting of exactly one
  code of length 1 is accepted (that code is then necessarily symbol 256).
- The distance length set must be complete, *except* that an empty set (no
  distance codes at all) and a set consisting of exactly one code of length
  1 are accepted.
- Over-subscribed sets are never accepted.
- Whenever a code table is incomplete (the single-1-bit-code cases), reading
  a bit pattern that is not a code is an error. With a single code of length
  1 the only valid code is the bit `0`.
- Decoding a length code while the distance set is empty is an error.

These rules match what zlib enforces.

## Error conditions (summary)

Print `error` (and nothing else) if any of the following occurs; otherwise
the stream is valid and the full output must be printed. Detect errors
wherever they occur, even after megabytes of otherwise valid output.

1. The stream ends before the final block is complete (this includes the
   empty stream, a stream that ends after a non-final block, ends inside a
   block header, inside a stored block's LEN/NLEN or data, inside a Huffman
   code, or inside extra bits). Note that a decoder may *peek* beyond the end
   of the stream while matching codes, but must not *consume* bits that do
   not exist.
2. `BTYPE = 3`.
3. Stored block with `LEN ^ NLEN != 0xFFFF`.
4. `HLIT > 29` or `HDIST > 29`.
5. Any code-length set violating the validity rules above (over-subscribed;
   incomplete beyond the permitted single-code / empty exceptions; missing
   end-of-block code).
6. Code-length symbol 16 with no previous length; a repeat overflowing the
   number of lengths.
7. A bit pattern that does not correspond to any code in an incomplete
   table.
8. Literal/length symbol 286 or 287; distance symbol 30 or 31; a length code
   when there are no distance codes.
9. A distance greater than the number of bytes output so far.
10. Trailing data: one or more whole bytes remain after the final block's
    last consumed bit. (Leftover bits within the last partially used byte
    are fine and their values are not checked.)

A stream that is valid produces the same output regardless of how a decoder
buffers input, so there is exactly one correct answer for every input.

## Input sizes

- Decompressed output is at most 16 MiB (32 MiB of hex output); the input
  line is at most about 34 MiB of hex (a stored-block stream is slightly larger
  than its payload).
- Streams may contain thousands of blocks (one test has ~1700 dynamic
  blocks), a million literals in a row, or a single dynamic block covering
  1 MiB of output.
- Read all of stdin before decoding; do not assume the hex line is short.

## Test suite overview

`tests/` contains 80 cases: tiny hand-made streams (stored, fixed, dynamic,
empty and mixed blocks, single-code and empty distance tables, 15-bit codes,
length 258 at distance 32768, length symbol 284 with extra value 31, all
286 + 30 symbols in use, code-length repeats 16/17/18 including runs
crossing the literal/distance boundary and a 16 repeating the zero produced
by a 17 run, a stored-block header ending on a byte boundary, nonzero
padding/discarded bits), zlib output at levels 0–9 with the default,
filtered, Huffman-only, RLE and fixed strategies, 35 malformed streams
(including the empty stream) covering every error condition above — each
malformed stream is otherwise well-formed, so a decoder that skips the
check in question prints data instead of `error` — and 1 MiB-scale text,
binary, random (stored), repetitive and near-maximum-distance data.
