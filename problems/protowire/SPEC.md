# protowire — Protobuf-style wire codec

Read a message schema and a list of requests from stdin. Each request either
decodes a hex-encoded byte string into a canonical text form or encodes a
text form into hex, using the Protocol Buffers wire format (proto3
semantics) as specified below. Print one output line per request.

All input is UTF-8 text with LF line endings. Output is UTF-8 with LF line
endings. Exit code is always 0; a malformed request is a normal result whose
output line is `error`, never a crash. stderr is ignored.

## Input

```
<schema>
--
<request>
<request>
...
```

The schema is everything before the first line consisting exactly of `--`.
Every line after that separator is one request. There are no blank request
lines. The final request line may or may not end with `\n`.

### Schema

The schema is a sequence of message definitions:

```
message <Name> { <field> <field> ... }
field := [repeated] <type> <name> = <number> ;
```

Tokenization: the four characters `{` `}` `;` `=` are single-character
tokens; every other token is a maximal run of `[A-Za-z0-9_]`; whitespace
(space, tab, CR, LF) separates tokens and is otherwise ignored. Definitions
may be written on one line (`message A { int32 x = 1; }`) or across many
lines, and punctuation need not be surrounded by whitespace
(`message A{int32 x=1;}` is valid).

- `<type>` is one of the scalar types `int32 int64 uint32 uint64 sint32
  sint64 bool fixed32 fixed64 sfixed32 sfixed64 string bytes`, or the name of
  a message defined anywhere in the schema (before or after this one,
  including the message being defined — recursive types are allowed).
- `repeated <type>` declares a repeated field (a list of zero or more
  values). There are no other modifiers (no `optional`, `oneof`, `map`,
  `enum`, `package`, `import`, comments, or options).
- Message names and field names match `[A-Za-z_][A-Za-z0-9_]*` and are
  never `message`, `repeated` or a scalar type name. Message names are
  unique in the schema; field names and field numbers are unique within a
  message. Field numbers are decimal integers in `1..536870911`
  (never in `19000..19999`). Fields are not necessarily listed in
  field-number order.
- The schema is guaranteed well-formed; implementations need not validate
  it. A schema may contain up to 50 messages with up to 64 fields each.

### Requests

```
decode <Name> <hex>
encode <Name> <text>
```

`<Name>` is always a message defined in the schema. Tokens on a request
line are separated by single spaces. Request lines never start with a
space.

- `<hex>` is a string of lowercase hex digits `0-9a-f` encoding the bytes to
  decode. When there are no bytes the line is exactly `decode <Name>`
  (nothing at all after the name). Anything else after `<Name>` is an
  `error`: a trailing space (`decode <Name> `), an odd number of hex
  digits, a character that is not a hex digit (uppercase digits included),
  or anything after the hex string such as a second space followed by more
  text.
- `<text>` is everything after the single space that follows `<Name>`, up
  to the end of the line; it may contain spaces inside string literals. It
  must be one text-form message (grammar below); in particular an empty or
  all-spaces `<text>` (the line `encode <Name>` or `encode <Name> `) is an
  `error`.

## Wire format

A message is a sequence of fields, each a **tag** followed by a value. The
byte string for a message is the concatenation of its encoded fields.

**Varint**: base-128 little-endian. Each byte holds 7 bits of the value,
least-significant group first; bit 7 is set on every byte except the last.
A varint may be at most **10 bytes**; a value is the sum of the 7-bit groups
shifted into place, taken modulo 2^64 (bits beyond bit 63 of the 10th byte
are discarded, so `ff ff ff ff ff ff ff ff ff 7f` decodes to 2^64−1 and
`80 80 80 80 80 80 80 80 80 02` decodes to 0). Non-minimal encodings such
as `81 00` (value 1) are accepted on decode. When encoding, a varint is
always minimal: the fewest bytes that hold the value, so 0 is the single
byte `00`, 1 is `01`, 300 is `ac 02`, and 2^64−1 is
`ff ff ff ff ff ff ff ff ff 01`.

**Tag** = varint of `(field_number << 3) | wire_type`. On decode a tag must
occupy at most **5 bytes** and its value must be less than 2^32; the field
number must be at least 1; the wire type must be one of 0, 1, 2, 3, 5 (4 is
only valid inside a group, see below). Anything else is an `error`.

