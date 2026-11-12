# QR code encoder

Encode text payloads as QR Code Model 2 symbols (ISO/IEC 18004), printing the
module matrix as text. Everything needed to implement this from scratch with a
basic standard library is specified below; no external tables are needed
beyond those included here.

## Input

Standard input is a sequence of query lines separated by `\n` (the final
newline is optional). There are no blank lines. Each line has the form

    <ecl> <mask> <text>

* `<ecl>` is one of `L`, `M`, `Q`, `H` (error correction level).
* `<mask>` is a digit `0`..`7` (use exactly that mask pattern) or the word
  `auto` (choose the mask by penalty scoring, see below).
* `<text>` is everything after the second space up to the end of the line. It
  is non-empty, contains no `\n`, `\r` or tab, has no leading or trailing
  spaces, and may contain interior spaces and arbitrary UTF-8. Treat it as a
  byte string: mode selection, character counts and byte-mode data all
  operate on its UTF-8 bytes. No ECI header is ever emitted.

Every query is guaranteed to fit in some version 1..40 at the requested level,
so `<text>` is at most 7089 bytes (2953 bytes when byte mode applies). There
are between 1 and 10000 queries per input.

## Output

For each query, in input order:

    version <v> mask <m>
    <row 0>
    ...
    <row size-1>
    <empty line>

where `v` is the chosen version (1..40), `m` the mask used (0..7), and
`size = 4*v + 17`. Each row is exactly `size` characters: `#` for a dark
module, `.` for a light module. Row 0 is the top of the symbol, character 0 is
the leftmost column. Do not print a quiet zone. The empty line after every
symbol (including the last one) separates queries.

## Encoding algorithm

Coordinates below are `(x, y)` = (column, row), 0-based from the top-left.

### 1. Mode selection

Choose the first applicable mode:

