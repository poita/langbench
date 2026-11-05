# mime — MIME email parser

Read a mailbox (an mbox file or a directory of `.eml` files), parse every
message it contains as RFC 5322 / RFC 2045-2047 email, and write a normalised
text dump of each message plus the decoded bytes of every attachment into an
output directory.

Write the message parsing and decoding yourself: don't use an email, MIME,
header, address or date parser, or a quoted-printable or base64 decoder, from a
library, the standard library or the language.

This is a **directory-mode** problem. The program is invoked with exactly two
arguments:

```
<command> <input path> <output directory>
```

The output directory already exists and is empty (an implementation may also
create it if it is missing); the program creates files and subdirectories
inside it and writes nothing anywhere else. Nothing is read from stdin;
anything written to stdout or stderr is ignored. The exit code must be 0.

All output text files are UTF-8 with LF (`\n`) line endings and no byte-order
mark. Input is **bytes** and is never assumed to be valid text.

Every input in the test suite satisfies the guarantees in
[Guarantees](#guarantees). An implementation may do anything at all on an
input that violates them — the tests never contain one — but it must not fail
on a valid input.

## Contents

1. [Input](#input)
2. [Bytes, lines and text](#bytes-lines-and-text)
3. [Character sets](#character-sets)
4. [Header parsing](#header-parsing)
5. [RFC 2047 encoded words](#rfc-2047-encoded-words)
6. [Structured header values](#structured-header-values)
7. [Addresses](#addresses)
8. [Dates](#dates)
9. [Content-Transfer-Encoding](#content-transfer-encoding)
10. [MIME structure](#mime-structure)
11. [Body selection and attachments](#body-selection-and-attachments)
12. [Adler-32](#adler-32)
13. [Output](#output)
14. [Worked example](#worked-example)
15. [Guarantees](#guarantees)
16. [Architecture and size](#architecture-and-size)

## Input

The input path is either a regular file or a directory.

**Directory** — every entry **directly inside** the directory whose name ends
with the four bytes `.eml` (lower case) and which is a regular file is one
message. Those entries are processed in ascending order of their names
compared as byte strings (`b"a.eml" < b"b.eml"`, ASCII order, so `Z` sorts
before `a`). All other entries are ignored. A message's bytes are the whole
file. Its **source id** is the file name, e.g. `basic.eml`.

**Regular file** — an mbox archive. It is split into messages as follows.

- A **separator line** is a line whose first five characters are `From `
  (`F`, `r`, `o`, `m`, space) and which is either the first line of the file
  or is immediately preceded by an empty line.
- Everything before the first separator line is discarded. If there is no
  separator line the mailbox contains no messages.
- Message *i* occupies the bytes from just after the separator line's
  terminator up to (but not including) the start of the next separator line,
  or to the end of the file for the last message.
- If those bytes end with the two characters LF LF, the final LF is removed
  (it is the blank line that separates mbox messages). Otherwise they are
  used unchanged.
- The separator line itself is not part of the message and is not parsed.
- No `>From ` unescaping is performed: body lines are used exactly as they
  appear.

Message *i* (1-based) has **source id** `mbox:<i>`, e.g. `mbox:1`.

Messages are numbered 1, 2, 3, … in the order just defined; the number is
written as four decimal digits with leading zeros (`0001`).

## Bytes, lines and text

A message is a byte string. Splitting it into **lines** is defined once and
used everywhere:

- A line ends at the next LF (0x0A). The LF, and a single CR (0x0D)
  immediately before it, are the terminator and are not part of the line.
- The last line of a byte string that does not end with LF has no terminator.
- A byte string ending in LF does **not** produce a final empty line:
  `b"a\nb\n"` has two lines, `b"a\nb"` has two lines, `b""` has none.

Whenever this specification speaks of "the bytes of a region with lines
joined", the lines are re-joined with a single LF after each line except that
the final line gets a LF only if the region's last line had a terminator. In
other words: **every CRLF in the input becomes a single LF, and nothing else
changes.** A CR that is not immediately followed by LF is an ordinary byte
and is never a line terminator.

Header text is obtained by decoding header bytes as UTF-8
(see [Character sets](#character-sets)); this is the only place where a
charset is applied without being named by the message.

## Character sets

`decode(bytes, charset)` produces a Unicode string. The charset name is
normalised first: strip leading and trailing spaces and tabs, then lower-case
ASCII letters. Then:

| Normalised name | Table |
|---|---|
| `us-ascii`, `ascii`, `iso-ir-6`, `ansi_x3.4-1968`, `iso646-us` | ASCII |
| `utf-8`, `utf8`, `unicode-1-1-utf-8` | UTF-8 |
| `iso-8859-1`, `iso8859-1`, `latin-1`, `latin1`, `l1`, `8859-1`, `iso_8859-1` | Latin-1 |
| `windows-1252`, `cp1252`, `windows1252`, `ansi` | cp1252 |
| anything else, including an empty name | cp1252 |

- **ASCII**: a byte < 0x80 maps to the code point with the same value; a byte
  ≥ 0x80 maps to U+FFFD.
- **Latin-1**: every byte maps to the code point with the same value.
- **cp1252**: bytes 0x00–0x7F and 0xA0–0xFF map to the code point with the
  same value; bytes 0x80–0x9F map through this table:

```
0x80 U+20AC   0x88 U+02C6   0x90 U+0090   0x98 U+02DC
0x81 U+0081   0x89 U+2030   0x91 U+2018   0x99 U+2122
0x82 U+201A   0x8A U+0160   0x92 U+2019   0x9A U+0161
0x83 U+0192   0x8B U+2039   0x93 U+201C   0x9B U+203A
0x84 U+201E   0x8C U+0152   0x94 U+201D   0x9C U+0153
0x85 U+2026   0x8D U+008D   0x95 U+2022   0x9D U+009D
0x86 U+2020   0x8E U+017D   0x96 U+2013   0x9E U+017E
0x87 U+2021   0x8F U+008F   0x97 U+2014   0x9F U+0178
```

- **UTF-8**: standard UTF-8 decoding. Invalid input is replaced using the
  *maximal subpart* rule, which must be implemented exactly:

  1. Let *b0* be the next byte. If *b0* < 0x80, emit U+0000+*b0* and consume
     one byte.
  2. Otherwise determine the sequence length and the allowed range of the
     second byte:

     | *b0* | length | allowed second byte |
     |---|---|---|
     | 0xC2–0xDF | 2 | 0x80–0xBF |
     | 0xE0 | 3 | 0xA0–0xBF |
     | 0xE1–0xEC | 3 | 0x80–0xBF |
     | 0xED | 3 | 0x80–0x9F |
     | 0xEE–0xEF | 3 | 0x80–0xBF |
     | 0xF0 | 4 | 0x90–0xBF |
     | 0xF1–0xF3 | 4 | 0x80–0xBF |
     | 0xF4 | 4 | 0x80–0x8F |
     | anything else (0x80–0xC1, 0xF5–0xFF) | — | — |

     For "anything else", emit U+FFFD and consume exactly one byte.
  3. Otherwise check the continuation bytes one at a time: the second byte
     must be in the allowed range above and each further byte must be in
     0x80–0xBF. On the first byte that is missing (end of input) or out of
     range, emit U+FFFD and consume only the bytes checked so far that were
     valid (that is, *b0* plus the continuation bytes that were in range).
     The offending byte is **not** consumed.
  4. If all continuation bytes are present and in range, emit the code point
     they encode and consume the whole sequence.

  So `b"\xe2\x28\xa1"` yields U+FFFD, `(`, U+FFFD, and `b"\xf0\x9f"` at the
  end of input yields a single U+FFFD.

## Header parsing

A message consists of a **header block** and a **body**.

Split the message into lines. Scan the lines from the first:

- An **empty** line (length 0) ends the header block; the body is everything
  after that line's terminator.
- A line whose first character is SPACE (0x20) or TAB (0x09), which is not the
  first line of the message, and which follows a field line, is a
  **continuation**.
- Any other line must be a **field line**: it contains a `:`, and the bytes
  before the first `:` are at least one byte and every one of them is in
  0x21–0x39 or 0x3B–0x7E (printable ASCII except SPACE and `:`). If the line
  is not a field line, the header block ends immediately **before** that line
  and the body starts at that line.

  So `Subject: x` starts a field, while `Subject :x` (space in the name),
  `no colon here`, `: novalue` (empty name) and
  `From nobody Mon Sep  1 00:00:00 2025` (space in the name) each end the
  header block.
- If the lines run out, the header block is the whole message and the body is
  empty.

Each non-continuation line starts a header field; the continuation lines that
follow it belong to it. **Unfolding** a field concatenates its lines with
nothing between them (the line terminators disappear, the leading whitespace
of each continuation line is kept). In the unfolded field, the **name** is
everything before the first `:` and the **raw value** is everything after it.
Both are taken from text decoded as UTF-8 per
[Character sets](#character-sets).

Fields are kept in the order they appear, including repetitions. When this
specification refers to "the `X` header" it means the **first** field whose
name, compared case-insensitively after stripping spaces and tabs from both
ends, equals `X`.

`collapse(s)` replaces each maximal run of SPACE and TAB characters in `s`
with a single SPACE and then strips a leading and a trailing SPACE.

For the output dump the value of a field is:

- `collapse(raw value)` if the lower-cased, stripped field name is one of
  `content-disposition`, `content-id`, `content-transfer-encoding`,
  `content-type`, `date`, `in-reply-to`, `message-id`, `mime-version`,
  `received`, `references`, `return-path`;
- otherwise `decode_unstructured(raw value)`
  (see [RFC 2047 encoded words](#rfc-2047-encoded-words)).

## RFC 2047 encoded words

An **encoded word** begins at position *i* of a string *v* when all of the
following hold:

1. `v[i:i+2] == "=?"`.
2. There is a `?` at some position *j* ≥ *i*+2. The **charset field** is
   `v[i+2:j]`; it must be non-empty and contain no SPACE and no TAB.
3. `v[j+1]` is one of `Q`, `q`, `B`, `b` and `v[j+2] == "?"`.
4. There is a `?` at some position *m* ≥ *j*+3. The **encoded text** is
   `v[j+3:m]`; it must contain no SPACE and no TAB.
5. `v[m+1] == "="`.

The encoded word is then `v[i:m+2]`. Take the first `?` in step 2 and the
first `?` in step 4; if any condition fails, no encoded word starts at *i*.

The charset is the charset field truncated at its first `*` (a language tag),
lower-cased and stripped; if that is empty, `us-ascii` is used. The encoded
text is turned into bytes:

- **Q**: scan the text. `_` produces byte 0x20. `=` followed by two
  hexadecimal digits (`0-9A-Fa-f`) produces that byte. Any other character —
  including a `=` not followed by two hex digits — produces its own UTF-8
  encoding.
- **B**: see [base64](#content-transfer-encoding); the same decoder is used.

The bytes are then turned into text with `decode(bytes, charset)`.

### decode_unstructured(v)

1. Scan *v* from left to right. At each position, if an encoded word starts
   there, append the item `(ENCODED, decoded text)` and skip past it;
   otherwise, if the character is SPACE or TAB, append it to the current
   whitespace run; otherwise append it to the current literal run. Runs of
   whitespace and runs of other literal characters are separate items:
   `(SPACE, run)` and `(LITERAL, run)`.
2. Concatenate the items in order: an `ENCODED` or `LITERAL` item contributes
   its text; a `SPACE` item contributes nothing at all if the item before it
   is `ENCODED` **and** the item after it is `ENCODED`, and otherwise
   contributes its own characters unchanged (so runs of blanks are preserved,
   tabs included).
3. Strip leading and trailing SPACE and TAB characters from the result.

Examples (the value follows `Subject:`):

| Raw value | Result |
|---|---|
| `=?utf-8?Q?caf=C3=A9?=` | `café` |
| `=?utf-8?Q?a?=   =?utf-8?Q?b?=` | `ab` |
| `x =?utf-8?Q?a?= y` | `x a y` |
| `=?utf-8?Q?a?=b` | `ab` |
| `=?iso-8859-1?Q?caf=E9?=` | `café` |
| `=?windows-1252?Q?smart=92quote?=` | `smart’quote` |
| `=?utf-8?B?SsO2cmc=?=` | `Jörg` |
| `=?utf-8*en?Q?hi?=` | `hi` |
| `=?utf-8?X?hi?=` | `=?utf-8?X?hi?=` |
| `  plain    spaced   text  ` | `plain    spaced   text` |
| `=?utf-8?Q?a?= <TAB> =?utf-8?Q?b?= <TAB> c` | `ab <TAB> c` |

In the last row `<TAB>` stands for one TAB character: the blanks between the
two encoded words vanish, the blanks after them survive as they are.

## Structured header values

`Content-Type`, `Content-Disposition` and `Content-Transfer-Encoding` are
parsed from the unfolded raw value with this grammar. Parentheses are
**ordinary characters** here — comments are not recognised in these three
headers.

Split the value into segments at every `;` that is not inside a quoted
string. A **quoted string** starts at a `"`. Scan forward from the character
after it: a `\` and the character after it are consumed together and stand
for that character, and any other character stands for itself, until a `"` is
reached, which closes the string and is consumed. A quoted string that is
never closed extends to the end of the value; a `\` that is the last
character of the value has no character after it and stands for itself.

Note that `"a\\"` is therefore a closed quoted string holding one backslash:
the `\` consumes the second `\`, and the `"` after them closes the string.

- The **first segment** is the value proper.
- Every later segment is a parameter. The parameter name is the text before
  the first `=`, stripped of spaces and tabs and lower-cased; the parameter
  value is the text after the first `=`, stripped of spaces and tabs, and
  then, if it begins with `"`, replaced by the contents of that quoted string
  with escapes resolved. A segment with no `=` is ignored. If the same
  parameter name occurs more than once, the first occurrence wins.

  An unquoted value therefore runs to the next top-level `;` or to the end of
  the header, blanks and all: `filename=two words.bin` gives
  `two words.bin`, and `boundary=simple boundary` gives `simple boundary`.
  This is deliberately more forgiving than RFC 2045, which would stop the
  value at the first blank.

### RFC 2231 parameters

After collecting the raw parameters (in order of first appearance), assemble
the effective parameter values:

- A name of the form `base*N` or `base*N*` where `base` is non-empty and `N`
  is one or more decimal digits is **segment N** of `base`; `N` is read as a
  decimal number, so `f*07` is segment 7. A name of the form `base*` is the
  single **extended** value of `base`. Any other name — including one that
  starts with `*`, such as `*0` — is a plain parameter under its own full
  name.
- If any `base*N`/`base*N*` segments exist for a base, its value is built by
  concatenating the segments in increasing numeric order of `N`, skipping
  missing numbers. When several segments of one base have the same number
  (`f*0` and `f*00`, or `f*1` and `f*1*`), only the first of them in order
  of appearance is used; the others are ignored. Each segment whose name ended with `*` is
  percent-decoded (`%` followed by two hexadecimal digits produces that byte;
  any other `%` is a literal `%`); segments without the trailing `*`
  contribute their characters' UTF-8 encodings. The charset for the whole
  parameter comes from segment 0 if it is extended, otherwise it is
  `us-ascii`.
- An extended value `base*` (and an extended segment 0) has the form
  `charset'language'text`: the text before the first `'` is the charset, the
  text between the first and second `'` is the language and is discarded, and
  the rest is the percent-encoded text. If that charset is empty, or if the
  value contains fewer than two `'` (in which case the whole value is the
  percent-encoded text), the charset is `us-ascii`. An empty charset here
  therefore means `us-ascii` and **not** the cp1252 fallback that an empty
  name gets in [Character sets](#character-sets): `filename*=''caf%E9.txt`
  decodes 0xE9 as ASCII and yields `caf` U+FFFD `.txt`, not `café.txt`.
- The resulting bytes are decoded with `decode(bytes, charset)`.
- If both an extended form (`base*` or `base*N…`) and a plain `base` exist,
  the extended form wins; if both `base*` and numbered segments exist, the
  numbered segments win.
- A plain parameter's value is used as-is except that
  `decode_unstructured` is applied to it (so RFC 2047 encoded words inside a
  plain parameter value are decoded). `decode_unstructured` is **not**
  applied to a value built from extended parameters.

Examples:

| Parameters | `filename` |
|---|---|
| `filename="report.pdf"` | `report.pdf` |
| `filename*=utf-8''a%C3%A9.txt` | `aé.txt` |
| `filename*0="long"; filename*1="name.txt"` | `longname.txt` |
| `filename*0*=utf-8''a%C3%A9; filename*1=".txt"` | `aé.txt` |
| `filename="=?utf-8?Q?a=C3=A9.txt?="` | `aé.txt` |
| `filename=two words.bin` | `two words.bin` |
| `filename*=''caf%E9.txt` | `caf` U+FFFD `.txt` |
| `filename*0=a; filename*2=c; filename*10=j` | `acj` |
| `filename="a\\"; x=1` | `a\` |

A parameter value that was folded across lines is unfolded first, like every
other header: `boundary="simple` followed by a continuation line
` boundary"` gives the boundary `simple boundary`.

### Content-Type

The value proper is stripped of spaces and tabs and lower-cased. It is used
when it consists of a non-empty **type** token, a `/`, and a non-empty
**subtype** token, where a token contains none of the characters
`SPACE TAB ( ) < > @ , ; : \ " / [ ] ? =`. Otherwise, and when the message
has no `Content-Type` header at all, the **default type** is used:

- `message/rfc822` for a part whose parent is a `multipart/digest`;
- `text/plain` for every other part.

Parameters are still taken from the header when it is present, even if its
value proper is unusable.

The `charset` parameter is normalised as in
[Character sets](#character-sets); when a `text/*` part has no `charset`
parameter, its charset is `us-ascii`.

### Content-Disposition

The value proper, stripped and lower-cased, is the **disposition type**. If
it is empty the disposition type is `inline`.

### Content-Transfer-Encoding

The value proper, stripped and lower-cased, is the **encoding**. If the
header is absent, the encoding is `7bit`.

## Addresses

The headers `from`, `sender`, `reply-to`, `to`, `cc` and `bcc` are parsed as
address lists from their unfolded raw values.

### Tokenising

Scan the value producing tokens; SPACE and TAB separate tokens and are
otherwise discarded.

- `(` starts a **comment**: skip to the matching `)`, counting nested `(`
  and `)`, and treating `\` followed by any character as that character.
  An unterminated comment runs to the end of the value. A comment produces
  no token.
- `"` starts a **quoted string** as defined above. It produces a
  `QUOTED` token whose text is the unescaped contents.
- `[` starts a **domain literal**: it runs to the next `]`, with `\`
  escapes; an unterminated one runs to the end of the value. It produces a
  `LITERAL` token whose text is the whole thing including the brackets, with
  escape sequences left in place.
- An **encoded word** (as defined in
  [RFC 2047 encoded words](#rfc-2047-encoded-words)) starting here produces an
  `ENCODED` token whose text is its decoded text. This is tested before the
  two rules below, so an encoded word is one token however many specials it
  contains.
- Each of `< > @ , : ; .` produces a `SPECIAL` token of that one character.
- Any other run of characters up to the next character that is whitespace or
  one of `( ) < > [ ] @ , : ; . " \` produces an `ATOM` token. A stray `)`,
  `]` or `\` produces an `ATOM` token of that single character.

### Grammar

The token list is split into **elements** at top-level `,` tokens, where
"top level" means not between a `<` and its matching `>`. Group delimiters do
not affect the split: a group's member list is split at commas like any other
list. In practice: scan the tokens keeping a **counter** that starts at 0, is
incremented by each `<` token and decremented by each `>` token but never
below 0; a `,` splits only while the counter is 0. The counter nests, so in
`a <b <c@d.com> , e@f.com>, g@h.com` the inner `>` only brings the counter
back to 1 and the first `,` does not split — the value is two elements,
`a <b <c@d.com> , e@f.com>` and `g@h.com`.

Group syntax is handled first: if an element contains a top-level `:` before
any `<` or `@`, the tokens up to and including that `:` are dropped (the
group name is discarded) and the rest is parsed as the element. A `;` token
at the end of an element is dropped. Note that a group's member list is
split at commas like any other list, so `g: a@b, c@d;` yields two elements,
`g : a@b` and `c@d ;`.

Each element is then matched against, in order:

1. `[phrase] < addr-spec >` — the tokens before the first `<`, if any, form
   the **phrase**; the tokens between that `<` and the **last** `>` form the
   addr-spec; anything after the `>` is ignored.
2. `addr-spec` — the whole element.

An **addr-spec** is `local @ domain` where `local` is a non-empty sequence of
`ATOM` and `QUOTED` tokens separated by `.` tokens and `domain` is either one
`LITERAL` token or a non-empty sequence of `ATOM` tokens separated by `.`
tokens. "Separated by" is strict: tokens and `.` tokens must alternate,
starting and ending with a token. An `ENCODED` token is never part of an
addr-spec. Its rendering is: the texts of the local tokens joined with `.`,
then `@`, then the texts of the domain tokens joined with `.`. An addr-spec
with no `@` token renders as just the local part; a rendering is only
produced when the token run is non-empty and matches the shape above.

The **phrase** of alternative 1 is *not* rebuilt from tokens. It is the
substring of the header value that runs from the first character of the
element's first token up to (not including) the `<` that opens the
addr-spec, decoded by `decode_display`:

`decode_display(s)` scans *s* from left to right, building the same item list
as [decode_unstructured](#decode_unstructuredv) with two extra rules, then
concatenating it by that function's step 2 and stripping it by its step 3:

- a `(` starts a comment, which is skipped exactly as in
  [Dates](#dates) (nested, with `\` escapes, running to the end if
  unterminated) and contributes a single `SPACE` item of one space;
- a `"` starts a quoted string, which contributes a `LITERAL` item holding
  its unescaped contents — encoded words inside a quoted string are **not**
  decoded.

So `John Q. Public ` renders as `John Q. Public` (step 3 strips the trailing
blank), `"Doe, John" ` as `Doe, John`, and `=?utf-8?B?SsO2cmc=?= ` as `Jörg`.
A comment contributes its one space *in addition to* the blanks around it, so
`John (the third) Public ` renders as `John` + three spaces + `Public`.

If an element does not match either alternative — because the addr-spec is
malformed, or because alternative 1's `<` has no `>` after it — it produces
one address whose display name is empty and whose spec is the concatenation
of the texts of **all** of the element's tokens in order with nothing between
them (so the blanks between tokens are lost: `Symantec Email Proxy` becomes
`SymantecEmailProxy`). An element with no tokens at all produces no address.

Examples:

| Value | Addresses as `display | spec` |
|---|---|
| `Real Name <user@example.com>` | `Real Name \| user@example.com` |
| `user@example.com (Real Name)` | ` \| user@example.com` |
| `"Doe, John" <jd@x.com>` | `Doe, John \| jd@x.com` |
| `a@b.com, (c) d@e.com` | ` \| a@b.com` and ` \| d@e.com` |
| `Undisclosed recipients:;` | (none) |
| `grp: a@b.com, c@d.com;` | ` \| a@b.com` and ` \| c@d.com` |
| `=?utf-8?B?SsO2cmc=?= <j@x.de>` | `Jörg \| j@x.de` |
| `foo (c (nested)) <a@b>` | `foo \| a@b` |
| `ed <a@[10.0.0.1]>` | `ed \| a@[10.0.0.1]` |
| `broken <a@@b>` | ` \| broken<a@@b>` |
| `John Q. Public <jqp@example.com>` | `John Q. Public \| jqp@example.com` |
| `Symantec Email Proxy` | ` \| SymantecEmailProxy` |
| `"=?utf-8?Q?x?=" <a@b>` | `=?utf-8?Q?x?= \| a@b` |
| `a <b <c@d.com> , e@f.com>, g@h.com` | ` \| a<b<c@d.com>,e@f.com>` and ` \| g@h.com` |
| `John (the third) Public <jqp@x.com>` | `John   Public \| jqp@x.com` |

## Dates

The `Date` header's unfolded raw value is parsed as follows.

1. Remove comments: a `(` starts a comment which ends at the matching `)`,
   counting nesting, with `\` escapes; an unterminated comment runs to the
   end. Comments are replaced by nothing.
2. Split the rest into tokens on runs of SPACE, TAB and `,`. (A comma is
   therefore just a separator; the optional day-of-week comma needs no
   special handling.)
3. If the first token is one of `Mon Tue Wed Thu Fri Sat Sun` compared
   case-insensitively, drop it.
4. The remaining tokens must be, in order: **day**, **month**, **year**,
   **time**, and optionally **zone**. Any further tokens are ignored. If
   there are fewer than four, the date is invalid.
   - **day**: one or two decimal digits, value 1–31.
   - **month**: one of `Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec`
     compared case-insensitively (exactly three letters).
   - **year**: two, three or four decimal digits. A two-digit year `yy` means
     `19yy` when `yy` ≥ 50 and `20yy` otherwise. A three-digit year `yyy`
     means `1900+yyy`. The final year must be ≥ 1 and ≤ 9999.
   - **time**: `hh:mm` or `hh:mm:ss`, each field one or two decimal digits,
     with `hh` ≤ 23, `mm` ≤ 59 and `ss` ≤ 60. A missing `ss` is 0.
   - **zone**: either `+hhmm` / `-hhmm` (exactly four digits) or a name. The
     offset in minutes is `±(hh*60+mm)`; `hh` and `mm` may be anything the
     four digits express. A name is matched case-insensitively against
     `UT`=0, `GMT`=0, `Z`=0, `EST`=-300, `EDT`=-240, `CST`=-360, `CDT`=-300,
     `MST`=-420, `MDT`=-360, `PST`=-480, `PDT`=-420. Any other zone token,
     and a missing zone, means offset 0.
5. The day must be valid for the month and year, using the Gregorian
   calendar with leap years (divisible by 4, except centuries not divisible
   by 400). Otherwise the date is invalid.

The **epoch** is

```
epoch = days_from_civil(year, month, day) * 86400 + hh*3600 + mm*60 + ss
        - offset_minutes * 60
```

where `days_from_civil` is the number of days from 1970-01-01 to that date
(negative before it). The **UTC rendering** is the date and time obtained by
converting `epoch` back to a civil date and time in UTC — the day number is
`floor(epoch / 86400)` and the time of day is `epoch - 86400 * that`, so a
negative `epoch` needs flooring division and a non-negative remainder, not
the truncating division most languages give — formatted
`YYYY-MM-DDTHH:MM:SSZ` with `YYYY` zero-padded to four digits (the tests
never produce a year outside 1000–9999). Note that `ss` = 60 and large zone
offsets therefore roll over naturally.

The **offset rendering** is the sign of `offset_minutes` (`+` when zero),
then `abs(offset_minutes) // 60` and `abs(offset_minutes) % 60`, each in
decimal, zero-padded to *at least* two digits. That is four digits for every
ordinary zone, but a four-digit zone can express more: `+9999` is
99*60+99 = 6039 minutes and renders as `+10039`.

Examples:

| Raw value | epoch | utc | offset |
|---|---|---|---|
| `Sun, 29 Feb 2004 22:03:22 -0800` | `1078121002` | `2004-03-01T06:03:22Z` | `-0800` |
| `3 Jan 70 00:00:00 GMT` | `172800` | `1970-01-03T00:00:00Z` | `+0000` |
| `Tue, 1 Jan 2036 00:00:60 +0000` | `2082758460` | `2036-01-01T00:01:00Z` | `+0000` |
| `Mon, 3 Mar 1969 12:00 (GMT) -0500` | `-26204400` | `1969-03-03T17:00:00Z` | `-0500` |
| `Sun, 07 Mar 2004 15:21:26 -0000` | `1078672886` | `2004-03-07T15:21:26Z` | `+0000` |
| `1 Jan 2000 00:00:00 +2359` | `946598460` | `1999-12-31T00:01:00Z` | `+2359` |
| `not a date` | — | — | — |

Note `-0000`: RFC 5322 reads it as "the zone is unknown", but here it is
simply an offset of zero minutes, and zero minutes always renders as `+0000`.
Note also the fourth row: the zone is the fifth token, and the comment
between the time and the zone is removed before tokenising, so `-0500` is
the zone and not an ignored sixth token.

## Content-Transfer-Encoding

`decode_body(bytes, encoding)` produces the decoded bytes of a leaf part.
The input is the part's body with lines already joined as described in
[Bytes, lines and text](#bytes-lines-and-text) (so no CRLF remains).

- `7bit`, `8bit`, `binary`, and **any unrecognised encoding**, and an absent
  header: the bytes unchanged.
- `quoted-printable`: scan the bytes. At a `=`:
  - if the next byte is LF, consume both and emit nothing (soft line break);
  - else if the next two bytes are hexadecimal digits (`0-9A-Fa-f`), consume
    all three and emit the byte they denote;
  - else if the `=` is the last byte, consume it and emit nothing;
  - else emit `=` and consume it.

  Every other byte is emitted unchanged, including trailing whitespace before
  a line break.
- `base64`: discard every byte that is not in the base64 alphabet
  (`A-Z`, `a-z`, `0-9`, `+`, `/`); `=` is discarded too. Let *n* be the
  number of remaining characters. Decode each complete group of four into
  three bytes. If `n % 4 == 2`, the final two characters produce one more
  byte (the top 8 bits of their 12); if `n % 4 == 3`, the final three
  characters produce two more bytes (the top 16 bits of their 18); if
  `n % 4 == 1` the final character is discarded.

Examples of quoted-printable (`⏎` is LF):

| Input | Output |
|---|---|
| `a=20b` | `a b` |
| `a=⏎b` | `ab` |
| `a=3Db` | `a=b` |
| `a=Zb` | `a=Zb` |
| `a=3⏎` | `a=3⏎` |
| `abc=` | `abc` |
| `=0D=0A` | CR LF |
| `x  ⏎y` | `x  ⏎y` |

## MIME structure

A **part** is a message: a header block plus a body. The whole message is
part 0. Parts are numbered in the order a depth-first pre-order walk visits
them (a part is numbered before its children, children in order).

Each part is classified from its effective content type (see
[Content-Type](#content-type)):

**multipart/&ast;** — if the part has a `boundary` parameter whose value is a
non-empty string, it is a **multipart container**; otherwise it is a leaf.

Let *B* be the boundary value, and let *Bb* be *B* encoded as UTF-8 (*B* is
a string, delimiter matching is on bytes; *B* came from header text decoded as
UTF-8, so a boundary parameter that held bytes which are not valid UTF-8 has
already become U+FFFD and *Bb* holds the three bytes `EF BF BD` for each of
them, which will not match the original bytes in the body). A **delimiter
line** is a line whose first bytes are `--` followed by *Bb*, and whose
remaining bytes are `--` or nothing, optionally followed by any number of
spaces and tabs. A delimiter whose remainder begins with `--` is a
**close delimiter**.

- Find the first delimiter line in the body. If there is none, the container
  has no children, its **preamble** is the whole body, and its **epilogue** is
  absent.
- Otherwise the preamble is the bytes before that line, less one trailing LF
  if present. (If the delimiter is the first line, the preamble is empty.)
- If that first delimiter is a close delimiter, the container has no children
  and its epilogue is everything after that line's terminator.
- Otherwise, each child part occupies the bytes from just after a
  non-close delimiter line's terminator up to (but not including) the first
  byte of the next delimiter line, less one trailing LF if present (that LF
  belongs to the delimiter that follows). Scanning stops at the first close
  delimiter; the
  epilogue is everything after that line's terminator. If no close delimiter
  is found, the last child runs to the end of the body — still less one
  trailing LF if present — and the epilogue is absent.
- Two delimiter lines in a row bound a child part of zero bytes, which is
  parsed like any other: an empty header block and an empty body.
- A child's bytes are parsed as a part in their own right.

**message/rfc822** — the part is a **message container** with exactly one
child: `decode_body(body, encoding)` parsed as a part.

**Everything else**, including every other `message/*` subtype — the part is
a **leaf**. Its **content** is `decode_body(body, encoding)`.

A leaf part whose type is `text/*` additionally has **text**:
`decode(content, charset)`.

## Body selection and attachments

Walk the parts in pre-order, but do not descend into a `message/rfc822`
container's child. A part is a **body candidate** when it is a leaf and its
`Content-Disposition` header, if present, has a disposition type other than
`attachment`.

- The **text body** is the first body candidate whose type is `text/plain`,
  if any.
- The **html body** is the first body candidate whose type is `text/html`,
  if any.

Every leaf part that is neither the text body nor the html body is an
**attachment**, including leaves inside a `message/rfc822` container.
Attachments are listed in part-index order.

A part's **filename** is the `filename` parameter of its `Content-Disposition`
header if it has one, else the `name` parameter of its `Content-Type` header
if it has one, else absent. It is reported as it is; it is never used to name
a file on disk.

## Adler-32

`adler32(bytes)`: let `a = 1`, `b = 0`; for each byte *x*,
`a = (a + x) mod 65521` and then `b = (b + a) mod 65521`. The result is
`b * 65536 + a`, printed as exactly eight lower-case hexadecimal digits.
`adler32(b"")` is `00000001`.

## Output

### Escaping

`esc(s)` maps a string to a string:

| Character | Output |
|---|---|
| `\` | `\\` |
| LF (U+000A) | `\n` |
| CR (U+000D) | `\r` |
| TAB (U+0009) | `\t` |
| `"` | `\"` |
| any other code point < 0x20, or 0x7F, or in 0x80–0x9F | `\xHH` with two lower-case hex digits |
| anything else | itself |

`q(s)` is `"` + `esc(s)` + `"`.

### Files

```
<output>/summary.txt
<output>/messages/NNNN.txt        one per message
<output>/parts/NNNN/PPP.bin       one per attachment
```

`NNNN` is the 4-digit message number and `PPP` is the 3-digit part index of
the attachment. `parts/NNNN/` exists only when message `NNNN` has at least
one attachment. Each `.bin` file holds the attachment's content bytes
exactly.

### summary.txt

One line `messages <count>` followed by one line per message in order:

```
<NNNN> source=<q(source id)> bytes=<message byte length> parts=<count> attachments=<count> text=<index|-> html=<index|->
```

`bytes` is the number of bytes of the message as extracted from the input
(after the mbox trailing-LF removal, before any line-ending normalisation).
`text` and `html` are the part indices of the selected bodies, or `-`.

### messages/NNNN.txt

Seven sections in this fixed order. Each begins with its marker line, and the
sections are separated by exactly one empty line. There is no empty line
before the first marker and the file ends with a newline after its last line.

```
[message]
[headers]
[addresses]
[date]
[structure]
[body]
[attachments]
```

**`[message]`** — two lines:

```
id <NNNN>
source <q(source id)>
```

**`[headers]`** — one line per header field, in message order:

```
<lower-cased stripped name>: <q(value)>
```

where `value` is as defined at the end of
[Header parsing](#header-parsing). A message with no header fields
contributes no lines.

**`[addresses]`** — for each of `from`, `sender`, `reply-to`, `to`, `cc`,
`bcc` in that order, for each field with that name in message order, for
each address the field yields in order:

```
<name> <k> display=<q(display)> spec=<q(spec)>
```

`k` counts from 0 over all addresses of all fields with that name in that
message. Fields that yield no addresses contribute no lines. An empty
section is possible.

**`[date]`** — if there is no `Date` header, the single line `none`.
Otherwise:

```
raw <q(unfolded raw value)>
valid <yes|no>
```

and, when valid, three more lines:

```
utc <YYYY-MM-DDTHH:MM:SSZ>
offset <±HHMM>
epoch <integer>
```

**`[structure]`** — one line per part in pre-order:

```
<2 spaces per depth><index> <type>/<subtype><attributes>
```

`index` is the part number (no padding). The attributes follow, each
preceded by one space, present only when applicable, in this exact order:

| Attribute | When | Value |
|---|---|---|
| `charset=` | type is `text/*` | the normalised charset name |
| `cte=` | always | the encoding token |
| `disposition=` | the part has a `Content-Disposition` header | the disposition type |
| `filename=` | the part has a filename | `q(filename)` |
| `boundary=` | multipart container | `q(boundary)` |
| `parts=` | container (multipart or message) | number of children |
| `preamble=` | multipart container | byte length of the preamble |
| `epilogue=` | multipart container | byte length, or `none` |
| `size=` | leaf | byte length of the content |
| `adler32=` | leaf | eight hex digits |
| `role=` | leaf | `text`, `html` or `attachment` |

**`[body]`** — the selected bodies:

```
text <index> chars <n>
| <escaped line>
...
html <index> chars <n>
| <escaped line>
...
```

`n` is the number of Unicode code points in the part's text. The lines are
that text split on LF, dropping the last piece when it is empty (so a text
ending in LF does not produce a trailing empty line), each escaped with `esc`
and prefixed by `| `. If the text is empty there are no `|` lines. When
there is no text body the first line is `text none` (and likewise
`html none`); both lines are always present, `text` first.

For example, a part whose text is `a\nb\n` produces `| a` and `| b`; text
`a\n\n` produces `| a` and `| ` (the escaped empty line); text `a` produces
`| a`.

**`[attachments]`** — one line per attachment in part-index order:

```
<index> type=<type>/<subtype> filename=<q(filename)|-> size=<n> adler32=<8 hex> file=parts/NNNN/PPP.bin
```

An empty section is possible.

## Worked example

Input file `input` (an mbox), shown with `⏎` for LF:

```
From nobody Mon Sep  1 00:00:00 2025⏎
Subject: =?utf-8?Q?Caf=C3=A9?= report⏎
From: Ann Example <ann@example.com>⏎
To: bob@example.org, Carl <carl@example.org>⏎
Date: Mon, 1 Sep 2025 12:30:00 +0200⏎
MIME-Version: 1.0⏎
Content-Type: multipart/mixed; boundary="X"⏎
⏎
ignore me⏎
--X⏎
Content-Type: text/plain; charset=iso-8859-1⏎
⏎
caf<0xE9>⏎
--X⏎
Content-Type: application/octet-stream⏎
Content-Disposition: attachment; filename="a.bin"⏎
Content-Transfer-Encoding: base64⏎
⏎
AAECAw==⏎
--X--⏎
⏎
```

The file is 465 bytes. The separator line and its LF are 37 of them, and the
final LF is dropped by the mbox rule, so the message is 427 bytes.

`summary.txt`:

```
messages 1
0001 source="mbox:1" bytes=427 parts=3 attachments=1 text=1 html=-
```

`messages/0001.txt`:

```
[message]
id 0001
source "mbox:1"

[headers]
subject: "Café report"
from: "Ann Example <ann@example.com>"
to: "bob@example.org, Carl <carl@example.org>"
date: "Mon, 1 Sep 2025 12:30:00 +0200"
mime-version: "1.0"
content-type: "multipart/mixed; boundary=\"X\""

[addresses]
from 0 display="Ann Example" spec="ann@example.com"
to 0 display="" spec="bob@example.org"
to 1 display="Carl" spec="carl@example.org"

[date]
raw " Mon, 1 Sep 2025 12:30:00 +0200"
valid yes
utc 2025-09-01T10:30:00Z
offset +0200
epoch 1756722600

[structure]
0 multipart/mixed cte=7bit boundary="X" parts=2 preamble=9 epilogue=0
  1 text/plain charset=iso-8859-1 cte=7bit size=4 adler32=04680214 role=text
  2 application/octet-stream cte=base64 disposition=attachment filename="a.bin" size=4 adler32=000e0007 role=attachment

[body]
text 1 chars 4
| café
html none

[attachments]
2 type=application/octet-stream filename="a.bin" size=4 adler32=000e0007 file=parts/0001/002.bin
```

The first part's content is four bytes, `caf` and 0xE9: the LF that ended
that line belongs to the `--X` delimiter after it. Its `adler32` is
`04680214` and the attachment's is `000e0007`.

and `parts/0001/002.bin` holds the four bytes `00 01 02 03`.

Note the leading space in the `[date]` `raw` line: the raw value is
everything after the `:`, which here begins with a space.

## Guarantees

Every test input satisfies all of the following.

1. The input path exists and is a regular file or a directory. A directory
   contains at least one `.eml` file and every such file name matches
   `[A-Za-z0-9._+-]+`. An mbox file contains at least one message.
2. No message contains a CR that is not immediately followed by LF.
3. No message has more than 999 parts, no part is nested more than 20 levels
   deep, and no input has more than 9999 messages.
4. Every `multipart/*` and `message/rfc822` part has an encoding of `7bit`,
   `8bit`, `binary` or an unrecognised token — never `base64` or
   `quoted-printable`. (These encodings are forbidden on composite types by
   RFC 2045.)
5. The number of base64-alphabet characters in a `base64` part's body is
   never congruent to 1 modulo 4.
6. The largest test input is a 3.5 MB mbox of 257 messages; the largest
   single message is about 90 kB.

Everything else an input can contain is defined above, including bytes with
no cp1252 meaning, header lines that are not fields, boundaries with blanks
in them, and delimiter lines with nothing between them.

## Architecture and size

A complete implementation has these parts:

1. **Mailbox splitting** — a hundred lines: mbox separator scanning or
   directory listing.
2. **Header parsing** — a few hundred lines: line splitting, unfolding,
   name/value splitting, the `collapse` helper.
3. **Charset decoding** — a few hundred lines: the cp1252 table and the
   UTF-8 decoder with the maximal-subpart rule. The UTF-8 decoder must be
   written by hand unless the language's own decoder is known to follow the
   same rule.
4. **RFC 2047** — about two hundred lines: encoded-word recognition, Q and B
   decoding, the whitespace rule.
5. **Structured values and RFC 2231** — three to four hundred lines:
   segment splitting, quoted strings, parameter assembly, percent decoding.
6. **Addresses** — three to four hundred lines: the tokeniser, the element
   splitter and the mailbox/group matcher.
7. **Dates** — about two hundred lines, including `days_from_civil` and its
   inverse.
8. **Transfer decoding** — about two hundred lines: quoted-printable and
   base64 by hand.
9. **MIME tree building** — two to three hundred lines: boundary scanning,
   preamble and epilogue, recursion.
10. **Output** — three to four hundred lines: escaping and the seven
    sections.

Total: roughly two to three thousand lines in a typical systems language.
The Python reference is about 1250 lines.

Performance is not a concern: the largest test is a 3.5 MB mbox of 257
messages, which the Python reference processes in about a second. A per-test
limit of 120 seconds is ample.

The test suite has 36 cases. The first 27 are hand-written and go from a
one-message mailbox through each feature in turn; the last 9 are larger —
Apache James mime4j and Ruby `mail` test messages, and three generated
mailboxes of list traffic, business mail with deep MIME trees, and a mix
of both with header-heavy messages.
