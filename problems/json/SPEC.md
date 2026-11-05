# json — JSON parser and canonical serializer

Read one JSON document from stdin. If it is not a valid document under the
rules below, print exactly `invalid`. Otherwise print its canonical
serialization. Either way the output is a single line terminated by `\n`
(LF, byte 0x0A), with no BOM and nothing else on stdout, and the exit code
is 0 in both cases (an invalid document is a normal result, not an error).
stderr is ignored.

Write the JSON parser and serializer yourself: don't use a JSON parser or
serializer from a library, the standard library or the language.

## Input

- The **entire** stdin is the document. It is a sequence of bytes.
- The bytes must be valid UTF-8 (RFC 3629): no overlong encodings, no
  encoded surrogates (U+D800–U+DFFF), no code points above U+10FFFF, no
  truncated sequences. Any violation anywhere in the input makes the whole
  document `invalid`.
- A leading byte-order mark (EF BB BF) is **not** allowed: it is `invalid`.
- Empty input, or input containing only whitespace, is `invalid`.
- Input size is at most 2,000,000 bytes (at most 24,000,000 bytes in the
  long benchmark tier, `bench-long/`).
- Validity is a property of the **whole** document. Every byte is checked,
  including values that are later discarded because a duplicate key
  overrides them: `{"a":"\uD800","a":1}`, `{"a":[1,],"a":1}` and an
  over-deep value under a key that is later repeated are all `invalid`.

## Grammar (RFC 8259)

```
document = ws value ws
value    = object | array | string | number | "true" | "false" | "null"
object   = "{" ws "}" | "{" member ( "," member )* "}"
member   = ws string ws ":" value
array    = "[" ws "]" | "[" value ( "," value )* "]"
ws       = ( " " | "\t" | "\n" | "\r" )*
```

- Any value may appear at top level (a bare number, string, literal, array or
  object). Exactly one value; anything other than whitespace after it is
  `invalid`.
- Whitespace is exactly the four characters space (0x20), tab (0x09),
  LF (0x0A), CR (0x0D). Anything else outside a string is `invalid`,
  including form feed (0x0C), vertical tab (0x0B), NUL (0x00), NEL (U+0085),
  NBSP (U+00A0), U+2028 and a trailing NUL byte after the value. Do not use a
  Unicode-aware `isspace`.
- Literals `true`, `false`, `null` are case-sensitive. `True`, `NaN`,
  `Infinity`, `-Infinity`, `nul` are `invalid`.
- Trailing commas (`[1,]`, `{"a":1,}`), leading commas, missing commas,
  missing colons, comments, single-quoted strings, unquoted keys and
  non-string keys are all `invalid`.

### Strings

```
string = '"' char* '"'
char   = any Unicode scalar value except '"', '\' and U+0000–U+001F
       | '\"' | '\\' | '\/' | '\b' | '\f' | '\n' | '\r' | '\t'
       | '\u' hex hex hex hex
```

- Raw (unescaped) control characters U+0000–U+001F inside a string are
  `invalid` (this includes a literal tab or newline). U+007F (DEL) and all
  non-ASCII characters may appear raw.
- `\uXXXX` hex digits may be upper or lower case but must be ASCII
  (`0-9A-Fa-f`); fullwidth or other Unicode digits are `invalid`.
- A backslash as the last byte of the input (`["\`) is `invalid`, like any
  other unterminated string.
- An escaped high surrogate `\uD800`–`\uDBFF` must be **immediately**
  followed by an escaped low surrogate `\uDC00`–`\uDFFF`; the pair decodes
  to one supplementary code point. A high surrogate followed by anything
  else (`\uD800\u0041`, `\uD800\uE000`, `\uD800\uDBFF`, a raw character,
  the closing quote), or a lone low surrogate, is `invalid`. The rule is the
  same inside object keys. A raw (unescaped) low surrogate cannot occur
  because it is not valid UTF-8.
- Any other character after a backslash (`\x`, `\U`, `\'`, `\0`, a truncated
  `\u12`) is `invalid`.

### Numbers

```
number   = "-"? int frac? exp?
int      = "0" | [1-9] [0-9]*
frac     = "." [0-9]+
exp      = ("e" | "E") ("+" | "-")? [0-9]+
```

Leading zeros (`01`), a leading `+`, `-` alone, `1.`, `.5`, `1e`, `1e+`,
`1E+-5`, `1e5e5`, hex (`0x1`) are `invalid`. No whitespace may appear inside
a number: `- 1` and `1 .5` are `invalid`. Digits are ASCII `0`–`9` only;
other Unicode digits (e.g. U+0662 ARABIC-INDIC DIGIT TWO, U+00B2 SUPERSCRIPT
TWO, U+FF11 FULLWIDTH DIGIT ONE) are `invalid`, so do not use a
Unicode-aware `isdigit`. Integers may be of any size (hundreds of digits);
implementations must not reject or round them. The digit strings of `int`,
`frac` and `exp` may each be arbitrarily long.

## Output

If the document is invalid: the line `invalid`.

Otherwise the canonical serialization of the document, as UTF-8, followed by
a single `\n`. The canonical form contains no whitespace outside strings and
is defined per value type:

- `true`, `false`, `null`: as-is.
- **Array**: `[` + elements in original order joined by `,` + `]`. Empty
  array is `[]`.
- **Object**: `{` + members joined by `,` + `}`, each member as
  `key:value` with the key serialized as a string. Empty object is `{}`.
  - **Duplicate keys**: keys are compared by their decoded value (`"a"` and
    `"a"` are the same key). When a key appears more than once, the
    object keeps that key exactly once with the value of its **last**
    occurrence.
  - **Ordering**: members are sorted by key in ascending lexicographic order
    of their **UTF-16 code unit** sequences (compare unit by unit as
    unsigned 16-bit integers; a proper prefix sorts first). For characters in
    the Basic Multilingual Plane this equals code point order, but
    supplementary characters (U+10000 and above, encoded as surrogate pairs
    0xD800–0xDFFF) sort **before** U+E000–U+FFFF. Example ordering:
    `""` < `"Z"` < `"a"` < `"a\u0000"` < `"aa"` < `"é"` < `"😀"` (U+1F600)
    < `"\uE000"` < `"\uFFFF"` (the last two written here as escapes; they
    would be raw in the output). Note this is *not* UTF-8 byte order and
    *not* code point order.
- **String** (values and keys alike): `"` + characters + `"`, where exactly
  these characters are escaped and nothing else:
  - `"` → `\"`, `\` → `\\`
  - U+0008 → `\b`, U+000C → `\f`, U+000A → `\n`, U+000D → `\r`, U+0009 → `\t`
  - every other U+0000–U+001F → `\u00XX` with **lowercase** hex digits
    (e.g. `\u001f`, `\u0000`)
  - everything else, including `/`, U+007F, U+2028 and all non-ASCII
    characters, is emitted raw as UTF-8. Surrogate pairs from the input are
    emitted as the single combined character.
- **Number**: numbers are echoed textually, never converted to floating
  point. Let the input lexeme be `-? int frac? exp?`.
  - If there is no `frac` and no `exp` (an integer lexeme), the output is
    the lexeme exactly as written. `-0` stays `-0`;
    `123456789012345678901234567890` stays as written.
  - Otherwise the output is `-? int frac?` exactly as written, followed by
    the normalized exponent if `exp` was present. The normalized exponent is
    a lowercase `e`, then the exponent digits with leading zeros removed
    (an all-zero exponent becomes the single digit `0`), preceded by `-`
    only if the original exponent was negative **and** nonzero. A `+` sign
    is dropped.
  - Examples: `1.0` → `1.0`; `1.50` → `1.50`; `1E5` → `1e5`; `1e+05` →
    `1e5`; `1e-007` → `1e-7`; `1e-0` → `1e0`; `1E+00` → `1e0`; `-0.0` →
    `-0.0`; `0e0` → `0e0`; `2.5E-000789` → `2.5e-789`.

## Nesting depth

The nesting depth of an array or object is 1 for a top-level array/object
and increases by one for each enclosing array or object. Scalars do not
count. The maximum supported depth is **512**: a document containing an
array or object at depth 513 or more is `invalid`, even if it is otherwise
well-formed and even if that container is empty (`[[...[{}]...]]` with 512
enclosing arrays is `invalid`). Implementations must handle depth 512
correctly (e.g. 512 nested arrays `[[[...]]]`). Inputs such as 100000
unclosed `[` must produce `invalid` without crashing.

## Worked examples

Input:
```
{ "b": [1, 2.50, 1E+3], "a": "héllo\/", "b": null }
```
Output:
```
{"a":"héllo/","b":null}
```
(`b` is duplicated, last wins; keys sorted; `é` emitted raw; `\/` → `/`.)

Input:
```
["😀", -0, 1e-007, 0.0, 1e-0, "tab\tquote\"nul\u0000 A\u0041"]
```
Output:
```
["😀",-0,1e-7,0.0,1e0,"tab\tquote\"nul\u0000 AA"]
```

Input:
```
"\u007f\/\u2028\uD83D\uDE00"
```
Output, shown as hex bytes because it contains characters that are not
printable (DEL raw, `/` unescaped, U+2028 raw, the surrogate pair combined
into the 4-byte UTF-8 sequence for U+1F600, then the newline):
```
22 7f 2f e2 80 a8 f0 9f 98 80 22 0a
```

Input:
```
[1, 2, ]
```
Output:
```
invalid
```

Input:
```
{"\uE000":1,"😀":2,"\uFFFF":3,"Z":4}
```
Output (UTF-16 order: `Z`, then the surrogate pair, then U+E000, then
U+FFFF; the last two keys are emitted raw, so the output is shown as hex):
```
7b 22 5a 22 3a 34 2c 22 f0 9f 98 80 22 3a 32 2c 22 ee 80 80 22 3a 31 2c 22 ef bf bf 22 3a 33 7d 0a
```

## Performance

The largest tests are documents of roughly 1–1.1 MB (deeply nested pretty
printed structures, long strings full of escapes, ~100k numbers, objects
with tens of thousands of keys to sort and deduplicate). A reasonable
implementation in a compiled language should finish every test well under a
second; suggested per-test timeout is 10 seconds. Memory use should stay
under a few hundred MB.