1. **Numeric** if every byte is an ASCII digit `0`-`9`.
2. **Alphanumeric** if every byte is in the 45-character set
   `0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:` (index in this string is the
   character's value; note the space at index 36).
3. **Byte** otherwise (each byte of the UTF-8 text is one 8-bit character).

Lowercase letters are never alphanumeric.

### 2. Data bit stream for a single segment

Mode indicator (4 bits): numeric `0001`, alphanumeric `0010`, byte `0100`.

Character count indicator, width by version:

| mode         | v1-9 | v10-26 | v27-40 |
|--------------|------|--------|--------|
| numeric      | 10   | 12     | 14     |
| alphanumeric | 9    | 11     | 13     |
| byte         | 8    | 16     | 16     |

Count is the number of characters (digits, alphanumeric characters, or bytes).

Data bits:

* Numeric: groups of 3 digits, each group's decimal value written in 10 bits;
  a final group of 2 digits uses 7 bits, of 1 digit uses 4 bits.
* Alphanumeric: pairs of characters, `45*first + second` in 11 bits; a final
  single character in 6 bits.
* Byte: each byte in 8 bits.

All values are written most-significant bit first.

Data bit length is therefore `10*(n div 3) + {0,4,7}[n mod 3]` (numeric),
`11*(n div 2) + 6*(n mod 2)` (alphanumeric) or `8*n` (byte).

### 3. Version selection

Let `C(v, ecl)` be the number of data codewords (see section 5). The stream
needs `4 + cc(mode, v) + databits` bits. Choose the smallest version `v` in
1..40 with `4 + cc(mode, v) + databits <= 8*C(v, ecl)`. Note that the
character-count width depends on `v`, so the check must be done per version.

### 4. Terminator and padding

After the segment, append a terminator of `min(4, 8*C - length)` zero bits.
Then append zero bits (0 to 7 of them) so the length is a multiple of 8 -- if
it already is, append nothing. Then append the pad codewords `0xEC` and
`0x11` alternately (starting with `0xEC`) until there are exactly `C` data
codewords.

### 5. Codeword counts

Total codewords in a version: `raw(v) div 8` where

    raw(v) = (16*v + 128)*v + 64
    if v >= 2:  a = v div 7 + 2;  raw -= (25*a - 10)*a - 55
    if v >= 7:  raw -= 36

(`raw(v)` is the number of modules available for data, 8 per codeword; the
`raw mod 8` remainder bits are placed as light modules.)

Error correction codewords per block `E[ecl][v]` and number of blocks
`B[ecl][v]`, versions 1..40:

    E[L] = 7 10 15 20 26 18 20 24 30 18 20 24 26 30 22 24 28 30 28 28 28 28 30 30 26 28 30 30 30 30 30 30 30 30 30 30 30 30 30 30
    E[M] = 10 16 26 18 24 16 18 22 22 26 30 22 22 24 24 28 28 26 26 26 26 28 28 28 28 28 28 28 28 28 28 28 28 28 28 28 28 28 28 28
    E[Q] = 13 22 18 26 18 24 18 22 20 24 28 26 24 20 30 24 28 28 26 30 28 30 30 30 30 28 30 30 30 30 30 30 30 30 30 30 30 30 30 30
    E[H] = 17 28 22 16 22 28 26 26 24 28 24 28 22 24 24 30 28 28 26 28 30 24 30 30 30 30 30 30 30 30 30 30 30 30 30 30 30 30 30 30

    B[L] = 1 1 1 1 1 2 2 2 2 4 4 4 4 4 6 6 6 6 7 8 8 9 9 10 12 12 12 13 14 15 16 17 18 19 19 20 21 22 24 25
    B[M] = 1 1 1 2 2 4 4 4 5 5 5 8 9 9 10 10 11 13 14 16 17 17 18 20 21 23 25 26 28 29 31 33 35 37 38 40 43 45 47 49
    B[Q] = 1 1 2 2 4 4 6 6 8 8 8 10 12 16 12 17 16 18 21 20 23 23 25 27 29 34 34 35 38 40 43 45 48 51 53 56 59 62 65 68
    B[H] = 1 1 2 4 4 4 5 6 8 8 11 11 16 16 18 16 19 21 25 25 25 34 30 32 35 37 40 42 45 48 51 54 57 60 63 66 70 74 77 81

Data codewords `C(v, ecl) = raw(v) div 8 - E*B`. Examples: v1-L 19, v1-M 16,
v1-Q 13, v1-H 9, v40-L 2956, v40-H 1276. Resulting maximum capacities at v40
are 7089 digits / 4296 alphanumeric / 2953 bytes at L and 3057 / 1852 / 1273
at H.

### 6. Error correction and interleaving

Let `T = raw(v) div 8`, `B` blocks, `E` ECC codewords per block. The first
`B - (T mod B)` blocks are "short" with `T div B - E` data codewords; the
remaining blocks have one more data codeword. Blocks take consecutive data
codewords in order.

Reed-Solomon over GF(2^8) with primitive polynomial `x^8+x^4+x^3+x^2+1`
(0x11D): field elements are bytes, addition and subtraction are both XOR, and
multiplication is carry-less polynomial multiplication reduced modulo 0x11D.
The generator element is 2, and `2^i` below means the `i`-th power of 2 in
this field (2^0 = 1, 2^1 = 2, ..., 2^8 = 0x1D, ...), not an integer power.
The generator polynomial of degree `E` is `prod_{i=0}^{E-1} (x - 2^i)`
(equivalently `(x + 2^i)`, since subtraction is XOR). A block's ECC
codewords are the coefficients of the remainder of `data(x) * x^E` divided by
the generator, highest degree first (the standard systematic RS encoding; data
codeword 0 is the highest-degree coefficient).

Final sequence: all blocks' data codewords interleaved (first codeword of
block 0, first of block 1, ..., then second codewords, ...; short blocks are
simply skipped at the last data position), followed by all blocks' ECC
codewords interleaved the same way.

### 7. Function patterns

Size `n = 4v + 17`. Dark = 1.

* **Finder patterns** centred at (3,3), (n-4,3), (3,n-4): a module at
  Chebyshev distance `d` from the centre is dark for `d` in {0,1,3}, light
  for `d` in {2,4} (`d = 4` is the separator). Clip to the symbol.
* **Timing patterns**: row 6 and column 6 between the separators, i.e.
  modules `(i,6)` and `(6,i)` for `8 <= i <= n-9`, dark iff `i` is even. (The
  parts of row 6 and column 6 with `i < 8` or `i > n-9` lie inside the finder
  patterns and their separators, whose values above take precedence.)