| wire type | name | payload |
|---|---|---|
| 0 | varint | one varint |
| 1 | fixed64 | 8 bytes |
| 2 | length-delimited | varint length, then that many bytes |
| 3 | start group | fields until the matching end group |
| 4 | end group | nothing |
| 5 | fixed32 | 4 bytes |

**Length prefix**: a varint of at most **5 bytes** (a 6th byte, i.e. a 5th
byte with bit 7 set, is an `error`), whose value must not exceed the number
of bytes remaining in the enclosing message; otherwise `error`.

### Scalar encodings

| type | wire type | value encoding |
|---|---|---|
| int32, int64 | 0 | varint of the value as a 64-bit two's complement integer (so −1 is 10 bytes `ff ff ff ff ff ff ff ff ff 01`) |
| uint32, uint64 | 0 | varint of the value |
| sint32 | 0 | varint of zigzag32(v) = `((v << 1) ^ (v >> 31)) & 0xffffffff` (arithmetic shift) |
| sint64 | 0 | varint of zigzag64(v) = `((v << 1) ^ (v >> 63)) & 0xffffffffffffffff` |
| bool | 0 | varint 1 for true (0 for false, which is never encoded) |
| fixed32, sfixed32 | 5 | 4 bytes little-endian (two's complement for sfixed32) |
| fixed64, sfixed64 | 1 | 8 bytes little-endian (two's complement for sfixed64) |
| string | 2 | length, then the UTF-8 bytes |
| bytes | 2 | length, then the bytes |
| message | 2 | length, then the encoded sub-message |

Zigzag: 0→0, −1→1, 1→2, −2→3, 2→4, …, −2^31→2^32−1 (sint32),
−2^63→2^64−1 (sint64).

### Decoding rules

Decoding processes the bytes of a message from start to end. Each field
occurrence is interpreted by looking up its field number in the message's
schema:

- **Unknown field number**: the field is skipped according to its wire
  type (its payload is not validated beyond what skipping requires; a
  length-delimited payload's bytes are never inspected). The limits above
  still apply while skipping: a varint of more than 10 bytes, a tag of
  more than 5 bytes or ≥ 2^32, a length prefix of more than 5 bytes or
  exceeding the remaining bytes, and truncated fixed-size data are all an
  `error` whether the field is known or unknown, at message level or
  inside a group.
- **Known field, wrong wire type**: if the wire type is not the one the
  field's type uses (per the table above), and is not wire type 2 on a
  repeated numeric field (packed, below), the occurrence is treated exactly
  like an unknown field and skipped. It is *not* an error.
- **Groups** (wire type 3): skipped. The group's body is a sequence of
  fields, each read with the same tag rules and skipped by wire type
  (groups may nest), until a tag with wire type 4 is found at the group's
  level. That end-group tag must carry the same field number as the start
  tag; a different number, an end-group tag outside any group, or data that
  ends before the group is closed, is an `error`. The tag rules apply
  unchanged inside a group: a field number of 0 or a wire type of 6 or 7
  anywhere is an `error`. (Tests never place a field-number-0 tag inside a
  group; implementations may still treat it as an error.)
- **Value conversion** for varint fields: let `v` be the decoded varint
  (0 ≤ v < 2^64).
  - int32: take the low 32 bits of `v`, interpret as two's complement.
  - int64: interpret `v` as two's complement (v ≥ 2^63 is negative).
  - uint32: the low 32 bits of `v`. uint64: `v`.
  - sint32: take the low 32 bits of `v`, then unzigzag: `(u >> 1) ^ -(u & 1)`.
  - sint64: unzigzag `v`.
  - bool: true if `v != 0`, else false (so `02` decodes as true).
- **string**: the payload bytes must be valid UTF-8 (RFC 3629: no overlong
  forms, no surrogates U+D800–U+DFFF, nothing above U+10FFFF, no truncated
  sequences); otherwise the whole request is an `error`. NUL bytes are
  allowed. **bytes**: anything.
- **Singular fields**: a later occurrence of a scalar field replaces the
  earlier value. Multiple occurrences of a singular *message* field are
  **merged**: the later payload is decoded into the same sub-message, so
  its scalars replace, its repeated fields append, and its sub-messages
  merge recursively.
- **Repeated fields**: each occurrence appends, in stream order. A repeated
  numeric field (every type except string, bytes and message) may arrive
  **packed**: wire type 2 with a length prefix followed by the elements'
  value encodings back to back, with no tags; or **unpacked**: one
  occurrence with the type's own wire type per element; or any mix of the
  two. A packed payload of a fixed32/fixed64 type whose length is not a
  multiple of 4/8 is an `error`; a packed varint payload that ends in the
  middle of a varint is an `error`. A packed payload may be empty (length
  0), contributing no elements. Repeated string/bytes/message fields are
  never packed: every wire-type-2 occurrence is exactly one element.
- **Sub-messages** are decoded eagerly with the same rules; an error inside
  a sub-message is an error for the request. Truncated data anywhere (a
  varint or fixed value cut short, a length exceeding the remaining bytes)
  is an `error`.
- Presence: a scalar field is *present* if any occurrence was decoded, but
  its text form is emitted only if the value is not the default (see
  Canonical text). A singular message field is present if any occurrence
  was decoded, even one with an empty payload. Unknown fields are dropped.

### Encoding rules (canonical form)

The encoding of a message is deterministic:

- Fields are emitted in **increasing field-number order**.
- A singular scalar field whose value is the default (integer 0, `false`,
  empty string, empty bytes) is **omitted entirely**.
- A singular message field is emitted (tag + length + body) whenever it is
  present, including when its body is empty (`tag 00`). Absent message
  fields are omitted.
- A repeated field with zero elements is omitted. A repeated numeric field
  is always emitted **packed**: one tag with wire type 2, the length of the
  concatenated element encodings, then the elements (default values such as
  0 are still emitted as elements). Repeated string/bytes/message fields
  emit one tag+length+payload per element, in order.
- Every varint (tags, lengths, values) is minimal.

The output of `encode` is the lowercase hex of these bytes on one line. An
empty encoding (for example `encode M {}` where M has no present fields)
produces an **empty line**.

## Canonical text form

```
message := "{" [ field ( ", " field )* ] "}"
field   := name ": " value
value   := integer | "true" | "false" | string | bytes | message | list
list    := "[" [ value ( ", " value )* ] "]"
```

- `decode` prints exactly this canonical form: fields in increasing
  field-number order, `: ` after the name, `, ` between fields and between
  list elements, no other whitespace. Only present, non-default fields
  appear: a scalar equal to its default is omitted; a repeated field with
  no elements is omitted; a present message field is printed even if empty
  (`d: {}`). An empty message prints as `{}`.
- **integer**: decimal, no leading zeros, no `+`, `-` only for negative
  values. int32/int64/sint32/sint64/sfixed32/sfixed64 print signed;
  uint32/uint64/fixed32/fixed64 print unsigned (fixed32 `ff ff ff ff` prints
  `4294967295`, sfixed32 `ff ff ff ff` prints `-1`).
- **bool**: `true` or `false` (only `true` ever appears in decode output
  for singular fields; lists may contain `false`). Lists likewise print
  every element, including `0`, `""` and `x""`.
- **string**: `"` + characters + `"`. Exactly these are escaped: `"` → `\"`,
  `\` → `\\`, LF → `\n`, CR → `\r`, TAB → `\t`, every other code point
  below U+0020 and U+007F → `\xHH` with two lowercase hex digits
  (`\x00`, `\x1f`, `\x7f`). Everything else, including all non-ASCII
  characters, is written raw as UTF-8.
- **bytes**: `x"` + lowercase hex of the bytes + `"`, e.g. `x"00ff"`; a
  list element with no bytes is `x""`.
- **message**: nested `{...}`. **list**: `[...]`, elements in order.

### Text accepted by `encode`

The `encode` text follows the grammar above with these relaxations, all of
which must be accepted:

- Any number of spaces (0x20 only) may appear between tokens, or none
  (`{a:1,c:[1,2]}` and `{ a : 1 }` are valid), including before the
  opening `{` and after the closing `}`. Spaces are not allowed inside a
  token (`- 1`, `x "00"`, `tr ue` are errors), and no other whitespace
  character (tab etc.) may appear outside a string literal.
- Fields may appear in any order.
- A field may be given its default value explicitly (`a: 0`, `s: ""`,
  `y: x""`, `b: false`, `c: []`); it encodes exactly as if absent. `d: {}`
  is *not* absent: it encodes the empty sub-message.
- In string literals the escapes `\"` `\\` `\n` `\r` `\t` and `\xHH` (hex
  digits in either case, any byte value 00–ff) are accepted; `\xHH` denotes
  one byte, so `"\xc3\xa9"` is the same as `"é"`. Any other character
  after `\` is an error. Raw non-ASCII characters are accepted, and so is
  a raw DEL (0x7f). A raw byte below 0x20 inside a literal is an error.
  After unescaping, the byte string must be valid UTF-8, else `error`.
- Bytes literals accept only lowercase hex digits, an even number of them.

Everything else is an `error`: unknown field name; the same field name
given twice; a value of the wrong kind for the field's type (a list for a
singular field or vice versa, a string for an integer, `{}` for a scalar,
an integer for a string, `0`/`1` or a string for a bool, …); an integer
outside the type's range (int32 and
sint32 and sfixed32: −2^31..2^31−1; int64, sint64, sfixed64: −2^63..2^63−1;
uint32, fixed32: 0..2^32−1; uint64, fixed64: 0..2^64−1); a negative sign on
an unsigned type; `-0`; leading zeros (`007`); `+5`; `1.0`; `True`;
missing or extra commas, brackets, quotes or colons; trailing text after
the closing `}`.

## Limits

- Nesting depth of messages (in the schema's recursion, in decode payloads,
  in encode text) and of groups never exceeds 64.
- The largest tests contain single payloads of about 0.6 MB (1.2 MB of
  hex), messages with 100,000 repeated elements (packed and unpacked, and
  as a 2 MB encode text), a 10,000-element repeated message field, and a
  file with 20,000 small requests. Total input per test is under 6 MB and
  the expected output is of similar size.

## Worked examples

Input:
```
message Inner { sint32 v = 1; }
message Outer {
  int32 a = 1;
  string b = 2;
  repeated int32 c = 3;
  Inner d = 4;
}
--
encode Outer {a: 1, b: "x", c: [1, 2], d: {v: -5}}
decode Outer 08011201781a02010222020809
encode Outer {d: {}, c: [], a: 0}
decode Outer 3800
decode Outer 08ff
```
Output:
```
08011201781a02010222020809
{a: 1, b: "x", c: [1, 2], d: {v: -5}}
2200
{}
error
```
Line 1: `08 01` is field 1, varint 1; `12 01 78` is field 2, length 1,
`x`; `1a 02 01 02` is field 3 packed (two one-byte varints); `22 02 08 09`
is field 4, length 2, whose body is Inner's field 1 with zigzag(−5) = 9.
Line 3: `a: 0` and `c: []` are defaults and vanish, `d: {}` is a present
empty sub-message: tag `22`, length `00`. Line 4: `38` is field 7, which
Outer does not have, so the varint `00` is skipped and nothing remains.
Line 5: `ff` has its continuation bit set and no byte follows.

Input:
```
message M { uint64 u = 1; sint64 s = 2; fixed32 f = 3; bytes y = 4; repeated bool bs = 5; bool k = 6; }
--
decode M 08ffffffffffffffffff0110ff011dffffffff2202000f2a03010001
decode M 3002
decode M 3d000000
encode M {k: true, y: x"cafe", s: -128, u: 18446744073709551615}
encode M {u: -1}
```
Output:
```
{u: 18446744073709551615, s: -128, f: 4294967295, y: x"000f", bs: [true, false, true]}
{k: true}
error
08ffffffffffffffffff0110ff012202cafe3001
error
```
Line 2: bool from varint 2 is `true`. Line 3: `3d` is field 7 (unknown)
with wire type 5, which needs 4 bytes but only 3 follow. Line 4: fields are
re-ordered by number; `s: -128` is zigzag 255 = `ff 01`. Line 5: a
negative value for an unsigned type.

Input (merging, unpacked repeated, groups, string escaping):
```
message P { repeated int32 r = 1; P p = 2; string s = 3; }
--
decode P 0801080212020803120208041a0322095c
decode P 1b08011c0805
decode P 1b08011400
```
Output:
```
{r: [1, 2], p: {r: [3, 4]}, s: "\"\t\\"}
{r: [5]}
error
```
Line 1: two unpacked `r` elements (`08 01`, `08 02`), then field 2 twice
(`12 02 08 03`, `12 02 08 04`, merged so the sub-message's `r` list gets
both elements), then `s` whose bytes `22 09 5c` are `"`, TAB, `\`, printed
with escapes. Line 2: `1b` is field 3 with wire type 3, a group (`s` uses
wire type 2, so this is treated as unknown), containing `08 01` and closed
by `1c` (field 3, wire type 4); then `08 05` is a real element of `r`.
Line 3: the end-group tag `14` carries field number 2, not 3.

These examples are the first three tests in `tests/`.
