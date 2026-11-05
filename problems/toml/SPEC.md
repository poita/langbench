# toml — a TOML 1.0.0 parser and serializer

Implement a complete TOML 1.0.0 reader and writer. The program runs in one of
two modes. In **decode** mode it parses a TOML document and prints it as a
*tagged JSON* tree (the interchange format used by the official `toml-test`
suite). In **encode** mode it reads such a tagged JSON tree and prints a
canonical TOML document.

Write the TOML parser and serializer yourself: don't use a TOML implementation
from a library, the standard library or the language. The tagged JSON is only
an interchange format: read and write it with the standard library's JSON
support or with your own code.

The test suite is the official `toml-test` corpus for TOML 1.0.0 (208 valid
documents and 501 invalid ones), plus real `Cargo.toml`, `Cargo.lock` and
`pyproject.toml` files and a set of hand-written cases. Rejecting every
invalid document is as important as parsing every valid one.

## Input

- Line 1 of stdin, terminated by a single `\n` (U+000A), is the **mode**:
  the six bytes `decode` or the six bytes `encode`, with no leading or
  trailing spaces. No other mode occurs.
- Everything after that first `\n` byte is the **document**, verbatim, byte
  for byte. It may contain any bytes at all, including CR, NUL and invalid
  UTF-8 (in decode mode those are among the things you must reject). The
  document may or may not end with a newline. Documents are at most 8 MB (at
  most 20 MB in the long benchmark tier, `bench-long/`).
- In encode mode the document is UTF-8 tagged JSON, always well formed and
  always produced by a successful decode (see *Encode input* below), so no
  error handling is needed there.

## Output

- **decode**: one line — either the tagged JSON described below, or the five
  characters `error` when the document is not valid TOML 1.0.0.
- **encode**: the canonical TOML document described below.
- Output is UTF-8 and ends with a single `\n`. Exit code 0 always; stderr is
  ignored. The runner ignores trailing whitespace at the end of each line and
  trailing newlines at the end of the output.

---

# Part 1 — decode

## 1.1 The tagged JSON format

The decoded document is a tree of three kinds of node:

- a **table** is a JSON object whose members are its keys;
- an **array** is a JSON array of nodes;
- a **value** is a JSON object with exactly two members, `"type"` and
  `"value"`, both JSON strings.

`"type"` is one of `string`, `integer`, `float`, `bool`, `datetime`,
`datetime-local`, `date-local`, `time-local`. `"value"` is always the value
rendered as text — never a JSON number or boolean.

The root of the document is a table, so the output is always a JSON object
(`{}` for an empty document).

There is no ambiguity between a table and a value: every member of a table is
itself an object or an array, never a string, so a table can never have
exactly two string-valued members named `type` and `value`. A TOML table whose
keys happen to be `type` and `value` therefore still decodes unambiguously.

### JSON formatting

The JSON must be **compact and key-sorted**:

- no whitespace anywhere outside string literals — `{"a":1}` not `{ "a": 1 }`,
  `[1,2]` not `[1, 2]`;
- the members of every object are sorted by key, comparing the keys as
  sequences of Unicode code points (so `""` first, `"A"` < `"a"` < `"é"`);
- array element order is the document order and is never sorted.

String escaping in the JSON output: `"` → `\"`, `\` → `\\`, U+0008 → `\b`,
U+000C → `\f`, U+000A → `\n`, U+000D → `\r`, U+0009 → `\t`, every other code
point below U+0020 → `\u00xx` with **lowercase** hex digits. Every other code
point, including U+007F and all non-ASCII code points, is written literally as
UTF-8 (never as a `\u` escape).

### Worked example

Input:

```
decode
name = "Tom"
dob = 1979-05-27T07:32:00-08:00

[db]
ports = [ 8001, 8002 ]
enabled = true

[[fruit]]
name = "apple"