* **Alignment patterns** (v >= 2): 5x5, dark at Chebyshev distance 0 and 2
  from the centre, light at distance 1. Centres are every pair `(px, py)`
  from the position list below, except the three that would overlap the
  finder patterns: `(px, py)` = (first, first) (top-left), (last, first)
  (top-right) and (first, last) (bottom-left). `(last, last)` is kept.

      v2: 6 18            v3: 6 22            v4: 6 26            v5: 6 30
      v6: 6 34            v7: 6 22 38         v8: 6 24 42         v9: 6 26 46
      v10: 6 28 50        v11: 6 30 54        v12: 6 32 58        v13: 6 34 62
      v14: 6 26 46 66     v15: 6 26 48 70     v16: 6 26 50 74     v17: 6 30 54 78
      v18: 6 30 56 82     v19: 6 30 58 86     v20: 6 34 62 90     v21: 6 28 50 72 94
      v22: 6 26 50 74 98  v23: 6 30 54 78 102 v24: 6 28 54 80 106 v25: 6 32 58 84 110
      v26: 6 30 58 86 114 v27: 6 34 62 90 118 v28: 6 26 50 74 98 122
      v29: 6 30 54 78 102 126   v30: 6 26 52 78 104 130   v31: 6 30 56 82 108 134
      v32: 6 34 60 86 112 138   v33: 6 30 58 86 114 142   v34: 6 34 62 90 118 146
      v35: 6 30 54 78 102 126 150   v36: 6 24 50 76 102 128 154
      v37: 6 28 54 80 106 132 158   v38: 6 32 58 84 110 136 162
      v39: 6 26 54 82 110 138 166   v40: 6 30 58 86 114 142 170

  Alignment patterns overwrite timing-pattern modules where they cross them
  (the values coincide anyway).
* **Dark module**: `(8, n-8)` is always dark.
* **Format information** (15 bits, section 9) and, for v >= 7, **version
  information** (18 bits, section 8) occupy reserved areas.

All of the above modules (including the reserved format and version areas)
are *function modules*: they are never masked and never hold data.

### 8. Version information (v >= 7)

`bits = (v << 12) | rem` where `rem` starts as `v` and, 12 times, is updated
`rem = (rem << 1) ^ ((rem >> 11) * 0x1F25)`. For `i` in 0..17, bit `i`
(least significant = 0) is placed at `(n-11 + i mod 3, i div 3)` and at the
transposed position `(i div 3, n-11 + i mod 3)`.

### 9. Format information

`data = (ecl_bits << 3) | mask` with `ecl_bits`: L=1, M=0, Q=3, H=2.
`rem` starts as `data` and, 10 times, `rem = (rem << 1) ^ ((rem >> 9) * 0x537)`.
`bits = ((data << 10) | rem) ^ 0x5412`. With `bit(i)` = bit `i` of `bits`:

* Around the top-left finder: `(8, i)` = bit(i) for i in 0..5; `(8,7)` =
  bit(6); `(8,8)` = bit(7); `(7,8)` = bit(8); `(14-i, 8)` = bit(i) for i in
  9..14.
* Second copy: `(n-1-i, 8)` = bit(i) for i in 0..7; `(8, n-15+i)` = bit(i)
  for i in 8..14.

### 10. Data placement

Walk column pairs from the right: `right = n-1, n-3, ...` down to 1, but when
`right == 6` use `right = 5` instead (column 6 is the timing column and is
skipped entirely, so the pairs left of it are columns (5,4), (3,2), (1,0)).
For each pair, the direction is upward when `((right + 1) & 2) == 0`,
otherwise downward, where `right` is the value after the `6 -> 5`
substitution (both 6 and 5 give "downward", so this is the usual zigzag: the
rightmost pair goes up, the next goes down, and so on, with the pairs left of
the timing column continuing the alternation as if column 6 did not exist). Traverse rows in that direction; at each row visit
`x = right` then `x = right - 1`. Every non-function module visited receives
the next bit of the final codeword sequence (MSB of codeword 0 first). When
the bits are exhausted, remaining modules stay light (these are the
`raw(v) mod 8` remainder bits).

### 11. Masking

Mask `m` inverts every non-function module `(x, y)` where the condition holds:

    0: (x + y) mod 2 == 0
    1: y mod 2 == 0
    2: x mod 3 == 0
    3: (x + y) mod 3 == 0
    4: (x div 3 + y div 2) mod 2 == 0
    5: (x*y) mod 2 + (x*y) mod 3 == 0
    6: ((x*y) mod 2 + (x*y) mod 3) mod 2 == 0
    7: ((x + y) mod 2 + (x*y) mod 3) mod 2 == 0

For a fixed mask, apply it and write that mask's format information.

### 12. Automatic mask selection (`auto`)

For each mask 0..7, produce the complete symbol (mask applied, format
information for that mask written, version information present) and compute
the penalty below. Choose the mask with the lowest penalty; on a tie, the
lowest mask number (ties do occur; the tests exercise them). The penalty is
evaluated on the full symbol including finder, timing, alignment, format and
version modules.

* **N1** -- for every row and every column, every maximal run of 5 or more
  consecutive same-coloured modules adds `3 + (run_length - 5)`.