[[fruit]]
name = "banana"
```

Output (one line, wrapped here for readability):

```
{"db":{"enabled":{"type":"bool","value":"true"},"ports":[{"type":"integer",
"value":"8001"},{"type":"integer","value":"8002"}]},"dob":{"type":"datetime",
"value":"1979-05-27T07:32:00-08:00"},"fruit":[{"name":{"type":"string",
"value":"apple"}},{"name":{"type":"string","value":"banana"}}],"name":
{"type":"string","value":"Tom"}}
```

## 1.2 Scalar text forms

### string

The `"value"` member is the string itself, after all escape processing. It is
a sequence of Unicode scalar values (never a surrogate).

### integer

Decimal, with a leading `-` when negative and no other sign, no leading zeros
(except the single digit `0`), no underscores: `0`, `42`, `-17`,
`9223372036854775807`. Integers written in TOML as hex, octal or binary are
printed in decimal.

### bool

Exactly `true` or `false`.

### float

Floats are IEEE-754 binary64. The text form is fixed and mechanical:

- NaN, whatever its sign bit, prints as `nan`;
- +∞ prints as `inf` and −∞ as `-inf`;
- every other value prints as **exactly 17 significant decimal digits in
  scientific notation**: an optional `-` (present exactly when the value is
  negative, negative zero included), one digit, `.`, sixteen digits, `e`, the
  exponent sign (`+` or `-`, always present), and the decimal exponent with at
  least two digits (no leading zeros beyond that).

The digits are the correctly rounded (round-half-to-even) 17-significant-digit
decimal representation of the double. This is exactly what C's
`printf("%.16e", x)` produces on a conforming library; any other conversion
must match it byte for byte, including the always-present exponent sign and
the two-digit minimum exponent width. Subnormals are included: `5e-324`
prints as `4.9406564584124654e-324`.

Examples:

| TOML        | `"value"`                    |
|-------------|------------------------------|
| `1.0`       | `1.0000000000000000e+00`     |
| `3.1415`    | `3.1415000000000002e+00`     |
| `-0.0`      | `-0.0000000000000000e+00`    |
| `0e0`       | `0.0000000000000000e+00`     |
| `1e308`     | `1.0000000000000000e+308`    |
| `6.626e-34` | `6.6259999999999998e-34`     |
| `inf`       | `inf`                        |
| `-nan`      | `nan`                        |

Seventeen significant digits always round-trip, so `encode` can print this
text straight back into the TOML document (see Part 2).

### datetime, datetime-local, date-local, time-local

These four types are handled **textually**: no calendar arithmetic, no time
zone conversion, no truncation of precision. The canonical text is

```
date-local      YYYY-MM-DD
time-local      HH:MM:SS[.frac]
datetime-local  YYYY-MM-DDTHH:MM:SS[.frac]
datetime        YYYY-MM-DDTHH:MM:SS[.frac]OFFSET
```

with these rules:

- the date and time fields are copied from the document unchanged (they are
  always already zero-padded to the widths above, because TOML requires it);
- the separator between date and time is always an uppercase `T`, whatever the
  document used (`T`, `t` or a space);
- `frac` is the fractional-second digits with **trailing zeros removed**; if
  no digits remain, the `.` is dropped too. `.5` stays `.5`, `.600` becomes
  `.6`, `.000` and `.0` disappear entirely. All digits are otherwise kept, at
  any length.
- `OFFSET` is `Z` when the document wrote `Z`, `z`, `+00:00` or `-00:00`, and
  otherwise the offset exactly as written, `+HH:MM` or `-HH:MM`.

Examples: `1987-07-05 17:45:00z` → `1987-07-05T17:45:00Z`;
`1987-07-05T17:45:56.600+08:00` → `1987-07-05T17:45:56.6+08:00`;
`1979-05-27t07:32:00-00:00` → `1979-05-27T07:32:00Z`.

## 1.3 The TOML 1.0.0 grammar

What follows is the whole of TOML 1.0.0, in the order you will need it. When
this section and the published TOML 1.0.0 specification appear to differ, this
section wins; §1.4 lists the places where TOML's own wording leaves a choice.

### Encoding and lines

- The document must be valid UTF-8. Any encoding error — a truncated sequence,
  an overlong form, a byte above the legal range, an encoded surrogate —
  makes the document invalid. (A UTF-16 file therefore fails, as do stray
  bytes such as `0xFF`.)
- A **newline** is LF (U+000A) or CRLF (U+000D U+000A). A CR that is not
  immediately followed by LF is invalid **anywhere** in the document,
  including inside strings and comments.
- A byte-order mark (U+FEFF) is not part of TOML 1.0.0. A document that starts
  with one is invalid.
- **Whitespace** means space (U+0020) and tab (U+0009), and only those.
- Every **digit** in the grammar below is an ASCII digit, `0`–`9` (plus
  `A`–`F`/`a`–`f` where hexadecimal digits are called for). This holds for
  integers, floats, exponents, date-time fields, offsets and `\u`/`\U`
  escapes alike. Decimal digits of other scripts are not digits here: a date
  whose digits are Arabic-Indic (U+0660 to U+0669), Devanagari or fullwidth
  rather than ASCII is an invalid value, as is such an integer or float.
  Beware of regular-expression `\d` and of `isdigit`-style predicates, which
  in many languages accept all of them.

### Comments

`#` starts a comment that runs to the end of the line. A comment may contain
tab, U+0020–U+007E and any code point at or above U+0080. Every other
character — the C0 controls other than tab, and U+007F (DEL) — is invalid
inside a comment.