* **N2** -- every 2x2 block of same-coloured modules adds 3. Blocks overlap:
  a solid 3x3 area contains four 2x2 blocks and adds 12.
* **N3** -- for every row and every column, every position where the 11
  consecutive modules equal `#.###.#....` (dark, light, dark, dark, dark,
  light, dark, then four light) or `....#.###.#` adds 40. Each of the two
  patterns is counted independently, so `....#.###.#....` adds 80. Only
  windows lying entirely inside the symbol count; the area outside the symbol
  is not treated as light.
* **N4** -- with `dark` the number of dark modules and `total = n*n`:
  `k = |20*dark - 10*total| div total` (integer division, rounding down), add
  `10*k`. This is the number of complete 5% steps by which the dark proportion
  deviates from 50%: a deviation in `[5%, 10%)` gives `k = 1`, in
  `[10%, 15%)` gives `k = 2`, and so on. Note the lower bound is inclusive:
  a symbol with exactly 60% dark modules (possible when `n` is a multiple of
  5, e.g. 375 of 625 at version 2) has `k = 2`. Some encoders use
  `ceil(deviation / 5%) - 1` instead, which gives `k = 1` there; that is
  wrong for this problem.

## Worked examples

### Example 1

Input:

    M 0 HELLO WORLD

`HELLO WORLD` is alphanumeric (11 characters), version 1-M (16 data
codewords). Data codewords: `32 91 11 120 209 114 220 77 67 64 236 17 236 17
236 17`; ECC codewords: `196 35 39 119 235 215 231 226 93 23`. Output:

    version 1 mask 0
    #######...#.#.#######
    #.....#.###...#.....#
    #.###.#...#.#.#.###.#
    #.###.#...#.#.#.###.#
    #.###.#.#.###.#.###.#
    #.....#..###..#.....#
    #######.#.#.#.#######
    .....................
    #.#.#.#..#..#...#..#.
    .####...#..#....#...#
    ...#######.#..#.##...
    ####.#.##..###.#.###.
    .#..####.#.#..###.#.#
    ........#.#...#...#.#
    #######.....#..#.##..
    #.....#..##...##.#...
    #.###.#.##..#.#######
    #.###.#...##.#.#...#.
    #.###.#.####.###.#..#
    #.....#....###...#.##
    #######.##.#.###....#
    
(followed by the empty line). With `M auto HELLO WORLD` the penalties for
masks 0..7 are 311, 406, 442, 463, 367, 528, 395, 445, so the output is the
same with `mask 0`.

### Example 2

Input:

    L auto 01234567

Numeric mode, version 1-L. Output:

    version 1 mask 3
    #######.##..#.#######
    #.....#..#..#.#.....#
    #.###.#.#.#.#.#.###.#
    #.###.#.#..#..#.###.#
    #.###.#.###...#.###.#
    #.....#.......#.....#
    #######.#.#.#.#######
    .........##..........
    ####..#.#.#..#..###.#
    ####...##...#..#.##..
    ....######..#####..#.
    ##..#..##.#.##...#.#.
    #..#..##..##.#..#....
    ........##...#.#....#
    #######..##..##.#.##.
    #.....#....####...#.#
    #.###.#..#.#..#.....#
    #.###.#.#....#..#.##.
    #.###.#.#..#.#..#.#..
    #.....#.##.##.#.##.##
    #######.##.##..#...#.
    

### Example 3

Input:

    H 5 héllo

`h`, `é` (2 bytes), `l`, `l`, `o` = 6 bytes, byte mode, version 1-H
(9 data codewords). Output:

    version 1 mask 5
    #######.####..#######
    #.....#..##.#.#.....#
    #.###.#.#.#...#.###.#
    #.###.#..#....#.###.#
    #.###.#.#.#...#.###.#
    #.....#..##...#.....#
    #######.#.#.#.#######
    ........#.#..........
    .....##...#.#.#.#.#.#
    .#####.......#..#.#.#
    .####.#####..#..##.##
    .##.##.#..#.#...#....
    #..#.###.#....#..#.#.
    ........#.####......#
    #######..##..###.###.
    #.....#.#..##.##.##..
    #.###.#.....##..#..#.
    #.###.#..##.##..##...
    #.###.#.........#####
    #.....#...#.#.#..##..
    #######...#.#.#.#..#.
    

## Input sizes

The largest tests contain up to 100 queries, many at version 40 (177x177
modules) with `auto` masking, i.e. eight full penalty evaluations per query.