### Statements

A document is a sequence of lines. Each line, after optional whitespace, is
empty, a comment, a key/value pair, or a table header. After a key/value pair
or a table header, only whitespace and an optional comment may follow before
the newline or end of file; anything else is invalid.

### Keys

A **simple key** is one of:

- a *bare key*: one or more of `A-Z a-z 0-9 _ -` (ASCII only; `1234` is a
  legal bare key);
- a *quoted key*: a basic string (`"…"`) or a literal string (`'…'`), with the
  same syntax and escapes as the corresponding string values, including the
  empty key `""`. Multi-line strings may not be used as keys.

A **key** is one or more simple keys separated by `.`, with optional
whitespace around each `.`. `a.b.c` is a *dotted key*; it addresses key `c`
of table `b` of table `a`.

Keys are compared by their decoded text: `"a"`, `'a'` and `a` are the same
key; `"é"` and the literal `é` are the same key.

### Values

A value is a string, integer, float, boolean, date-time, array or inline
table. A value is required after `=`; there is no null.

**Basic strings** are delimited by `"`. The permitted unescaped characters are
tab, U+0020–U+0021, U+0023–U+005B, U+005D–U+007E and everything at or above
U+0080 — i.e. everything except `"`, `\`, the C0 controls other than tab, and
U+007F. A newline may not appear. The escape sequences are exactly

```
\b  U+0008      \"  U+0022        \uXXXX      4 hex digits
\t  U+0009      \\  U+005C        \UXXXXXXXX  8 hex digits
\n  U+000A      \f  U+000C
\r  U+000D
```

Any other character after `\` is invalid. Hex digits may be upper or lower
case. The scalar value named by `\u`/`\U` must be a Unicode scalar value: at
most U+10FFFF and not in U+D800–U+DFFF. `\u0000` is legal and produces a NUL
character in the string (which the JSON output writes as `\u0000`).

**Multi-line basic strings** are delimited by `"""`.

- A newline immediately after the opening `"""` is discarded (CRLF included).
- Newlines inside the string are kept. A CRLF inside the body becomes a single
  LF in the value.
- One or two consecutive `"` may appear inside the body. The string ends at
  the first run of three or more `"`; a run of four contributes one `"` to the
  value and a run of five contributes two, then the string ends. A run of six
  or more is invalid.
- All the escapes above are allowed, plus the *line-ending backslash*: a `\`
  followed by optional whitespace and then a newline discards the backslash,
  that newline, and every whitespace character and newline that follows, up to
  the next non-whitespace character.
- The same characters are forbidden as in basic strings, except that newlines
  are allowed.

**Literal strings** are delimited by `'` and have no escapes at all. The
permitted characters are tab, U+0020–U+0026, U+0028–U+007E and everything at
or above U+0080 — i.e. everything except `'`, the C0 controls other than tab,
and U+007F. A newline may not appear.

**Multi-line literal strings** are delimited by `'''`, discard a newline
immediately after the opening delimiter, keep all other newlines (normalising
CRLF to LF), allow runs of one or two `'` inside, end at a run of three to
five `'` (contributing zero, one or two `'` respectively), and treat a run of
six or more as invalid. There are no escapes.

**Integers.**

```
decimal   [+-]? ( "0" | [1-9] ( "_"? [0-9] )* )
hex       "0x" HEXDIG ( "_"? HEXDIG )*
octal     "0o" [0-7] ( "_"? [0-7] )*
binary    "0b" [01] ( "_"? [01] )*
```

Leading zeros are invalid in decimal (`01` and `+01` are errors; `0` is fine).
An underscore must sit between two digits — never leading, trailing or
doubled. The prefixes must be lower case (`0X` is invalid) while hex digits
may be either case. The prefixed forms may not carry a sign (`-0x1` is
invalid). The value must fit in a signed 64-bit integer,
−9223372036854775808 to 9223372036854775807 inclusive, in every base;
anything outside that range is an error.

**Floats.**

```
float     decimal-int ( frac exp? | exp )
frac      "." [0-9] ( "_"? [0-9] )*
exp       ("e" | "E") [+-]? [0-9] ( "_"? [0-9] )*
special   [+-]? ( "inf" | "nan" )
```

The integer part follows the decimal-integer rules above (so `01.5`, `.5` and
`5.` are all invalid, and so is `1.e2` or `1e`). The exponent digits, unlike
the integer part, may have leading zeros (`0e00` is valid). `inf` and `nan`
must be lower case. A finite literal whose magnitude is too large for a double
becomes ±infinity, and one too small becomes ±0.0 — the usual `strtod`
behaviour; neither is an error.

**Booleans** are exactly `true` and `false`, lower case.

**Date-times** use RFC 3339 shapes, with all fields fixed-width:

```
date-local      YYYY "-" MM "-" DD
time-local      HH ":" MM ":" SS [ "." 1*DIGIT ]
datetime-local  date-local ( "T" | "t" | " " ) time-local
datetime        datetime-local ( "Z" | "z" | ("+"|"-") HH ":" MM )
```

Seconds are mandatory (`17:45` is not a time in TOML 1.0.0) and every field
must have exactly the number of digits shown (`1987-7-05` is invalid). The
date must be a real calendar date: month 01–12, day within the month, February
29 only in a leap year (divisible by 4, and by 400 if divisible by 100). The
time must satisfy hour ≤ 23, minute ≤ 59, second ≤ 59. The offset must satisfy
hour ≤ 23, minute ≤ 59. The year is four digits, so 0001–9999.

The space separator only forms a date-time when a complete time follows it:
in `d = 1979-05-27 # comment` the value is a `date-local`.

**Arrays** are `[` … `]` holding values separated by `,`. Whitespace,
newlines and comments may appear freely before, between and after the
elements. One trailing comma is allowed (`[1, 2, ]`); two commas in a row are
not, and neither is a leading comma. Elements need not have the same type.

**Inline tables** are `{` … `}` holding key/value pairs separated by `,`.
In TOML 1.0.0 an inline table must fit on one line: **no newline may appear
between the braces outside a value**, and **no trailing comma** is allowed
(`{}` is the empty inline table). A value inside the braces may still contain
newlines where that value's own syntax allows them: a multi-line string, or
an array, whose elements may be separated by newlines and comments as in any
array (`a = { b = [`, newline, `]}` is valid). A newline between the
key/value pairs of the inline table itself, or of an inline table nested in
such an array, is an error. Keys inside may be dotted. An inline table is closed
as soon as it ends: no later statement may add keys to it or to any table
nested inside it.

### Tables

A `[header]` line opens a table; the key/value pairs that follow belong to it
until the next header. A `[[header]]` line appends a new element to an array
of tables and opens that element. Whitespace is allowed inside the brackets
and around the dots of the key, but not between the two brackets of an
array-of-tables header: `[[ a . b ]]` is valid, while `[ [a] ]`, `[[a] ]`
and `[ [a]]` are not.

Call a table *explicit* if it was opened by a `[header]` line or written as an
inline-table literal, *implicit* if it was brought into existence only as an
intermediate segment of some other header, and *dotted* if it was brought into
existence by an intermediate segment of a dotted key. The rules are:

1. **Duplicate keys are always an error.** Defining the same key twice in the
   same table, whether through key/value pairs, dotted keys or inline tables,
   is invalid.
2. `[a.b.c]`: the segments `a` and `b` are resolved left to right. A missing
   segment becomes a new implicit table. An existing segment must be a table
   that is not part of an inline-table literal, or an array of tables created
   by `[[ … ]]`, in which case its **last element** is used. Anything else
   (a scalar, an array literal, an inline table) is an error.
   The final segment `c` must either not exist, or exist as a table that is
   neither explicit, nor dotted, nor part of an inline table — that is, an
   implicit table, which now becomes explicit. Anything else is an error, so
   `[a]` twice is invalid, and so is `[a]` after `a.b = 1`.
3. `[[a.b]]`: `a` is resolved as in rule 2. `b` must either not exist, in
   which case a new array of tables is created, or already be an array of
   tables created by `[[ … ]]`; a new explicit table is appended to it and
   opened. An array *literal* or a table at `b` is an error.
4. A dotted key `a.b.c = v` inside the current table resolves `a` and `b` the
   same way, except that each missing segment becomes a new **dotted** table,
   and an existing segment is acceptable only if it is a table that is neither
   explicit nor part of a closed inline table. So `a.b = 1` followed by
   `a.c = 2` is fine, and `[x] \n a.b = 1 \n a.c = 2` is fine, but a dotted
   key may not reach into a table that a `[header]` or an inline-table literal
   created.
5. A header may pass *through* a dotted table but may not target one. After
   `[fruit]` and `apple.color = "red"`, the line `[fruit.apple.texture]` is
   valid while `[fruit.apple]` is not.
6. Sub-tables of an array-of-tables element attach to the element most
   recently appended: after `[[fruit]]`, both `[fruit.physical]` and
   `[[fruit.varieties]]` belong to that element.

### Errors

A document is invalid, and decode prints `error`, whenever any rule above is
broken. There is no error recovery and no error message: the output is exactly
`error`. Structural depth is bounded in the tests (no more than a few hundred
levels of nesting), but an implementation must not crash on the deeply nested
cases in the suite.

## 1.4 Decisions where TOML leaves a choice

These follow the reference implementation, which is used as the oracle for
the whole test suite; the toml-test corpus does not settle them.

- **Leap seconds**: second 60 is rejected. Seconds are 00–59.
- **Byte-order mark**: a leading U+FEFF makes the document invalid.
- **CRLF inside multi-line strings** is normalised to a single LF in the
  value. (Everywhere else CRLF is just a newline, and a lone CR is an error.)
- **Integer range**: the 64-bit signed range is enforced for every base, so
  `0xFFFFFFFFFFFFFFFF` is an error.
- **Float range**: overflow yields ±inf and underflow yields ±0.0, silently.
- **`-00:00`** is treated as UTC and canonicalised to `Z`.
- **NaN** loses its sign: `nan`, `+nan` and `-nan` all decode to `nan`.

---

# Part 2 — encode

## 2.1 Encode input

The document on stdin is one tagged JSON tree in the format of Part 1, but
written by the test generator rather than by your decoder, so it may contain
arbitrary JSON whitespace and its object members may be in any order. It is
always well formed:

- the root is a JSON object;
- every value node has exactly the two string members `type` and `value`,
  `type` is one of the eight type names, and `value` is a legal text form for
  that type as defined in §1.2 — floats in particular arrive in the canonical
  17-digit form, or as `inf`, `-inf`, `nan`;
- no table has duplicate keys (JSON forbids it here).

A JSON object is a **value node** exactly when it has two members named `type`
and `value`, both strings, with `type` one of the eight type names; otherwise
it is a table. As noted in §1.1 this test is never ambiguous for these inputs.

## 2.2 Canonical TOML output

The output is a TOML document in the following canonical form. It is defined
so that two correct implementations produce identical bytes.

**Classification.** Inside a table, each key's value is one of:

- a **sub-table**: a JSON object that is not a value node;
- an **array of tables**: a JSON array that is non-empty and *all* of whose
  elements are sub-tables;
- everything else — a value node, or any other array (empty arrays included,
  and arrays that mix tables with non-tables).

**A table is rendered** as follows, given the dotted path that addresses it
(empty for the root):

1. First, for every key of the third kind above, in ascending key order
   (Unicode code point order), one line
   `KEY␣=␣VALUE`
   where `VALUE` is the inline rendering below.
2. Then, for every key of the first two kinds, in ascending key order:
   - a sub-table emits a blank line, the header line `[PATH.KEY]`, and then
     the sub-table rendered by these same rules with path `PATH.KEY`;
   - an array of tables emits, for each element in order, a blank line, the
     header `[[PATH.KEY]]`, and then that element rendered by these same
     rules with path `PATH.KEY`.

   The blank line before a header is omitted only when **no line at all has
   been written to the document yet** — the test is over the whole output so
   far, not over the table being rendered. So the only header that is not
   preceded by a blank line is one on the very first line of the document,
   and a table whose first content is a sub-table renders as
   `[a]`, blank line, `[a.b]`.

Every table gets a header, even an empty one, and even when a deeper header
would have created it implicitly. The root table has no header. The document
ends with a single `\n`, so an empty root table produces a lone `\n`
(trailing newlines are ignored when comparing outputs anyway).

**Inline rendering** of a value:

- a value node renders as its TOML literal (below);
- an array renders as `[` + elements joined by `,␣` + `]`, with `[]` when
  empty — so `[1, 2]`, `[[1], []]`, `[{a = 1}, 2]`;
- a table renders as `{` + `KEY␣=␣VALUE` items joined by `,␣` + `}`, with `{}`
  when empty, its keys in ascending order.

**Keys** render as the bare key itself when the key is non-empty and consists
only of `A-Z a-z 0-9 _ -`; otherwise as a basic string quoted by the rule
below. A dotted path joins rendered keys with `.` and no spaces.

**Literals**:

| type             | rendering                                               |
|------------------|---------------------------------------------------------|
| `string`         | a basic string, quoted as below                          |
| `integer`        | the `value` text verbatim                                |
| `float`          | the `value` text verbatim (`1.0000000000000000e+00`, `inf`, `-inf`, `nan`) |
| `bool`           | the `value` text verbatim (`true` / `false`)             |
| `datetime`, `datetime-local`, `date-local`, `time-local` | the `value` text verbatim |

Every one of those texts is already valid TOML, so no conversion is needed.

**Basic-string quoting** writes `"`, then each code point, then `"`:
`"` → `\"`, `\` → `\\`, U+0008 → `\b`, U+0009 → `\t`, U+000A → `\n`,
U+000C → `\f`, U+000D → `\r`, every other code point below U+0020 and U+007F
→ `\u00xx` with **lowercase** hex. Everything else is written literally as
UTF-8. Multi-line strings, literal strings and `\U` escapes are never
produced.

### Worked example

Input (the tagged JSON from the decode example above, reformatted):

```
encode
{"db":{"enabled":{"type":"bool","value":"true"},"ports":[{"type":"integer","value":"8001"},{"type":"integer","value":"8002"}]},"dob":{"type":"datetime","value":"1979-05-27T07:32:00-08:00"},"fruit":[{"name":{"type":"string","value":"apple"}},{"name":{"type":"string","value":"banana"}}],"name":{"type":"string","value":"Tom"}}
```

Output:

```
dob = 1979-05-27T07:32:00-08:00
name = "Tom"

[db]
enabled = true
ports = [8001, 8002]

[[fruit]]
name = "apple"

[[fruit]]
name = "banana"
```

## 2.3 The round-trip guarantee

For every tagged JSON tree `x` that `encode` can be given,
`decode(encode(x)) == x` byte for byte. The rules above are chosen to make
this hold, and the generator checks it on every encode test:

- keys that need quoting are quoted, so every key survives;
- the canonical float text has 17 significant digits, which round-trips
  through a double exactly, and `inf`/`-inf`/`nan` map to themselves;
- date-time texts are already canonical, so re-decoding reproduces them;
- basic strings escape every character TOML forbids and nothing that would
  change the value;
- pairs are written before headers at each level, so the document parses with
  the intended shape; empty tables get explicit headers so they survive;
- an array is written inline exactly when it is not a non-empty array of
  tables, which is exactly the condition under which the decoder produces an
  array literal.

---

# Implementation notes

Expect roughly 900–1400 lines in a systems language. A workable shape is:

- a **decoder**: a single-pass recursive-descent parser over the decoded
  UTF-8 text, with a small set of scanners (whitespace/comment, key, the four
  string forms, number/date-time, array, inline table) and a table-resolution
  layer that holds the explicit/implicit/dotted/inline flags of §1.3. Watch
  the character-class checks: a large share of the invalid corpus is control
  characters, lone CRs and bad escapes in places that are easy to skip over.
- a **JSON writer**: 30 lines, but it must sort keys and escape exactly as
  §1.1 says.
- a **JSON reader** for encode mode, for the well-formed JSON of §2.1
  (objects, arrays, strings with their escapes, and whitespace).
- an **encoder**: the classification and rendering of §2.2, about 100 lines.

Performance is not the point, but the suite does include a 2.2 MB generated
document and a 190 KB `Cargo.lock`; a straightforward single-pass parser
handles both in well under a second, while anything quadratic in the document
length (repeated string concatenation, re-scanning from the start of the
buffer) will not.
