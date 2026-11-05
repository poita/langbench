# typeset — the Codexa typesetting engine

Read a *Codexa* document (an invented markup language) together with an
optional settings file, lay the document out on numbered pages using
total-fit line breaking, Liang hyphenation, footnotes, floating figures, a
generated table of contents and running headers, and write a complete
description of every placed item.

This is a **directory-mode** problem. The program is invoked with exactly two
arguments:

```
<command> <input directory> <output directory>
```

The input directory holds the document. The output directory already exists
and is empty (an implementation may also create it if it is missing); the
program creates files inside it and writes nothing anywhere else. Nothing is
read from stdin; anything written to stdout or stderr is ignored. The exit
code must be 0, including for the error cases described in
[Errors](#errors) — an invalid document is reported in a file, not by an
exit code.

All text is UTF-8 with LF (`\n`) line endings and no byte-order mark. All
output files are written as UTF-8 with LF line endings.

Nothing in this problem is floating point. Every quantity is an integer and
every formula below is exact, so two correct implementations produce
byte-identical output.

## Contents

1. [Units and arithmetic](#units-and-arithmetic)
2. [Input layout](#input-layout)
3. [The settings file](#the-settings-file)
4. [Settings reference](#settings-reference)
5. [Font metric files](#font-metric-files)
6. [Hyphenation pattern files](#hyphenation-pattern-files)
7. [The Codexa markup language](#the-codexa-markup-language)
8. [Errors](#errors)
9. [Horizontal lists](#horizontal-lists)
10. [Hyphenation](#hyphenation)
11. [Line breaking](#line-breaking)
12. [Setting a line](#setting-a-line)
13. [Vertical lists](#vertical-lists)
14. [Tables](#tables)
15. [Footnotes](#footnotes)
16. [Floating figures](#floating-figures)
17. [Page breaking](#page-breaking)
18. [Running headers and footers](#running-headers-and-footers)
19. [The table of contents](#the-table-of-contents)
20. [Output](#output)
21. [Worked examples](#worked-examples)
22. [Guarantees](#guarantees)
23. [Architecture and size](#architecture-and-size)
24. [Limits and performance](#limits-and-performance)

## Units and arithmetic

Three kinds of integer quantity appear.

- **Lengths** are measured in **millipoints** (mp), one thousandth of a
  typographic point. `1pt = 1000mp`, `1in = 72000mp`, `1pc = 12000mp`,
  `1mm = 2835mp`, `1cm = 28350mp`. (The millimetre values are *defined* to be
  these integers; do not derive them.) Coordinates, widths, heights and page
  dimensions are all in millipoints.
- **Glyph space units** are thousandths of an em and appear only in font
  metric files. A glyph whose advance is `u` units, set at size `s`
  millipoints, advances `scale(u, s)` millipoints.
- **Plain integers** are counts, penalties, badnesses and demerits.

All arithmetic is performed on signed 64-bit integers. No intermediate value
in this specification exceeds 2^62 in magnitude, and implementations must not
overflow: in particular the demerits of a single line can reach
`(10 + 10000)^2 + 10000^2 = 200200100` and a paragraph's total demerits can
reach several billion, so 32-bit accumulators are not enough.

### Floor division and `scale`

Division is always **floor division** (rounding towards negative infinity),
written `a div b` with `b > 0`:

```
a div b  =  the unique q with a = q*b + r and 0 <= r < b
```

This differs from the `/` operator of C, C++, D, Go, Java and Rust, which
truncates towards zero. Implement it explicitly, for example:

```
fn fdiv(a, b):            # b > 0
    q = a / b             # truncating division
    if a % b != 0 and a < 0: q = q - 1
    return q
```

Scaling a glyph-space quantity to millipoints is

```
scale(u, s) = (u * s) div 1000
```

`u` may be negative (kerns are), `s` is always positive. `scale` is applied
once per quantity; never scale an already-scaled value again, and never scale
a sum of quantities that this specification sums *after* scaling (the two
differ by rounding, and the difference is observable).

### Lowercase roman numerals

Front-matter pages are labelled with lowercase roman numerals. For `n` in
1..3999 the numeral is produced by the usual greedy subtraction over the pairs

```
1000 m   900 cm   500 d   400 cd   100 c   90 xc
  50 l    40 xl    10 x    9 ix     5 v     4 iv    1 i
```

so 1 is `i`, 4 is `iv`, 9 is `ix`, 14 is `xiv`, 40 is `xl`, 2026 is `mmxxvi`.
The same greedy rule is applied unchanged above 3999 (an `@ol` marker can
reach 100000 or more), so 4000 is `mmmm` and 5001 is `mmmmmi`.

## Input layout

```
<input>/
    document.cdx     required — the Codexa document
    settings.cfg     optional — overrides for the layout settings
```

No other entry of the input directory is read. If `document.cdx` is missing
the program reports the error `missing-document` (see
[Errors](#errors)).

Font metrics and hyphenation patterns are **not** in the input directory.
They are read from a fixed `data` directory resolved **relative to the
process's current working directory**:

```
data/faces/<face>.cfm       the nine font faces
data/hyphen/<set>.chp       the hyphenation pattern sets
```

The test runner always starts the program with the current working directory
set to `problems/typeset/`, where that `data` directory lives. An
implementation must therefore open `data/faces/serif.cfm` (and the others) as
a path relative to the current working directory; it must not look for them
relative to the input directory, the output directory or the executable.

The nine faces are

```
serif  serif-bold  serif-italic  serif-bold-italic
sans   sans-bold   sans-italic   sans-bold-italic
mono
```

and the two pattern sets are `english` and `minimal`. An implementation may
read all eleven files eagerly or on demand; the files never change.

## The settings file

`settings.cfg` is a sequence of LF-separated lines. Each line is one of:

- **Blank**: empty, or containing only spaces and tabs. Ignored.
- **Comment**: its first character that is not a space or tab is `#`.
  Ignored.
- **Assignment**: `key = value`.

An assignment line matches

```
[ \t]* KEY [ \t]* "=" VALUE
```

where `KEY` is one or more characters from `a-z 0-9 -` and `VALUE` is the rest
of the line with leading and trailing spaces and tabs removed. A `#` inside
`VALUE` is a literal `#`, not a comment. `VALUE` may be empty.

Anything else is the error `bad-syntax`, reported at the line's first
character that is not a space or tab. A key that is not in
[Settings reference](#settings-reference) is `unknown-setting`, reported at
the first character of the key. A key that has already been assigned is
`duplicate-setting`, reported the same way.

If `settings.cfg` is absent every setting takes its default.

### Value types

**length** — `[-]? DIGITS [ "." DIGITS ] [ UNIT ]` where `UNIT` is one of
`pt`, `mm`, `cm`, `in`, `pc`, the fractional part has one to three digits, and
no unit means millipoints. The value in millipoints is

```
(whole * 10^k + frac) * unit_mp  div  10^k
```

where `k` is the number of fraction digits (0 when there is no fractional
part), `frac` is the fraction digits read as an integer, `unit_mp` is 1 for no
unit and otherwise 1000, 2835, 28350, 72000 or 12000, and a leading `-` negates
the result. So `2.5pt` is 2500, `0.5pt` is 500, `1.5mm` is 4252
(`15 * 2835 div 10 = 4252`), `-6pt` is -6000 and `734` is 734. Anything else
(including an empty value, a `+` sign, more than three fraction digits, a
missing digit before or after the point, or trailing characters) is
`bad-length`.

**integer** — `[-]? DIGITS`, no unit, no leading `+`. Otherwise
`bad-integer`.

**boolean** — exactly `on` or `off`. Otherwise `bad-boolean`.

**enum** — one of the words listed for that key. Otherwise `bad-enum`.

**family** — exactly `serif`, `sans` or `mono`. Otherwise `unknown-font`.

**patterns** — exactly `english` or `minimal`. Otherwise
`unknown-patterns`.

**text** — the value is read in a **single left-to-right scan**, and the
first problem met stops the scan:

- `\{`, `\}` and `\\` are the literal characters `{`, `}` and `\`. The two
  characters are consumed together, so an escaped brace never takes part in
  a placeholder and never closes one. A `\` followed by anything else, or
  by nothing, is `bad-escape` at the `\`.
- An unescaped `{` must begin a placeholder: the text from it up to the next
  `}` (whatever lies between, escapes included) is `{name}`, and `name` must
  be one of `page`, `pages`, `title`, `author`, `date`, `chapter`,
  `section`. Otherwise, including when there is no later `}`, it is
  `unknown-placeholder` at the `{`. The scan resumes after the `}`.
- An unescaped `}` met by the scan (one that does not close a placeholder)
  is `stray-brace` at the `}`.
- Every other character is literal.

So `\{page}` is `stray-brace` at its final `}` (the `{` was escaped, so the
`}` closes nothing), `}\q` is `stray-brace` at column 1 of the value, and
`{pa\ge}` is `unknown-placeholder` at the `{`.

Placeholders are substituted when the header or footer is rendered; the result
is plain text with no further markup.

Every value is additionally range-checked. A value outside the stated range is
`bad-value`.

Every one of `bad-length`, `bad-integer`, `bad-boolean`, `bad-enum`,
`unknown-font`, `unknown-patterns` and `bad-value` is reported at the **first
character of the value** — that is, at the first character after the `=` that
is not a space or a tab, or at the end-of-line position (one past the last
character) when the value is empty. `bad-escape`, `unknown-placeholder` and
`stray-brace` are reported at the offending character. Unless stated
otherwise, lengths must be `>= 0`.

## Settings reference

Lengths are shown with units for readability; the stored value is in
millipoints. Defaults written as expressions are evaluated after the explicit
settings have been read, so `footer-baseline` defaults to 36pt above the
bottom of whatever page height is in force.

### Page geometry

| key | type | default | range |
|---|---|---|---|
| `page-width` | length | `612pt` | `>= 36000` |
| `page-height` | length | `792pt` | `>= 36000` |
| `margin-top` | length | `72pt` | `>= 0` |
| `margin-bottom` | length | `72pt` | `>= 0` |
| `margin-left` | length | `72pt` | `>= 0` |
| `margin-right` | length | `72pt` | `>= 0` |
| `header-baseline` | length | `36pt` | `>= 0` |
| `footer-baseline` | length | `page-height - 36pt` | `>= 0` |
| `page-start` | integer | `1` | `1..3000` |

`page-start` is the arabic number of the first body page: body page `m`
(1-based, counted after the front pages) is labelled `page-start + m - 1`, in
decimal. It does not affect the roman labels of the front pages, nor the
`{pages}` placeholder, which is a count of body pages.

The **body rectangle** is

```
body-x      = margin-left
body-y      = margin-top
body-width  = page-width  - margin-left - margin-right
body-height = page-height - margin-top  - margin-bottom
```

and `body-bottom = body-y + body-height`. `body-width` and `body-height` must
both be at least 36000; otherwise the offending margin setting (or, if the
margins are all defaults, the page dimension) is `bad-value`. Concretely: the
check runs after all settings are read; the reported position is the first
character of the value of the last explicitly assigned one of the six keys
`page-width`, `page-height`, `margin-top`, `margin-bottom`, `margin-left`,
`margin-right` (last in file order), and `0:0` if none of them was assigned.

### Body text

| key | type | default | range |
|---|---|---|---|
| `body-font` | family | `serif` | |
| `body-size` | length | `10pt` | `1000..200000` |
| `leading` | length | `12pt` | `>= 1000` |
| `line-skip` | length | `1pt` | `>= 0` |
| `align` | enum `justify left right center` | `justify` | |
| `par-indent` | length | `18pt` | `>= 0` |
| `par-space` | length | `0pt` | `>= 0` |

`par-space` is the vertical space between two consecutive paragraphs.

### Line breaking

| key | type | default | range |
|---|---|---|---|
| `tolerance` | integer | `1000` | `0..10000` |
| `line-penalty` | integer | `10` | `0..10000` |
| `hyphen-penalty` | integer | `50` | `-9999..9999` |
| `ex-hyphen-penalty` | integer | `50` | `-9999..9999` |
| `adj-demerits` | integer | `10000` | `0..1000000` |
| `double-hyphen-demerits` | integer | `10000` | `0..1000000` |
| `final-hyphen-demerits` | integer | `5000` | `0..1000000` |
| `ragged-stretch` | integer | `3` | `0..100` |
| `hyphenate` | boolean | `on` | |
| `hyphen-patterns` | patterns | `english` | |

### Headings

| key | type | default | range |
|---|---|---|---|
| `heading-font` | family | `sans` | |
| `heading-bold` | boolean | `on` | |
| `heading-italic` | boolean | `off` | |
| `heading-align` | enum `justify left right center` | `left` | |
| `heading-number` | boolean | `on` | |
| `heading-number-gap` | length | `6pt` | `>= 0` |
| `h1-newpage` | boolean | `off` | |
| `h1-size` | length | `20pt` | `1000..200000` |
| `h2-size` | length | `14pt` | `1000..200000` |
| `h3-size` | length | `12pt` | `1000..200000` |
| `h4-size` | length | `11pt` | `1000..200000` |
| `h1-leading` | length | `24pt` | `>= 1000` |
| `h2-leading` | length | `17pt` | `>= 1000` |
| `h3-leading` | length | `14pt` | `>= 1000` |
| `h4-leading` | length | `13pt` | `>= 1000` |
| `h1-space-before` | length | `18pt` | `>= 0` |
| `h2-space-before` | length | `14pt` | `>= 0` |
| `h3-space-before` | length | `12pt` | `>= 0` |
| `h4-space-before` | length | `11pt` | `>= 0` |
| `h1-space-after` | length | `9pt` | `>= 0` |
| `h2-space-after` | length | `7pt` | `>= 0` |
| `h3-space-after` | length | `6pt` | `>= 0` |
| `h4-space-after` | length | `5pt` | `>= 0` |

### Lists, quotes and preformatted text

| key | type | default | range |
|---|---|---|---|
| `list-indent` | length | `18pt` | `>= 0` |
| `list-marker-gap` | length | `4pt` | `>= 0` |
| `list-space` | length | `6pt` | `>= 0` |
| `list-item-space` | length | `0pt` | `>= 0` |
| `quote-indent` | length | `18pt` | `>= 0` |
| `quote-space` | length | `6pt` | `>= 0` |
| `pre-font` | family | `mono` | |
| `pre-size` | length | `9pt` | `1000..200000` |
| `pre-leading` | length | `11pt` | `>= 1000` |
| `pre-indent` | length | `0pt` | `>= 0` |
| `pre-space` | length | `6pt` | `>= 0` |

`list-space` is the space above and below a whole list; `list-item-space` the
extra space between consecutive items of one list. `quote-indent` is applied
on both sides of a block quote.

### Tables and rules

| key | type | default | range |
|---|---|---|---|
| `table-col-gap` | length | `8pt` | `>= 0` |
| `table-row-space` | length | `2pt` | `>= 0` |
| `table-rule-space` | length | `2pt` | `>= 0` |
| `table-rule-thickness` | length | `400` | `>= 1` |
| `table-space` | length | `6pt` | `>= 0` |
| `table-leading` | length | `12pt` | `>= 1000` |
| `rule-thickness` | length | `500` | `>= 1` |
| `rule-space` | length | `6pt` | `>= 0` |

### Footnotes

| key | type | default | range |
|---|---|---|---|
| `footnote-font` | family | `serif` | |
| `footnote-size` | length | `8pt` | `1000..200000` |
| `footnote-leading` | length | `10pt` | `>= 1000` |
| `footnote-indent` | length | `10pt` | `>= 0` |
| `footnote-mark-gap` | length | `2pt` | `>= 0` |
| `footnote-mark-size` | length | `6pt` | `1000..200000` |
| `footnote-mark-raise` | length | `2pt` | `>= 0` |
| `footnote-item-space` | length | `2pt` | `>= 0` |
| `footnote-rule-width` | length | `120pt` | `>= 0` |
| `footnote-rule-thickness` | length | `400` | `>= 1` |
| `footnote-space-before` | length | `6pt` | `>= 0` |
| `footnote-space-after` | length | `3pt` | `>= 0` |
| `footnote-min-split` | integer | `1` | `1..100` |
| `footnote-max-height` | length | `body-height div 2` | `>= 1000` |
| `mark-size` | length | `7pt` | `1000..200000` |
| `mark-raise` | length | `3pt` | `>= 0` |

`mark-size` and `mark-raise` govern the reference mark in the running text;
the `footnote-mark-*` keys govern the mark in front of the footnote itself.
`footnote-max-height` is how much of a page the footnote area may *reserve*
while the page break is being chosen; a page whose footnotes need more than
that splits them (see [Page breaking](#page-breaking)). Its default is
`body-height div 2`, computed after the page geometry is known.

### Figures

| key | type | default | range |
|---|---|---|---|
| `figure-width` | length | `0` | `>= 0` |
| `figure-frame` | boolean | `on` | |
| `figure-caption-font` | family | `serif` | |
| `figure-caption-size` | length | `9pt` | `1000..200000` |
| `figure-caption-leading` | length | `11pt` | `>= 1000` |
| `figure-caption-align` | enum `justify left right center` | `center` | |
| `figure-caption-space` | length | `4pt` | `>= 0` |
| `figure-caption-prefix` | text | `Figure` | |
| `figure-caption-gap` | length | `4pt` | `>= 0` |
| `float-space-after` | length | `12pt` | `>= 0` |
| `float-min-body` | length | `24pt` | `>= 0` |

`figure-width` of `0` means "the full measure of the body". A
`figure-caption-prefix` that contains a placeholder is `bad-value`: the
prefix is used literally.

### Page breaking

| key | type | default | range |
|---|---|---|---|
| `widows` | integer | `2` | `1..20` |
| `orphans` | integer | `2` | `1..20` |
| `keep-with-next` | boolean | `on` | |

### Table of contents

| key | type | default | range |
|---|---|---|---|
| `toc-depth` | integer | `2` | `0..4` |
| `toc-font` | family | `serif` | |
| `toc-size` | length | `10pt` | `1000..200000` |
| `toc-leading` | length | `14pt` | `>= 1000` |
| `toc-indent` | length | `18pt` | `>= 0` |
| `toc-number-gap` | length | `6pt` | `>= 0` |
| `toc-reserve` | length | `30pt` | `>= 0` |
| `toc-leader` | text | `.` | 1..8 characters |
| `toc-leader-gap` | length | `3pt` | `>= 0` |
| `toc-entry-space` | length | `0pt` | `>= 0` |
| `toc-title` | text | `Contents` | |
| `toc-title-font` | family | `sans` | |
| `toc-title-size` | length | `20pt` | `1000..200000` |
| `toc-title-space-after` | length | `12pt` | `>= 0` |

`toc-leader` must be a non-empty string of one to eight characters, none of
which is a space; otherwise `bad-value`. Placeholders are not allowed in
`toc-leader` or `toc-title` (`bad-value`).

### Running headers and footers

| key | type | default | range |
|---|---|---|---|
| `header-font` | family | `sans` | |
| `header-size` | length | `9pt` | `1000..200000` |
| `header-left` | text | *empty* | |
| `header-center` | text | *empty* | |
| `header-right` | text | *empty* | |
| `footer-left` | text | *empty* | |
| `footer-center` | text | *empty* | |
| `footer-right` | text | *empty* | |
| `header-left-even` | text | *same as* `header-left` | |
| `header-center-even` | text | *same as* `header-center` | |
| `header-right-even` | text | *same as* `header-right` | |
| `footer-left-even` | text | *same as* `footer-left` | |
| `footer-center-even` | text | *same as* `footer-center` | |
| `footer-right-even` | text | *same as* `footer-right` | |

An `-even` key that is not assigned takes the value of the corresponding
plain key *after* the plain key's own default or assignment has been
resolved. An empty slot produces no output at all.
## Font metric files

A `.cfm` file (Codexa Font Metrics) describes one face. It is a sequence of
LF-separated lines. On every line, everything from the first `#` to the end of
the line is removed, then leading and trailing spaces and tabs are removed; a
line that is then empty is ignored. Every other line is a record whose fields
are separated by runs of spaces and tabs.

```
cfm 1                       first record; format version, always 1
face <name>                 the face name, matching the file name
ascent <units>              distance from the baseline to the top of the line
descent <units>             distance from the baseline to the bottom
space <adv> <str> <shr>     the inter-word glue of this face
extra <units>               extra width added after a sentence-ending period
default <units>             advance used for a code point with no `glyph`
glyph <codepoint> <units>   the advance width of one glyph
kern <cp1> <cp2> <units>    the kern inserted between that ordered pair
```

`<units>` are thousandths of an em and are non-negative except for `kern`,
which is usually negative. `<codepoint>` is a decimal Unicode scalar value.
Each record except `glyph` and `kern` occurs exactly once; `glyph` occurs once
per listed code point and `kern` once per listed ordered pair. The supplied
files are well formed and an implementation does not need to validate them.

Measurement uses only these numbers:

- `adv(c)` is the `glyph` advance of code point `c`, or `default` if `c` has no
  `glyph` record.
- `kern(a, b)` is the `kern` value of the ordered pair `(a, b)`, or 0.
- `ascent`/`descent` are the vertical extent of any line containing material
  in this face.
- `space`/`extra` produce inter-word glue, see
  [Horizontal lists](#horizontal-lists).

The nine supplied faces have these vertical metrics and glue (for reference;
the files are authoritative):

| face | ascent | descent | space | stretch | shrink | extra | default |
|---|---|---|---|---|---|---|---|
| `serif` | 731 | 223 | 254 | 127 | 85 | 112 | 512 |
| `serif-bold` | 742 | 229 | 276 | 138 | 92 | 122 | 560 |
| `serif-italic` | 728 | 226 | 251 | 120 | 80 | 110 | 506 |
| `serif-bold-italic` | 739 | 232 | 273 | 130 | 87 | 120 | 552 |
| `sans` | 764 | 237 | 281 | 140 | 94 | 124 | 528 |
| `sans-bold` | 773 | 243 | 302 | 151 | 101 | 133 | 580 |
| `sans-italic` | 761 | 240 | 278 | 134 | 89 | 122 | 524 |
| `sans-bold-italic` | 770 | 246 | 299 | 145 | 97 | 131 | 572 |
| `mono` | 700 | 215 | 600 | 0 | 0 | 0 | 600 |

`mono` is monospaced: every glyph advances 600 units and it has no kerns, no
glue stretch and no glue shrink.

### Resolving a face

A **style** is a triple (family, bold, italic) where family is `serif`, `sans`
or `mono`. The face name is

| family | bold | italic | face |
|---|---|---|---|
| `serif` | off | off | `serif` |
| `serif` | on | off | `serif-bold` |
| `serif` | off | on | `serif-italic` |
| `serif` | on | on | `serif-bold-italic` |
| `sans` | off | off | `sans` |
| `sans` | on | off | `sans-bold` |
| `sans` | off | on | `sans-italic` |
| `sans` | on | on | `sans-bold-italic` |
| `mono` | *any* | *any* | `mono` |

## Hyphenation pattern files

A `.chp` file (Codexa Hyphenation Patterns) is read with the same line rules
as a `.cfm` file (strip from `#`, trim, skip empty).

```
chp 1                    first record; format version, always 1
left <n>                 minimum letters before the first break
right <n>                minimum letters after the last break
pattern <text>           one Liang pattern
exception <text>         one explicit exception
```

A **pattern** is a string of lowercase letters `a`-`z`, the boundary marker
`.` (which may appear only as the first or last character) and single decimal
digits. Reading the pattern left to right, the letters and `.` form the
pattern's *key* of length `m`, and the digits give values at the `m + 1`
inter-letter positions of the key: a digit written immediately before key
character `i` (0-based) sets position `i`, and a digit written after the last
key character sets position `m`. Positions with no digit are 0. For example
`.anti3` has key `.anti` and values `[0,0,0,0,0,3]`, `c2h` has key `ch` and
values `[0,2,0]`, and `3tion` has key `tion` and values `[3,0,0,0,0]`.

An **exception** is a lowercase word with `-` at each permitted break, for
example `al-go-rithm`. The word with the hyphens removed is the key; the break
positions are the counts of letters preceding each hyphen.

The two supplied sets are `english` (145 patterns, 9 exceptions, `left 2`,
`right 3`) and `minimal` (7 patterns, 2 exceptions, `left 2`, `right 2`).
Both were invented for this problem and are not derived from any existing
pattern set. Within one file no two patterns have the same key and no two
exceptions have the same key, so a map from key to values is enough.

## The Codexa markup language

A Codexa document is a sequence of LF-separated lines of UTF-8 text. Parsing
is strictly line-based: every line is classified before its contents are
examined.

- A **blank line** contains only spaces (U+0020). Blank lines separate
  blocks and are otherwise ignored.
- A **directive line** is a line whose first non-space character is `@`.
- Any other non-blank line is a **text line**.

Documents contain no TAB characters, no CR characters and no C0 control
characters other than LF (see [Guarantees](#guarantees)).

### Grammar

```ebnf
document    = [ doc-block ] [ toc-block ] { block } ;

block       = heading | paragraph | quote | group | ulist | olist
            | table | pre | figure | rule | vspace | newpage ;

doc-block   = "@doc" nl { meta-line } "@end" nl ;
meta-line   = key "=" rest-of-line nl ;

toc-block   = "@toc" [ attrs ] nl ;

heading     = ("@h1"|"@h2"|"@h3"|"@h4") [ "*" ] inline-rest ;
paragraph   = text-line { cont-line } ;
quote       = "@q" nl { block } "@end" nl ;
group       = "@block" attrs nl { block } "@end" nl ;
ulist       = "@ul" [ attrs ] nl { item } "@end" nl ;
olist       = "@ol" [ attrs ] nl { item } "@end" nl ;
item        = "@li" inline-rest { cont-line } { block } ;
table       = "@table" attrs nl { row | hrule } "@end" nl ;
row         = cell { "|" cell } nl ;
hrule       = "@hrule" nl ;
pre         = "@pre" [ attrs ] nl { raw-line } "@end" nl ;
figure      = "@fig" attrs nl { text-line | blank-line } "@end" nl ;
rule        = "@rule" nl ;
vspace      = "@vspace" attrs nl ;
newpage     = "@newpage" nl ;

attrs       = { sp+ name "=" value } ;
value       = bare | '"' { any-but-quote } '"' ;
inline-rest = { sp } inline nl ;
cont-line   = text-line ;
```

`cont-line` applies to `@li` and to paragraphs: the text of such a block
continues on every immediately following text line, until a blank line, a
directive line or the end of the file. A **heading takes no continuation
lines**: its inline text is the rest of its own directive line and nothing
else, so a text line immediately after `@h1 Title` starts a paragraph.

Each text line of a block contributes its text from its first non-space
character on: the leading spaces of every text line (continuation lines and
`@fig` caption lines included) are dropped before anything else. Trailing
spaces are kept. Consecutive source lines of one block are then joined by a
single space, which the whitespace rules of
[Whitespace in inline text](#whitespace-in-inline-text) turn into one
inter-word glue together with any spaces at the end of the first line. A run
of spaces at the very end of a block's text is removed by rule 2 of those
rules, and an escaped space (`\ `) is never a space for this purpose and is
never removed. So a line ending in `ghi\` followed by a line `  jkl` gives
`ghi`, one rigid space (the `\` escapes the joining space) and `jkl`, with
no glue: the second line's leading spaces were dropped before the join.

A `@fig` block is not a `cont-line` construct in the usual sense: blank lines
inside it are ignored, **every** text line between the `@fig` line and the
matching `@end` is joined into the caption with one space, and any other
directive there is `block-not-allowed`. The caption's inline content is
scanned (and its inline errors are found) only when the `@fig`'s `@end` is
reached. A `block-not-allowed` directive inside the `@fig`, or a
`missing-end` for it, is therefore reported even when an earlier caption line
contains an inline error.

Because the lines are joined with a space *before* the inline content is
scanned, a `\` that is the last character of a source line other than the
block's last line escapes that joining space: it becomes `\ `, a rigid
space, and is not an error. Only a `\` at the very end of the block's text
is `bad-escape`.

### Directives and their attributes

The **directive name** is the maximal run of non-space characters that starts
at the `@`; for `@h1`..`@h4` a single trailing `*` is part of the name and
makes the heading unnumbered. A name that is not one of the names in the
table below (or `@end`) is `unknown-block`, reported at the `@`. So `@h1x`
and `@h1*x` are both `unknown-block`.

Attributes follow the directive name, separated by spaces. An attribute is
`name=value`, where `name` is a maximal run of characters from `A-Za-z0-9-`;
`value` is either a **bare** value (one or more characters from
`A-Za-z0-9.+-%`) or a **quoted** value (`"` ... `"`, containing any
characters other than `"` and LF). Attribute names are checked against the
list for that directive (`bad-attribute` otherwise) and never repeat
(`bad-attribute` on the second occurrence); both are reported at the first
character of the name. A token that is not of the form `name=` is also
`bad-attribute`, reported at its first character, so a directive that takes
no attributes rejects any trailing word — including `@end`.

A missing required attribute is `missing-attribute`, reported at the `@` of
the directive name. A value of the wrong shape or out of range is
`bad-attribute-value`, reported at the first character of the value — the
opening `"` for a quoted value, and for an empty bare value the character
right after the `=` (one past the end of the line when the `=` is the line's
last character). An unterminated quoted value, and a value (bare, or quoted
and then closed) immediately followed by a character that is neither a space
nor the end of the line, are both `bad-attribute-value` at that same position
(`width="10pt"x` is `bad-attribute-value` at the opening `"`).

Quoting is transparent: the value of a quoted attribute is the text between
the quotes, and it is checked exactly as a bare value with that text would
be, so `height="10pt"` is valid and `height=""` is a (malformed) empty
length.

The checks on one directive line run in this order, and the first failure
stops everything:

0. The directive name (`unknown-block`).
1. The attribute tokens are read left to right. For each token the name is
   checked (`bad-attribute`: not of the form `name=`, unknown, or repeated)
   and then the value's lexical form (`bad-attribute-value`: an empty bare
   value, an unterminated quoted value, or a value immediately followed by a
   character that is neither a space nor the end of the line).
2. If a required attribute is absent: `missing-attribute`.
3. **Placement**: `unexpected-end`, `block-not-allowed` and `duplicate-toc`
   (see below).
4. Each value's shape and range, in source order, left to right
   (`bad-attribute-value`).
5. Checks that need two attributes at once — only the rule that `@table`'s
   `align` has exactly `cols` letters — reported at the first character of
   the `align` value.

So `@table align=xyz` is `missing-attribute` (step 2 runs before the letters
of `align` are examined), while `@table cols=0 foo=1` is `bad-attribute` at
`foo`. Inside a `@table`, `@vspace` with no `height` is `missing-attribute`,
`@vspace foo=1` is `bad-attribute`, but `@vspace height=abc` is
`block-not-allowed` (placement, step 3, comes before the value check of
step 4). `@end foo=1` with nothing open is `bad-attribute`, not
`unexpected-end`. The heading directives and `@li` take no attributes (the
rest of their line is inline text), so for them step 3 follows step 0
directly and the inline text is checked afterwards.

| directive | attributes | notes |
|---|---|---|
| `@doc` | none | must be the first block of the document |
| `@toc` | `title` (text) | must be the first block, or the second if `@doc` is present; at most one |
| `@h1`..`@h4` | none | a trailing `*` on the name makes the heading unnumbered and excluded from the table of contents |
| `@q` | none | |
| `@block` | `align`, `indent`, `right-indent`, `font`, `size`, `leading` | all optional; each overrides the corresponding setting for the blocks inside |
| `@ul` | none | |
| `@ol` | `start` (integer `1..100000`, default 1) | |
| `@li` | none | only inside `@ul` or `@ol` |
| `@table` | `cols` (integer `1..20`, **required**), `align` (one letter per column from `lrc`, default all `l`) | |
| `@hrule` | none | only inside `@table` |
| `@pre` | none | |
| `@fig` | `height` (length `>= 0`, **required**), `width` (length `>= 0`, default `figure-width`) | |
| `@rule` | none | |
| `@vspace` | `height` (length `>= 0`, **required**) | |
| `@newpage` | none | |

`align` values are `justify`, `left`, `right`, `center`; `font` values are
`serif`, `sans`, `mono`; `indent`, `right-indent`, `size` and `leading` are
lengths with the same ranges as the corresponding settings. For `@table`,
`align` must have exactly `cols` letters.

The `title` attribute of `@toc` is used **literally**: its characters are the
TOC title text, with no escape processing and no placeholders.

An `@end` line closes the innermost open block, after implicitly closing any
open `@li` item (an item is closed by the next `@li` or by the `@end` of its
list, never by an `@end` of its own). `@end` with nothing open is
`unexpected-end`. End of input with something open is `missing-end`, reported
at the line after the last line of the file, column 1. A directive name that
is not in the table above is `unknown-block`. A directive used where it is
not allowed (`@li` outside a list, `@hrule` outside a table, `@doc` not
first, `@toc` in the wrong place, a second `@toc`, a block inside `@doc`,
`@pre`, `@table` or `@fig`) is `block-not-allowed` — except that a second
`@toc` is `duplicate-toc`. `unknown-block`, `block-not-allowed`,
`duplicate-toc` and `unexpected-end` are all reported at the `@` of the
directive.

When a second `@toc` is also misplaced, the innermost open block decides:
if it is a `@ul` or `@ol` with no `@li` yet, a `@table`, a `@doc` or a
`@fig` — the blocks that admit no ordinary directive at all — the result is
`block-not-allowed`; anywhere else (at the top level, or inside a `@q`, a
`@block` or a list item) it is `duplicate-toc`.

`@li` is allowed only when the innermost open block is the list itself or an
`@li` item of that list, so an `@li` inside a `@q` that is inside an item is
`block-not-allowed`.

Inside `@ul` and `@ol`, the only things allowed before the first `@li` are
blank lines; a text line or any other directive there is `text-not-allowed`
(for a text line, reported at its first character that is not a space) or
`block-not-allowed` (for a directive). Inside `@table`,
text lines are rows and the only directives allowed are `@hrule` and `@end`.
Inside `@doc`, every non-blank text line must be `key = value`; any other
text line is `bad-syntax`, reported at the line's first character that is not
a space. A directive line other than `@end` there is `block-not-allowed` at
its `@` (after the directive name itself has been accepted, so an unknown
name is still `unknown-block`).

Inside `@pre`, the block is terminated by the first line whose characters
with every leading and trailing space removed are exactly `@end`. Every
earlier line, blank lines included, is taken verbatim except that trailing
spaces are removed from it. No escape, style or glue processing is applied,
and no hyphenation is attempted whatever `pre-font` is: a `@pre` source line
is **one** BOX holding all of the line's characters, spaces included (and no
BOX at all when the line is empty).

### `@doc` metadata

A `meta-line` is `key = value` with the same shape as a settings assignment
(`[ \t]* KEY [ \t]* "=" VALUE`, `KEY` one or more characters from `a-z 0-9 -`,
`VALUE` trimmed). A line that does not have that shape is `bad-syntax`. The
permitted keys are `title`, `author` and `date`; anything else is
`unknown-meta`, reported at the first character of the key. A repeated key is
`duplicate-meta`, reported the same way. Values are literal text: no escapes,
no markup, no placeholders, and in particular no inline construct is ever
recognised inside them, so no inline error code can arise there. Unassigned
keys are the empty string.

### Inline markup

Within inline text the following constructs are recognised, scanning left to
right.

```ebnf
inline      = { chunk } ;
chunk       = style | escape | nbsp | disc | char ;
style       = "{" tag "|" inline "}" ;
tag         = "b" | "i" | "m" | "+" | "-" | "n" ;
escape      = "\" ( "{" | "}" | "|" | "\" | "@" | "~" | " " ) ;
nbsp        = "~" ;
disc        = "\-" ;
char        = any character except "{" "}" "\" "~" ;
```

| construct | meaning |
|---|---|
| `{b|…}` | bold on inside |
| `{i|…}` | italic on inside |
| `{m|…}` | family `mono` inside |
| `{+|…}` | one size step larger inside |
| `{-|…}` | one size step smaller inside |
| `{n|…}` | a footnote; the inside is the footnote's text |
| `~` | a non-breaking space |
| `\-` | a discretionary hyphenation point |
| `\ ` | a literal space that is never a break and never collapses |
| `\{ \} \| \\ \@ \~` | the literal character |

A size step multiplies by 6/5 going up and by 5/6 going down:

```
step-up(s)   = (s * 6) div 5
step-down(s) = (s * 5) div 6
```

Nesting is arbitrary and the styles compose: `{b|{i|x}}` is bold italic,
`{+|{+|x}}` is two steps larger. A `{` that is not followed by a valid tag and
`|` is `unknown-inline` at the `{`. A `{` whose matching `}` is missing before
the end of the block is `unclosed-inline`, reported at the **innermost** such
`{` — the one opened last, which is where a left-to-right scan discovers the
missing `}`. A `}` with no open `{` is `stray-brace` at the `}`. A `\`
followed by a character not in the escape list, and a `\` that is the last
character of a block's text, are `bad-escape` at the `\`.

`{n|…}` may not be nested inside another `{n|…}` (`nested-footnote` at the
inner `{`), and it is forbidden inside a heading and a figure caption
(`footnote-not-allowed` at the `{`); a table cell cannot contain one at all,
as explained below. Inside a `@pre` block and a
`@doc` value nothing is scanned at all, so no footnote can be written there
in the first place. A footnote's text may contain the other inline
constructs; the style inside a `{n|…}` starts afresh from the footnote
context rather than from the style in force at the reference point.

`|` is an ordinary character everywhere except immediately after a tag inside
`{`…`}` and, in a table row, as the cell separator. In a table row a literal
`|` must be written `\|`.

A table row is split into cells **before** its inline content is parsed:
scanning the row's line left to right, a `\` consumes the character after it
(so neither can be a separator), and every other `|` is a cell separator. The
cells' texts are then parsed as inline content, each with its leading and
trailing spaces removed in the sense of rule 2 of
[Whitespace in inline text](#whitespace-in-inline-text). A row with a number
of cells different from `cols` is `cell-count`; because the split happens
first, `cell-count` is reported before any inline content of that row is
examined.

The split does not know about inline constructs, so the `|` of a style tag
or a footnote splits the row like any other: a table cell can never contain
`{b|…}`, `{i|…}`, `{m|…}`, `{+|…}`, `{-|…}` or `{n|…}`. A row such as
`{b|x} | y` in a two-column table is the three cells `{b`, `x}` and `y`
(`cell-count`); with three columns it is valid as far as the split goes and
the first cell's text `{b` is then `unknown-inline` at its `{`. For the same
reason `footnote-not-allowed` never arises in a table cell. Escapes, `~`,
`\ ` and `\-` work in cells as everywhere else.

### Whitespace in inline text

Within one block's inline text, after the constructs above have been
recognised:

1. Every run of one or more spaces becomes a single **inter-word glue**.
2. A glue at the very start or very end of the block's text is removed.
3. A source line break between two continuation lines is itself a run of
   spaces for the purpose of rule 1 (the lines are joined with a space).
4. `~`, `\ ` and `\-` are not spaces and do not take part in rules 1 and 2.

So `a  b` and `a b` are identical, and `{b|a} {i|b}` has one glue between the
two fragments. A glue carries the style in force *at the position of the first
space it came from*.

## Errors

If the input is invalid the program writes exactly one file,
`error.txt`, containing exactly one line:

```
<file>:<line>:<col>: <code>
```

followed by a newline, and writes neither `layout.txt` nor `report.txt`. The
exit code is still 0.

- `<file>` is `settings.cfg`, `document.cdx` or `-` (for `missing-document`).
- `<line>` is the 1-based line number, `<col>` the 1-based column measured in
  Unicode scalar values (so the first character of a line is column 1).
- `<code>` is one of the codes below.

Only the **first** error is reported. The scan order is:

1. If `document.cdx` does not exist: `-:0:0: missing-document`. Nothing else
   is checked.
2. `settings.cfg`, if present, is validated line by line in file order. For
   one line, the checks happen in this order: line shape, key known, key not
   duplicated, value well formed, value in range. The first failure stops
   everything.
3. The six-key body-rectangle check of
   [Page geometry](#page-geometry).
4. `document.cdx` is parsed in source order. Within a block the checks happen
   in this order: the directive name, then the attributes left to right, then
   the block's own text content in source order (and within one line, left to
   right), then its nested blocks in order. Checks that can only be made at
   the end of a construct (`cell-count`, `missing-end`) are reported at the
   position stated for that code. The inline text of a paragraph or an
   `@li` is scanned when that text ends (at the blank line, directive line
   or end of file that ends it), before the line that ends it is examined,
   so its errors precede any error on that line and precede `missing-end`.
   A figure caption is the exception described in
   [Grammar](#grammar): it is scanned at its `@end`.

| code | meaning |
|---|---|
| `missing-document` | `document.cdx` is absent |
| `bad-syntax` | a line is not any of the forms allowed where it appears |
| `unknown-setting` | no such settings key |
| `duplicate-setting` | the key was already assigned |
| `bad-length` | not a valid length literal |
| `bad-integer` | not a valid integer literal |
| `bad-boolean` | not `on` or `off` |
| `bad-enum` | not one of the listed words |
| `unknown-font` | not `serif`, `sans` or `mono` |
| `unknown-patterns` | not `english` or `minimal` |
| `bad-value` | valid literal, but outside the allowed range |
| `bad-escape` | `\` followed by a character that cannot be escaped |
| `unknown-placeholder` | `{name}` in a text setting with an unknown name |
| `stray-brace` | `}` that closes nothing |
| `unknown-block` | unknown `@directive` |
| `block-not-allowed` | a directive that is not allowed in this position |
| `duplicate-toc` | a second `@toc` |
| `unexpected-end` | `@end` with no open block |
| `missing-end` | end of file with a block still open |
| `bad-attribute` | unknown or repeated attribute name |
| `missing-attribute` | a required attribute is absent |
| `bad-attribute-value` | attribute value of the wrong shape or out of range |
| `cell-count` | a table row has the wrong number of cells |
| `text-not-allowed` | a text line where no text is allowed |
| `unknown-meta` | unknown key inside `@doc` |
| `duplicate-meta` | repeated key inside `@doc` |
| `unknown-inline` | `{` not starting a known inline tag |
| `unclosed-inline` | `{` whose `}` is missing |
| `nested-footnote` | `{n|` inside another `{n|` |
| `footnote-not-allowed` | `{n|` where footnotes are forbidden |

`cell-count` is reported at column 1 of the offending row line.
## Horizontal lists

Every piece of running text in the document — a paragraph, a heading, a list
item, a block quote's paragraphs, a table cell, a figure caption, a footnote
and a table-of-contents entry — is turned into a **horizontal list** and then
broken into lines. A horizontal list is built from a block's inline text
together with a **context**:

| context field | meaning |
|---|---|
| `family`, `bold`, `italic` | the initial style |
| `size` | the initial size in millipoints |
| `leading` | baseline-to-baseline distance for this list |
| `left` | the x coordinate of the left edge of every line |
| `measure` | the width available to every line |
| `first-indent` | extra indent applied to the first line only |
| `align` | `justify`, `left`, `right` or `center` |
| `hyphenate` | whether Liang hyphenation is applied |

Each block kind supplies its own context; see
[Vertical lists](#vertical-lists). `first-indent` is 0 for every kind except
a paragraph, where it is `par-indent`.

### Resolving styles

Scanning the inline text, a *style state* (family, bold, italic, size) starts
at the context's initial style and is modified by the inline tags:

- `{b|…}`: `bold = on` inside.
- `{i|…}`: `italic = on` inside.
- `{m|…}`: `family = mono` inside.
- `{+|…}`: `size = step-up(size)` inside.
- `{-|…}`: `size = step-down(size)` inside.
- `{n|…}`: the inside is removed from this list entirely and becomes a
  separate horizontal list (see [Footnotes](#footnotes)); at the reference
  point a **mark box** is produced.

Entering a tag saves the state, leaving it restores it. The **face** of a
character is resolved from (family, bold, italic) by the table in
[Resolving a face](#resolving-a-face). A character's **raise** is 0 except
inside a mark.

### Items

A horizontal list is a sequence of items.

**BOX** — a run of glyphs. Fields: face, size, raise, the text, and the width

```
box_units = sum over the box's characters of adv(c)
          + sum over adjacent pairs (c_i, c_i+1) of kern(c_i, c_i+1)
box_width = scale(box_units, size)
```

Note the single `scale`: the kerns are summed in glyph space and the total is
scaled once. A **rigid box** is a BOX with no text and no face: it is used
for `~` and `\ `, whose width is `scale(space, size)` of the face in force,
and for the fixed gaps of
[The heading number](#the-heading-number),
[The figure block](#the-figure-block) and
[The TOC's vertical list](#the-tocs-vertical-list). A rigid box advances the
x coordinate by its width, emits nothing in the output, and — having no face
— contributes nothing to a line's ascent or depth. "A line with no boxes at
all", in [Vertical metrics of a line](#vertical-metrics-of-a-line), means a
line with no BOX that has text.

**GLUE** — stretchable space between words. Fields: natural width `w`,
stretch `y`, shrink `z`, and an `infinite` flag.

**PENALTY** — a possible break. Fields: the penalty value `p`, a `flagged`
flag, and optional pre-break text with its own face, size, raise and width
(computed as a BOX).

### Fragments and glue

The resolved character stream (spaces, ordinary characters, rigid spaces,
marks and discretionary points, each carrying its style) is cut into
**fragments**. A fragment is a maximal run of ordinary characters with the
same (face, size, raise) containing no space, no rigid space, no mark and no
end of block. A discretionary point does **not** end a fragment.

A discretionary point belongs to the fragment that holds the ordinary
character immediately before it, at the position after that character. If
the character before it is not an ordinary character of the current fragment
(the point is at the start of the text, or right after a space, a rigid
space or a mark), the point is dropped. A point right before a change of
face, size or raise therefore lands at the end of the earlier fragment (and
is then discarded, see [Hyphenation](#hyphenation)), never at the start of
the later one.

Each fragment becomes one BOX, unless it has hyphenation points (see
[Hyphenation](#hyphenation)), in which case it becomes `k+1` BOXes separated
by `k` PENALTY items. No kern is ever applied across such a split, so the
BOXes' widths are computed independently and their sum is what the engine
uses everywhere.

Each run of spaces becomes one GLUE. Let `f` be the face and `s` the size in
force at the first space of the run. The glue is

```
w = scale(space(f), s)
y = scale(stretch(f), s)
z = scale(shrink(f), s)
```

except that an **extra-space glue** is produced when the glue follows a
sentence end. The glue follows a sentence end when, taking the characters of
the inline text immediately before the space run and skipping over any number
of trailing characters from the set

```
)  ]  }  '  "  U+2019  U+201D
```

the next character back is `.`, `!` or `?`, and the character before *that*
one is not an uppercase ASCII letter `A`-`Z` (so `etc.` and `end.` qualify but
`J. Smith` and `F.` do not; a `.` at the very start of the text qualifies).

The search runs over the resolved stream of the block's inline text, in which
each unit is an ordinary character, a rigid space, a footnote mark, a
discretionary point or an earlier glue. A discretionary point is transparent:
it is skipped without ending the search and is not "the character before".
Any unit that is not an ordinary character — a rigid space, a mark, an
earlier glue, or the start of the text — ends the search immediately, which
makes the glue an ordinary one unless the search had already found its `.`,
`!` or `?`.

An extra-space glue is

```
w = scale(space(f) + extra(f), s)
y = scale(stretch(f) + (stretch(f) div 2), s)
z = scale(shrink(f), s)
```

Only the skipped characters listed above are skipped; any other character
ends the search immediately.

When the context's `align` is not `justify`, **every** glue of the list
(except the final glue described next) is then replaced by

```
w unchanged,   y = ragged-stretch * w,   z = 0
```

### The ends of the list

Every horizontal list ends with

```
PENALTY(p = 10000, flagged = false)
GLUE(w = 0, y = 0, z = 0, infinite = true)
PENALTY(p = -10000, flagged = false)
```

The infinite glue makes the last line of a list cost nothing however short it
is; the penalty of 10000 in front of it stops a line from being broken there
(a penalty of 10000 is never a breakpoint, and a glue is only a breakpoint
when a BOX precedes it); and the final forced penalty makes the last break
mandatory. These three items are always present, even for an empty list.

### Breakpoints

An item index `i` is a **breakpoint** when either

- item `i` is a GLUE and item `i-1` exists and is a BOX, or
- item `i` is a PENALTY with `p < 10000`.

The breakpoint's penalty is 0 for a GLUE and `p` for a PENALTY; it is
*flagged* only for a flagged PENALTY.

**Breakpoint 0** is the notional start of the list, the position before item
0. It is never flagged and its penalty is 0. Where the text below writes
`a+1` for the first item of a line, breakpoint 0 means item 0.

### The line between two breakpoints

For breakpoints `a < b` the line consists of items `a+1 .. b-1`, with any
leading GLUE items of that range removed, followed by the pre-break text of
item `b` if item `b` is a PENALTY that has pre-break text. Then

```
W = sum of the widths of the BOXes and the natural widths of the GLUEs
Y = sum of the GLUE stretches        (and `infinite` if any GLUE is infinite)
Z = sum of the GLUE shrinks
```

The line's **measure** is `measure - first-indent` when `a` is breakpoint 0,
and `measure` otherwise.

## Hyphenation

A fragment is hyphenated only when all of the following hold:

- the context's `hyphenate` is on and the global `hyphenate` setting is on;
- the fragment's family is not `mono`;
- the fragment contains at least one letter.

If any of the three fails the fragment has **no** hyphenation points at all —
not even the explicit `\-` points of
[the discretionary rule below](#hyphenation), which this gate suppresses too.
A point whose position is 0 or the length of the fragment is discarded, so a
fragment is never split into an empty box.

Each leaf context inherits `hyphenate` from the context it is built in. The
four contexts that are not nested in any block context — a footnote, a figure
caption, the TOC title and a TOC entry — take `hyphenate` from the global
`hyphenate` setting. Running header and footer text is never hyphenated.

Let the fragment's characters be `c_0 .. c_{n-1}`. A **letter** is one of
`A`-`Z` or `a`-`z`. Find the longest prefix of non-letters and the longest
suffix of non-letters, and let the remaining middle part be the **core**,
occupying positions `[lo, hi)`. If the core is empty the fragment has no
hyphenation points.

The core is split at every `-` it contains into **segments**. A break is
permitted immediately after each `-` of the core, with penalty
`ex-hyphen-penalty`, flagged, and **no** pre-break text (the hyphen is already
there). Each segment is then hyphenated on its own:

- If the segment is not entirely letters, it yields no points.
- Otherwise lowercase it by mapping `A`-`Z` to `a`-`z` (no other case mapping
  exists) and apply Liang's algorithm below. Each resulting position `q`
  (meaning "after `q` letters of the segment") becomes a break at the
  corresponding fragment position, with penalty `hyphen-penalty`, flagged,
  and pre-break text `-` (U+002D) in the fragment's face, size and raise.

If the fragment contains at least one explicit discretionary point (`\-`)
strictly inside it (at a position `p` with `0 < p < n`), Liang's algorithm
is **not** applied to any of its segments: the fragment's only hyphenation
points are those explicit ones (each with penalty `hyphen-penalty`, flagged,
pre-break text `-`) and the breaks after core hyphens. Explicit points are
not subject to `left`/`right` minima and need not lie inside the core. A
discretionary point at position `n` (the end of the fragment) is discarded
**before** this test, so it does not suppress Liang: `typesetting\-` is
hyphenated exactly like `typesetting`.

All of a fragment's points are sorted by position and deduplicated (a position
that is both an explicit point and a core-hyphen break keeps the core-hyphen
break). The PENALTY items appear between the BOXes in that order.

### Liang's algorithm

Given the lowercased segment `s` of length `n` and the active pattern set:

1. Build `t = "." + s + "."`, of length `n + 2`.
2. Let `v[0 .. n+2]` be an array of zeros; `v[i]` is the value at the position
   immediately before `t[i]`.
3. For every pair `0 <= i < j <= n+2`, if `t[i..j)` is the key of a pattern,
   then for every `k` in `0 .. j-i` set `v[i+k] = max(v[i+k], pattern[k])`.
4. For `q` in `1 .. n-1`, a break after `q` letters is permitted iff
   `v[1+q]` is odd.
5. Only `q` with `left <= q <= n - right` are kept, where `left` and `right`
   come from the pattern file.

If the lowercased segment is the key of an **exception**, steps 1–4 are
skipped and the exception's own break positions are used instead; step 5 still
applies.

Patterns whose key begins with `.` can only match at `i = 0`, and patterns
whose key ends with `.` only at `j = n+2`, which falls out of the definition
above; no special casing is needed.

### Worked trace

With the `english` set (`left 2`, `right 3`) and the segment `winter`:

```
t = ".winter."            (indices 0..7, so v has indices 0..8)
the only matching pattern key is "nt" (from n1t, values [0,1,0]) at i=3,
which sets v[3] = max(v[3],0), v[4] = max(v[4],1), v[5] = max(v[5],0)
v = [0, 0, 0, 0, 1, 0, 0, 0, 0]
q=1 -> v[2]=0   q=2 -> v[3]=0   q=3 -> v[4]=1 (odd)
q=4 -> v[5]=0   q=5 -> v[6]=0
kept by left/right: 2 <= q <= 6-3 = 3   ->   q = 3
```

so `winter` breaks only as `win-ter`. For `typesetting`:

```
t = ".typesetting."
matches: "tt"  (t1t,  [0,1,0]) at i=7
         "ing" (3ing, [3,0,0,0]) at i=9
         "ng"  (n1g,  [0,1,0]) at i=10
v = [0, 0, 0, 0, 0, 0, 0, 0, 1, 3, 0, 1, 0, 0]
odd positions q = 7, 8, 10
kept by left/right: 2 <= q <= 11-3 = 8   ->   q = 7 and q = 8
```

so `typesetting` becomes the three boxes `typeset`, `t`, `ing` separated by
two flagged penalties. The exception `al-go-rithm` makes `algorithm` break at
q = 2 and q = 4 regardless of the patterns (its pattern values alone would
permit no break at all).

## Line breaking

A horizontal list is broken into lines by a total-fit algorithm: the chosen
set of breakpoints minimises the sum of the lines' demerits.

### Badness and fitness

For a line with natural width `W`, stretch `Y`, shrink `Z` and measure `L`,
let `d = L - W`:

- `d >= 0` and the line contains the infinite glue: `badness = 0`,
  `fitness = decent`. (A line that contains the infinite glue but is still
  too wide falls through to the `d < 0` case below: infinite stretch does not
  excuse an overfull line.)
- Otherwise:
  - `d == 0`: `badness = 0`, `fitness = decent`.
  - `d > 0` and `Y == 0`: the line is **unstretchable**.
  - `d > 0` and `Y > 0`:
    ```
    badness = min(10000, (100 * d^3) div Y^3)
    fitness = very-loose  if d > Y
              loose       if 2*d > Y
              decent      otherwise
    ```
  - `d < 0`, let `e = -d`. If `Z == 0` or `e > Z` the line is **overfull**.
    Otherwise
    ```
    badness = min(10000, (100 * e^3) div Z^3)
    fitness = tight   if 2*e > Z
              decent  otherwise
    ```

`d^3` and `Y^3` are exact integer cubes and the division is exact integer
division. `d` (and `e`) never exceeds 2^20 in the tests, so `d^3` fits in 64
bits, but `100 * d^3` can reach about 1.2 * 10^20 and does **not** fit in a
signed or unsigned 64-bit integer; it must still be computed exactly (for
example with a 128-bit intermediate, or by any other exact method).

The four fitness classes are numbered

```
tight = 0,  decent = 1,  loose = 2,  very-loose = 3
```

An unstretchable or overfull line is assigned, for the purpose of the
formulas that still need them in pass 2,

```
unstretchable: badness = 10000, fitness = very-loose
overfull:      badness = 10000, fitness = tight
```

### Feasibility

In **pass 1** a line is feasible iff it is neither unstretchable nor overfull
and its badness is `<= tolerance`.

In **pass 2** every line is feasible.

### Demerits of one line

Let `b` be the badness of the line, `p` the penalty of the breakpoint that
ends it, `flag` whether that breakpoint is flagged, `c` the line's fitness
class, and `c0` the fitness class of the node the line starts from (the start
node has class `decent`). Let `flag0` be whether the start node's breakpoint
is flagged (false for the start node).

```
dem = (line-penalty + b)^2
if 0 <= p and p < 10000:        dem += p * p
if -10000 < p and p < 0:        dem -= p * p
if flag and flag0:              dem += double-hyphen-demerits
if |c - c0| > 1:                dem += adj-demerits
if b is the final breakpoint
   and flag0:                   dem += final-hyphen-demerits
```

`p == -10000` (the final forced penalty) contributes nothing. `dem` may be
negative in principle; with the supplied ranges it never is.

### The algorithm

Breakpoints are processed in increasing index order. A **node** records a
breakpoint, a fitness class, a line number, the total demerits of the best
path reaching it with that class, and its predecessor. Nodes are numbered in
creation order; node 0 is `(breakpoint 0, class decent, line 0, total 0)`.

For each breakpoint `b` in increasing order:

1. For every existing node `n` (every node created before this breakpoint is
   processed), compute the line from `n`'s breakpoint to `b` using measure
   `measure - first-indent` if `n` is at breakpoint 0 else `measure`. If the
   line is feasible, its candidate total is `n.total + dem(n, b)`.
2. For each fitness class `c` that at least one feasible candidate produced,
   create one node `(b, c, n.line + 1, best total, n)` where the best
   candidate is the one with the smallest total; ties are broken by the
   smallest predecessor node number. The nodes for one breakpoint are
   created (and so numbered) in increasing order of their fitness class:
   a `tight` node before a `decent` one before a `loose` one before a
   `very-loose` one.

Nodes are never removed; an implementation may of course prune nodes that can
no longer yield a feasible line (`n` such that the line from `n` to `b` is
already overfull can never become feasible again, because widths only grow),
and may stop at the first `b` for which no node exists only after confirming
there is none at the final breakpoint.

After the final breakpoint has been processed, the chosen breaking is read off
the node at the final breakpoint with the smallest total demerits; ties are
broken by the smaller fitness class, then by the smaller node number. The
chain of predecessors gives the lines in reverse order.

If **no** node exists at the final breakpoint after pass 1, the whole list is
broken again from scratch in pass 2 (every line feasible), and the list is
counted in `emergency-lists`. Pass 2 always succeeds, because with every line
feasible the chain of consecutive breakpoints is itself a valid breaking.

Pass 2 is a plain minimisation over the same demerits, with no extra term for
how overfull a line is. When every candidate line of a list is already at
badness 10000 — a narrow measure with long words, say — the cheapest breaking
is then the one with the fewest lines, often a single very wide overfull
line. That is the correct answer and must not be special-cased; such a line
is placed, counted in `overfull-lines`, and may run far past the right margin.

An empty horizontal list still has the final breakpoint, so it produces
exactly one (empty) line, whose demerits are `(line-penalty + 0)^2`.

The list's **total demerits** is the total of the chosen final node. The sum
of these over every list broken in the document is reported as
`total-demerits`.

A `@pre` block is **not** broken: each of its source lines is a one-line
horizontal list that skips this whole section, contributes no demerits, and is
not counted in `emergency-lists` or `hyphenated-lines`. Its line is still set
by [Setting a line](#setting-a-line), so it is counted in `lines` and, when
its single box is wider than the measure, in `overfull-lines`.

Every other horizontal list in the document is broken by this algorithm and
contributes to `total-demerits`, `hyphenated-lines`, `overfull-lines` and
`emergency-lists`: paragraphs, `@li` texts, headings, table cells, footnotes,
figure captions, the TOC title and TOC entries. Running header and footer
text is set as one line without breaking and contributes to none of them.

## Setting a line

Let the line's items be as defined in
[The line between two breakpoints](#the-line-between-two-breakpoints), with
natural width `W`, stretch `Y`, shrink `Z` and measure `L`, and let the
context's alignment be `align`.

### Glue widths

- If the line contains the infinite glue: every finite glue keeps its natural
  width and the infinite glue is given width 0.
- Otherwise if `align` is not `justify`: every glue keeps its natural width.
- Otherwise (`justify`), let `E = L - W`:
  - `E == 0`, or `E > 0` with `Y == 0`, or `E < 0` with `Z == 0`: every glue
    keeps its natural width.
  - `E > 0` with `Y > 0`: distribute `E` over the glues in proportion to their
    stretches.
  - `E < 0` with `0 < -E <= Z`: distribute `E` over the glues in proportion to
    their shrinks.
  - `E < 0` with `-E > Z`: every glue is set to `w - z` (fully shrunk).

**Distribution** of a total `E` over glues `g_1 .. g_k` with weights
`w_1 .. w_k` (the stretches or the shrinks), `T = w_1 + … + w_k > 0`:

```
P_0 = 0;  P_i = w_1 + … + w_i
C_i = (E * P_i) div T                (floor division, E may be negative)
glue i is set to its natural width + (C_i - C_{i-1})
```

Because `P_k = T`, the increments sum to exactly `E`.

### Horizontal placement

Let `W_set` be the sum of the set widths of the line's boxes and glues, and
let `left_line = left + first-indent` for the first line of the list and
`left_line = left` otherwise. The x coordinate of the first item is

| align | start x |
|---|---|
| `justify` | `left_line` |
| `left` | `left_line` |
| `right` | `left_line + L - W_set` |
| `center` | `left_line + ((L - W_set) div 2)` |

Items are then placed left to right, each advancing x by its set width.

The line is **overfull** when `W_set > L`; it contributes to
`overfull-lines`. (With `justify` this happens only when the glue could not
shrink enough, which only pass 2 can produce; with the ragged alignments it
happens whenever the natural width exceeds the measure.)

### Output runs

Each BOX with text produces one `text` item. Two BOXes merge into a single
`text` item — their texts concatenated and their widths added — when

- they have the same face, size and raise,
- they come from the same fragment, and
- the only items between them in the line are PENALTY items.

The pre-break text that ends a line merges with the BOX before it under the
same rule (it always has the same face, size and raise, and comes from the
same fragment). Rigid boxes emit nothing. The infinite glue emits nothing.

So an unbroken word with three hyphenation points is one `text` item, and a
word broken after its first point produces `pre-` at the end of one line and
the rest at the start of the next.

### Vertical metrics of a line

```
ascent = max over the line's boxes of (scale(ascent(face), size) + raise)
depth  = max over the line's boxes of max(0, scale(descent(face), size) - raise)
```

If the line has no boxes at all, `ascent` and `depth` come from the context's
initial face and size with raise 0.
## Vertical lists

The body of the document is turned into a single flat sequence of **vertical
items** by walking the block tree in source order. The table of contents, when
present, is turned into a second such sequence (see
[The table of contents](#the-table-of-contents)).

### Vertical items

| item | fields |
|---|---|
| `LINE` | the placed runs of one line, its ascent, depth, the leading of its list, its group identity (group id, index `k`, group size `n`, group kind) and the footnotes it references |
| `GLUE` | a height |
| `RULE` | x, width, thickness |
| `ROW` | a table row: x, height and its cells' lines |
| `FRAME` | x, width, height (a figure's frame, inside a figure block only) |
| `FLOATMARK` | the index of a figure |
| `FORCEBREAK` | nothing |

A **group** is the set of lines produced by one horizontal list. Its kind is
`heading` for `@h1`..`@h4` and `other` for everything else.

A document's vertical list never contains a `FRAME`: a `@fig` contributes
only a `FLOATMARK`, and the frame belongs to the figure block that
[The figure block](#the-figure-block) lays out separately.

### Contexts

The root context is

```
family    = body-font        left        = body-x
bold      = off              measure     = body-width
italic    = off              align       = align
size      = body-size        hyphenate   = hyphenate
leading   = leading
```

Container blocks modify it for their contents:

| block | changes |
|---|---|
| `@q` | `left += quote-indent`, `measure -= 2 * quote-indent` |
| `@block` | for each attribute given: `align`, `size`, `leading`, `family` (from `font`); `left += indent`, `measure -= indent + right-indent` |
| `@ul`, `@ol` | `left += list-indent`, `measure -= list-indent` |
| `@li` | unchanged (the item's content uses the list's context) |

Leaf blocks build horizontal lists:

| block | family / bold / italic | size | leading | align | first-indent |
|---|---|---|---|---|---|
| paragraph | context | context | context | context | `par-indent` |
| `@li` text | context | context | context | context | 0 |
| `@h1`..`@h4` | `heading-font` / `heading-bold` / `heading-italic` | `hN-size` | `hN-leading` | `heading-align` | 0 |
| `@pre` line | `pre-font` / off / off | `pre-size` | `pre-leading` | `left` | 0 |
| table cell | context family, off, off | context | `table-leading` | column letter | 0 |
| figure caption | `figure-caption-font` / off / off | `figure-caption-size` | `figure-caption-leading` | `figure-caption-align` | 0 |
| footnote | `footnote-font` / off / off | `footnote-size` | `footnote-leading` | `align` | 0 |
| TOC title | `toc-title-font` / `heading-bold` / `heading-italic` | `toc-title-size` | `h1-leading` | `heading-align` | 0 |
| TOC entry | `toc-font` / off / off | `toc-size` | `toc-leading` | `left` | 0 |

`@pre` additionally uses `left += pre-indent`, `measure -= pre-indent`, and
its lines are never broken.

`measure` is never allowed to go below 1000: if the computed measure would be
smaller, it is clamped to 1000. (The tests never rely on the clamp.)

### Vertical space between blocks

Space is accumulated in two registers, `pending-max` and `pending-add`, both
starting at 0, together with a flag `started` (false until the first item has
been emitted into the current vertical list). Each leaf block has a
*space-before* and a *space-after*:

| block | space-before | space-after |
|---|---|---|
| paragraph | `par-space` | `par-space` |
| `@li` text | 0 | 0 |
| `@h1`..`@h4` | `hN-space-before` | `hN-space-after` |
| `@pre` | `pre-space` | `pre-space` |
| `@table` | `table-space` | `table-space` |
| `@rule` | `rule-space` | `rule-space` |
| `@fig` | 0 | 0 |
| `@newpage` | 0 | 0 |
| `@vspace` | — | — |
| container `@q` | `quote-space` | `quote-space` |
| container `@ul`, `@ol` | `list-space` | `list-space` |
| container `@block` | 0 | 0 |

Walking the tree:

- Entering a container: `pending-max = max(pending-max, space-before)`.
- Leaving a container: `pending-max = max(pending-max, space-after)`.
- Between two consecutive `@li` of one list:
  `pending-max = max(pending-max, list-item-space)`.
- `@vspace height=h`: `pending-add += h`.
- Any other leaf block: `pending-max = max(pending-max, space-before)`; then
  if `started` and `pending-max + pending-add > 0`, emit
  `GLUE(pending-max + pending-add)`; reset `pending-max = space-after`,
  `pending-add = 0`; emit the block's items; `started = true`.
  (`@newpage` instead emits `FORCEBREAK` and sets both registers to 0; it
  emits no glue, before or after.)

Both registers are discarded at the end of the vertical list.

Note the consequences: two paragraphs separated by `@vspace height=12pt` with
`par-space = 6pt` are separated by 18000; `@vspace height=6pt` twice gives
12000; a paragraph followed by a block quote whose first child is a paragraph
is separated by `max(par-space, quote-space, par-space)`.

### Items emitted by each leaf block

- **paragraph**, **`@li` text**: the `LINE` items of its broken horizontal
  list, in order, with group kind `other`.
- **`@h1`..`@h4`**: the `LINE` items of its broken horizontal list, group
  kind `heading`. If `h1-newpage` is on and the level is 1, a `FORCEBREAK` is
  emitted first (before any glue; the glue registers are zeroed as for
  `@newpage`).
- **`@pre`**: one `LINE` per source line, in order, group kind `other`,
  group size = the number of source lines.
- **`@rule`**: `RULE(x = left, width = measure, thickness = rule-thickness)`.
- **`@table`**: see [Tables](#tables).
- **`@fig`**: `FLOATMARK(index)` only. The figure itself is laid out later.
- **`@vspace`**, **`@newpage`**: as described above.

`@doc` and `@toc` emit nothing into the body at all. A container block
(`@q`, `@block`, `@ul`, `@ol`) emits nothing of its own: its items are the
items of its children, in order, with the space rules above applied as the
walk enters and leaves it. A table cell's lines are carried inside the
`ROW` item that contains them and are not separate `LINE` items, so the
widow and orphan rules never apply inside a table; likewise a figure's
caption lines live inside the figure block and never appear in the body's
vertical list.

### List markers

Each `@li` gets a **marker** placed in the indent to the left of its content.
The item's **depth** is the number of enclosing `@ul`/`@ol` blocks (1 for a
top-level list). The marker's text is

| depth mod 3 | `@ul` | `@ol` |
|---|---|---|
| 1 | `U+2022` (bullet) | the item's number in decimal, then `.` |
| 2 | `U+2013` (en dash) | the item's number in lowercase letters, then `.` |
| 0 | `*` | the item's number in lowercase roman, then `.` |

The item's number is `start + (the item's 0-based position in its list)`,
where `start` is the `@ol` attribute (default 1). Lowercase letters are
bijective base 26: 1 is `a`, 26 is `z`, 27 is `aa`, 28 is `ab`, 52 is `az`,
53 is `ba`. Lowercase roman numerals are as in
[Lowercase roman numerals](#lowercase-roman-numerals).

The marker is one BOX in the face resolved from (the context family, bold off,
italic off) at the context size. It is placed on the baseline of the **first
line of the item**, at

```
x = left - list-marker-gap - (the marker's width)
```

where `left` is the item's context `left` (the list's `left`, i.e. already
indented by `list-indent`). It is in the same region as the line it sits on
and is not a `LINE` of its own: it is not counted in `lines`, it does not
affect the line's ascent or depth, and if the item's first line lands on a
different page from a later line, the marker goes with the first line.

### The heading number

A heading `@hN` without `*` and with `heading-number` on is numbered. Four
counters `c1..c4` start at 0. On a numbered `@hN`: `cN += 1` and every
`cM` with `M > N` is reset to 0. The **number string** is `c1`, then `.cM`
for each `M` from 2 to `N`, in decimal, with no trailing dot: level 1 gives
`3`, level 2 gives `3.1`, level 3 gives `3.1.2`.

A numbered heading's horizontal list begins with

```
BOX(number string, heading face, hN-size, raise 0)
rigid BOX of width heading-number-gap
```

followed by the heading's inline content. An unnumbered heading (`*` or
`heading-number` off) has no number box and no gap, and does not advance the
counters.

The number string is ordinary inline text in the heading's own style, so it
forms its own fragment; it contains no letter, so it is never hyphenated. The
same holds for the number of a TOC entry and for the `number + "."` box of a
figure caption, and the plain text of a TOC entry is ordinary inline text
too, with its spaces becoming glue and its words hyphenated as usual.

### Plain text of a heading

Used by the table of contents and the `{chapter}`/`{section}` placeholders.
It is the heading's inline content with: all style tags removed (their
contents kept), `{n|…}` impossible (footnotes are forbidden in headings),
every `\-` removed, every `~` and `\ ` replaced by one space, every escape
replaced by its character, and every run of spaces replaced by one space,
with leading and trailing spaces removed. The number string is not part of it.

### Vertical placement on a page

Given the page's body top `body_top` and a sequence of vertical items:

```
cursor = body_top ;  fresh = true ;  prev_baseline = 0 ;  prev_depth = 0
for each item:
    LINE:
        if fresh:  baseline = cursor + ascent
        else:      baseline = prev_baseline
                            + max(leading, prev_depth + line-skip + ascent)
        place the line at that baseline
        cursor = baseline + depth
        prev_baseline = baseline ;  prev_depth = depth ;  fresh = false
    GLUE h:      cursor += h ;                fresh = true
    RULE:        top = cursor ; cursor += thickness ;  fresh = true
    ROW:         top = cursor ; cursor += height ;     fresh = true
    FRAME:       top = cursor ; cursor += height ;     fresh = true
    FLOATMARK:   nothing
```

`leading` here is the leading recorded in the `LINE` item (the leading of the
horizontal list it came from). The **used body height** after a prefix of
items is `cursor - body_top`, computed after dropping any trailing `GLUE`
items of that prefix.

### Break legality

A page break happens *before* a vertical item. The position before item
index `j` (`0 <= j <= n`, where `j == n` is the end of the list) is a **legal
break** exactly when all of the following hold.

1. `j > 0`.
2. If item `j` is a `LINE` with group index `k`, group size `n_g` and group
   kind `heading`: `k == 1`.
3. If item `j` is a `LINE` with group index `k > 1`, group size `n_g` and
   group kind `other`: `k - 1 >= orphans` and `n_g - k + 1 >= widows`.
4. If `keep-with-next` is on: the position is not inside a **keep run**. For
   every heading group `H`, scan forward from the item after `H`'s last line,
   skipping `GLUE` and `FLOATMARK` items, to the next item `X` (if any). The
   keep run covers the positions before each of `H`'s lines after the first,
   the positions before each skipped item, the position before `X`, and, when
   `X` is a `LINE` with group size `n_g`, the positions before the following
   `min(orphans, n_g) - 1` lines of that group. (Those last positions are
   already illegal by rules 2 and 3, since they are before line `k` of a
   group with `2 <= k <= orphans`; the clause is listed only so that the
   keep run is described completely.)
5. `j == n` is always a legal break (subject to rule 1).

A `FORCEBREAK` at index `j` makes the position before `j` a **mandatory**
break.

## Tables

A table block with `cols` columns, alignment letters `a_1..a_cols` and a
source-ordered sequence of rows and `@hrule`s is laid out as follows.

### Cell measurement

Every cell's inline text (with leading and trailing spaces removed) is turned
into a horizontal list using the table-cell context. Two widths are derived
from that list:

- `nat` — the natural width of the whole list on one line: the sum of every
  BOX width and every GLUE natural width, excluding the final infinite glue.
- `min` — the largest natural width of any single line the list could
  produce: the maximum, over every pair of consecutive breakpoints `(a, b)`
  of the list (including breakpoint 0 and the final breakpoint), of the `W` of
  the line from `a` to `b`.

For an empty cell both are 0.

`nat_i` and `min_i` for column `i` are the maxima of `nat` and `min` over that
column's cells. A column with no cells (impossible: every row has `cols`
cells) would be 0.

### Column widths

```
A = max(0, measure - (cols - 1) * table-col-gap)
if sum(nat) <= A:        w_i = nat_i
else if sum(min) >= A:   w_i = min_i
else:
    D = sum(nat) - A
    S = sum(nat_i - min_i)                  (> 0 in this branch)
    P_0 = 0 ;  P_i = (nat_1-min_1) + … + (nat_i-min_i)
    C_i = (D * P_i) div S
    w_i = nat_i - (C_i - C_{i-1})
```

The table's width is `TW = sum(w_i) + (cols - 1) * table-col-gap`, and column
`i`'s left edge is `x_i = left + sum over j<i of (w_j + table-col-gap)`.

### Rows

Each cell of a row is broken with `left = x_i`, `measure = w_i` and the
column's alignment (`l` → `left`, `r` → `right`, `c` → `center`). Then

```
A_row = max over the row's cells of the ascent of their first line
n_row = max over the row's cells of their number of lines
D_row = max over the row's cells of the depth of their last line
```

Cell `i`'s line `k` is placed at baseline `row_top + A_row + (k-1) *
table-leading`. The row's height is
`A_row + (n_row - 1) * table-leading + D_row`.

An empty row (every cell empty) still produces one line per cell, so
`n_row = 1` and `A_row`/`D_row` come from the cell context's face and size.

### The table's vertical items

Walking the table's elements in source order:

- A row emits `ROW`. If the previous element was also a row, `GLUE(table-row-space)`
  is emitted first.
- An `@hrule` emits `GLUE(table-rule-space)` (omitted if it is the first
  element), then `RULE(x = left, width = TW, thickness = table-rule-thickness)`,
  then `GLUE(table-rule-space)` (omitted if it is the last element).

## Footnotes

Each `{n|…}` in the document is a footnote. They are numbered 1, 2, 3, … in
source order (the order in which the `{n|` appears in `document.cdx`).

### The reference mark

At the reference point the enclosing horizontal list gets a BOX whose text is
the footnote's number in decimal, whose face is resolved from the style in
force at that point, whose size is `mark-size` and whose raise is
`mark-raise`. It is its own fragment: it ends the fragment before it and the
next character starts a new one. Its baseline in the output is
`baseline - mark-raise`.

A `LINE` records the footnotes referenced by the boxes it contains, in the
order those boxes appear in the line.

### The footnote's own lines

The footnote's text is a horizontal list with the footnote context
(`left = body-x + footnote-indent`,
`measure = body-width - footnote-indent`). Breaking it gives the footnote's
lines once and for all; a split footnote keeps the same lines.

### The footnote area of a page

A page's footnote lines are, in order:

1. the lines carried over from the previous page, then
2. for each footnote referenced on the page, in reference order, all of its
   lines.

These lines form **groups**: each footnote's lines are one group, and the
material carried over from the previous page arrives as a list of groups —
the unplaced tail of the one footnote the previous page split, followed by
any whole footnotes that page had no room for at all. The split tail is a
group with no mark; a whole footnote keeps its mark wherever it ends up. The
stack height of a sequence of groups is

```
cursor = 0 ;  fresh = true
for each group g:
    if g is not the first:  cursor += footnote-item-space ;  fresh = true
    for each line of g:     advance cursor exactly as in
                            "Vertical placement on a page", with leading =
                            footnote-leading
H_fn = cursor      (the distance from the top of the stack to its bottom)
```

The area the footnotes take from the page is

```
A_fn = footnote-space-before + footnote-rule-thickness
     + footnote-space-after + H_fn           (0 when there are no lines)
```

A page that places no footnote line has no footnote area at all: no rule, no
space and nothing in the `footnote` region. Otherwise the area is placed with
its bottom flush with the bottom of the body:

```
rule_top = body-bottom - H_fn - footnote-space-after - footnote-rule-thickness
RULE at (body-x, rule_top, footnote-rule-width, footnote-rule-thickness)
stack_top = rule_top + footnote-rule-thickness + footnote-space-after
```

and the stack is placed from `stack_top` with the loop above. All of these
items are in the `footnote` region.

The first line of each non-carried group also gets a mark:

```
text  = the footnote number in decimal
face  = the footnote face (footnote-font, bold off, italic off)
size  = footnote-mark-size
x     = body-x + footnote-indent - footnote-mark-gap - (the mark's width)
y     = that line's baseline - footnote-mark-raise
```

A split tail carried from an earlier page gets no mark. The mark is **not** part of the footnote line's
horizontal list: it does not affect that line's ascent, depth or width, and it
is not counted in `lines`.

### Splitting

See [Page breaking](#page-breaking) for how many lines a page takes.

## Floating figures

`@fig height=H [width=W]` queues a figure. Figures are numbered 1, 2, 3, … in
source order. The queue is FIFO.

### The figure block

A figure block is laid out at a given top `y`:

```
fw   = W if W > 0 else body-width            (W defaults to figure-width)
fx   = body-x + ((body-width - fw) div 2)
if figure-frame is on:  FRAME at (fx, y, fw, H)
caption_top = y + H + figure-caption-space
```

The caption's horizontal list is

```
[ BOX(figure-caption-prefix)  GLUE(normal, caption face/size) ]   if the
                                                 prefix is not empty
BOX(number + ".")
rigid BOX of width figure-caption-gap
… the caption's inline content …
```

where the caption's context has `left = fx` and `measure = fw`, so the
caption is set under the figure's own box rather than across the whole
measure. The prefix and the caption's inline content are ordinary inline
text: their spaces become glue and their fragments are hyphenated by the
normal rules (hence the two boxes `Fig` and `ure` in Example 15). The glue
after the prefix is an ordinary, never an extra-space, glue of the caption
face and size, and, like every other glue of the list, it is replaced by the
ragged glue of [Horizontal lists](#horizontal-lists) when
`figure-caption-align` is not `justify`.

The list is broken and placed with the figure-caption context, first baseline
at `caption_top + ascent` and the usual baseline rule afterwards. The figure
block's height is `(last caption baseline + its depth) - y`. It does not
depend on `y`, so a figure block may be laid out once and placed anywhere.

### Placement

A figure is never placed on the page that references it. When a page's content
has been decided, every `FLOATMARK` in that page's body appends its figure to
the queue (in item order).

At the start of every later page, figures are taken from the front of the
queue while they fit. With `k` figures already taken for this page, the zone
height is

```
zone(k) = sum of the k figure block heights + k * float-space-after
```

(so there is `float-space-after` between consecutive figures and after the
last one). The next figure is taken when:

- there is still body material left, and `body-height - zone(k+1) >= float-min-body`; or
- there is no body material left and `k == 0` (the first figure is always
  taken on a page with no body material); or
- there is no body material left and `zone(k+1) <= body-height`.

The first figure that cannot be taken stops the loop — later figures are
never taken ahead of it.

The figures are placed at `body-y`, `body-y + H_1 + float-space-after`, and so
on, and the page's body starts at `body_top = body-y + zone(k)` with
`goal = body-height - zone(k)`. All of a figure's items are in the `float`
region.

After the last body page, pages continue to be produced while the queue is
non-empty, with no body material.

## Page breaking

Body pages are produced one at a time. The state is an index `i` into the
vertical item list, the figure queue, and the list of footnote lines carried
over from the previous page.

Repeatedly: first run step 0, then stop if `i == n` and the figure queue is
empty and no carried-over lines remain, and otherwise produce one page with
steps 1 to 8. Running step 0 before the stop test means that `GLUE` and
`FORCEBREAK` items at the very end of the list are consumed without
producing a page, so a document that ends with `@newpage` does not gain a
blank page at the end.

0. While `i < n` and item `i` is a `GLUE` or a `FORCEBREAK`, `i += 1`.
1. Take figures for the float zone as described in
   [Placement](#placement), giving `k`, `body_top` and
   `goal = body-height - zone(k)`.
2. If `i < n`, choose the cut. For `j` from `i+1` upwards: if item `j-1` is a
   `FORCEBREAK`, set `cut = j-1` and stop. Otherwise compute
   ```
   used(j) = used-body(i..j) + min(A_fn(i..j), footnote-max-height)
   ```
   where `used-body(i..j)` is the used body height of items `i..j-1` with
   trailing `GLUE` dropped, and `A_fn(i..j)` is the footnote area height
   (including `footnote-space-before`, the rule and `footnote-space-after`)
   for the carried-over lines plus **all** lines of **all** footnotes
   referenced by `LINE` items in `i..j-1`. If `used(j) <= goal` and the
   position before `j` is a legal break, remember `j` as the best cut so far.
   Stop the loop when `used(j) > goal` or when `j` reaches `n`.

   `cut` is the best remembered `j`; if there is none, `cut` is the smallest
   `j > i` whose position is a legal break, or `n` if there is none. (In that
   case the page is overfull: this is the only way a page can exceed its
   goal.)

   Both `used-body(i..j)` and `A_fn(i..j)` are non-decreasing in `j`, and so
   is the capped reservation, so stopping at the first `j` with
   `used(j) > goal` loses nothing.

   The reservation is capped so that an unusually long footnote does not
   squeeze the body off the page: whatever the footnotes need, at most
   `footnote-max-height` of the page is held back for them while the break is
   chosen, and step 5 then places as many of their lines as actually fit.
3. If `i == n` (no body material), `cut = n` and the page's body is empty.
4. The page's body is items `i..cut-1` with trailing `GLUE` dropped, placed by
   [Vertical placement on a page](#vertical-placement-on-a-page) with the
   `body_top` of step 1, in the `body` region. Let `B` be its used body
   height.
5. Decide the footnote lines. The page's candidate sequence is the carried-over
   group followed by the groups of the footnotes referenced in the body, in
   reference order. Let
   ```
   avail = goal - B - footnote-space-before - footnote-rule-thickness
                    - footnote-space-after
   ```
   Take the longest prefix of the candidate lines whose stack height is
   `<= avail`. If that prefix ends strictly inside a group, leaving fewer than
   `footnote-min-split` lines of that group placed, shorten it to exclude that
   group entirely — unless doing so empties the prefix, in which case keep it.
   If the page's body is empty — the list of items `i..cut-1` with trailing
   `GLUE` dropped has no items at all — and at least one line remains, the
   prefix must contain at least one line regardless of `avail`. A body that
   consists only of `FLOATMARK` items is **not** empty for this rule, even
   though it places nothing and `B == 0`.
   The prefix is placed as in
   [The footnote area of a page](#the-footnote-area-of-a-page); the rest is
   carried over to the next page and counted in `footnote-split-lines`. The
   carried material keeps its group structure: the group the prefix ended
   inside contributes its unplaced tail as a markless group, and every group
   after it is carried whole.
6. Every `FLOATMARK` among items `i..cut-1` queues its figure, in item order.
7. Render the running header and footer (see
   [Running headers and footers](#running-headers-and-footers)).
8. `i = cut`. (Step 0 of the next page skips the consumed `FORCEBREAK` and
   any glue, so consecutive `@newpage` directives never make a blank page.)

Each page consumes at least one vertical item, one figure or one footnote
line, so the loop terminates.

## Running headers and footers

For each page and each of the six slots the text is chosen as

```
if the page's label number is even:  use <slot>-even
else:                                use <slot>
```

The label number is the page's arabic number for a body page and the roman
numeral's value for a front page. An empty text produces nothing.

Placeholders are substituted:

| placeholder | value |
|---|---|
| `{page}` | the page's label string (`12`, or `iv` on a front page) |
| `{pages}` | the number of body pages, in decimal |
| `{title}`, `{author}`, `{date}` | the `@doc` values, or empty |
| `{chapter}` | the current `@h1`, see below |
| `{section}` | the current `@h2`, see below |

`{chapter}` comes from the last `@h1` — numbered or not — whose first line was
placed on this page or on an earlier body page. When that heading has a number
string, `{chapter}` is the number string, a single space and the heading's
plain text; when it has none (it is marked `*`, or `heading-number` is off),
`{chapter}` is just the plain text. It is empty on front pages and before the
first `@h1`. `{section}` is the same for `@h2`.

The substituted text is set as one unbreakable line: runs of spaces become
glue (with the sentence rule of
[Fragments and glue](#fragments-and-glue)), a glue at the very start or the
very end of the text is removed (rule 2 of
[Whitespace in inline text](#whitespace-in-inline-text) — this matters when a
placeholder at either end substitutes to the empty string, as in
`{section} - {page}` before the first `@h2`), everything else becomes
fragments, the face is resolved from `header-font` with bold and italic off,
and the size is `header-size`. Let `W` be the sum of the box widths and
natural glue widths of what remains. If nothing remains the slot produces no
output. Then

| slot | x |
|---|---|
| `*-left` | `body-x` |
| `*-center` | `body-x + ((body-width - W) div 2)` |
| `*-right` | `body-x + body-width - W` |

The baseline is `header-baseline` for the three header slots and
`footer-baseline` for the three footer slots, measured from the top of the
page. Header items are in the `header` region, footer items in the `footer`
region. Header and footer text is never hyphenated, never broken and never
counted in `lines` or `overfull-lines`.

## The table of contents

If the document has no `@toc` block there are no front pages and nothing in
this section applies.

### Entries

While the body is laid out, every heading records the body page on which its
**first line** was placed. An entry is produced for every heading that

- is not marked `*`, and
- has level `<= toc-depth`.

The entry's fields are its level, its number string (empty when the heading is
unnumbered or `heading-number` is off), the heading's plain text, and the
label of its page.

### The TOC's vertical list

Built with the same `pending-max`/`pending-add` machinery as the body:

1. The TOC **title** block: a horizontal list containing just the resolved
   `toc-title` text (the `title` attribute of `@toc` overrides the setting),
   as literal characters, in the TOC-title context with `left = body-x` and
   `measure = body-width`. Its space-before is 0 and its space-after is
   `toc-title-space-after`. The title is a group of kind `other`.
2. Each entry, in document order, as its own block with space-before and
   space-after `toc-entry-space`. The entry's horizontal list is
   ```
   [ BOX(number string)  rigid BOX of width toc-number-gap ]   if numbered
   … the plain text, as literal characters …
   ```
   in the TOC-entry context, whose `left` is
   `body-x + (level-1) * toc-indent` and whose `measure` is
   `body-width - (level-1) * toc-indent - toc-reserve`.

### Leaders and the page label

After an entry's lines have been placed, its **last** line also gets the page
label and the leaders, both on that line's baseline:

```
label      = the entry's page label, as a BOX in the TOC face at toc-size
label_x    = body-x + body-width - (label's width)
x_from     = (the x after the last item of the last line) + toc-leader-gap
x_to       = label_x - toc-leader-gap
unit       = the width of the toc-leader string as a single BOX
k          = max(0, (x_to - x_from) div unit)
```

If `k > 0`, one `text` item is emitted at `x = x_to - k * unit` whose text is
the leader string repeated `k` times and whose width is `k * unit` (the
repetitions are not kerned against each other). The label is emitted at
`label_x`. Both are in the `body` region.

If the entry's last line has no items at all (an entry with no number and
empty text), `x_from` is the left edge of that line plus `toc-leader-gap`.

### TOC pages

The TOC's vertical list is paginated by the algorithm of
[Page breaking](#page-breaking) with no figures and no footnotes, after the
body has been paginated. Its pages are **front pages**: page `m` (1-based) is
labelled with the lowercase roman numeral of `m`, and `{chapter}` and
`{section}` are empty on them. Front pages are emitted before body pages.

## Output

On success exactly two files are written: `layout.txt` and `report.txt`.

### layout.txt

```
layout 1
pages <total number of pages>
```

then, for each page in output order (front pages first, then body pages), a
page record:

```
page <index> <label> <page-width> <page-height> <body-x> <body-y> <body-width> <body-height>
```

`<index>` is the 1-based position of the page in the output; `<label>` is the
page label string. All six geometry numbers are in millipoints.

After each page record come its item lines, each indented by exactly two
spaces:

```
  text <region> <face> <size> <x> <y> <width> "<string>"
  rule <region> <x> <y> <width> <thickness>
  box <region> <x> <y> <width> <height>
```

- `<region>` is one of `header`, `float`, `body`, `footnote`, `footer`.
- `<face>` is a face name such as `serif-bold`.
- `<size>` is the size in millipoints.
- For `text`, `<x>` is the left edge and `<y>` the baseline; `<width>` is the
  run's advance width.
- For `rule` and `box`, `<y>` is the **top** edge.
- `<string>` is the run's text in double quotes. Inside the quotes, `\` is
  written `\\`, `"` is written `\"`, and every other character is written
  literally as UTF-8. Runs never contain LF.
- `box` is used for figure frames; `rule` for `@rule`, table rules and the
  footnote separator.

All numbers are decimal with no leading zeros, no `+`, and a leading `-` when
negative.

The item lines of one page are sorted by this key, in order:

1. region, by the rank `header` = 0, `float` = 1, `body` = 2,
   `footnote` = 3, `footer` = 4;
2. `y` ascending;
3. `x` ascending;
4. kind, by the rank `text` = 0, `rule` = 1, `box` = 2;
5. the formatted line itself, compared byte by byte as UTF-8.

The file ends with a newline. A document that produces no pages gives

```
layout 1
pages 0
```

### report.txt

Exactly these lines, in exactly this order, each `<key> <value>` with one
space:

```
report 1
pages <n>
front-pages <n>
body-pages <n>
lines <n>
paragraphs <n>
headings <n>
tables <n>
figures <n>
footnotes <n>
footnote-split-lines <n>
hyphenated-lines <n>
overfull-lines <n>
emergency-lists <n>
total-demerits <n>
```

| key | definition |
|---|---|
| `pages` | total pages emitted |
| `front-pages` | table-of-contents pages |
| `body-pages` | `pages - front-pages` |
| `lines` | `LINE` items placed in the `body`, `float` and `footnote` regions, including `@pre` lines, table-cell lines and TOC lines; header and footer lines are not counted |
| `paragraphs` | paragraph blocks in the document (not list items, not headings) |
| `headings` | `@h1`..`@h4` blocks, including unnumbered ones |
| `tables` | `@table` blocks |
| `figures` | `@fig` blocks |
| `footnotes` | `{n|…}` constructs |
| `footnote-split-lines` | footnote lines carried from one page to the next, totalled over all pages |
| `hyphenated-lines` | lines that end at a breakpoint with non-empty pre-break text |
| `overfull-lines` | lines whose set width exceeds their measure |
| `emergency-lists` | horizontal lists that needed pass 2 |
| `total-demerits` | the sum of the chosen total demerits of every horizontal list processed by the line-breaking algorithm |

A `LINE` that is laid out but never placed cannot happen: every line of every
horizontal list reaches some page.
## Worked examples

Examples 5 to 16 all use this `settings.cfg`, which gives a small page so that
whole layouts fit on this page:

```
# small.cfg
page-width   = 200pt
page-height  = 120pt
margin-top   = 20pt
margin-bottom = 20pt
margin-left  = 20pt
margin-right = 20pt
```

so `body-x = 20000`, `body-y = 20000`, `body-width = 160000`,
`body-height = 80000` and `body-bottom = 100000`. Everything else is a
default: body `serif` at 10000, `leading` 12000, `line-skip` 1000,
`par-indent` 18000, `align justify`, `tolerance` 1000. The serif face has
`ascent 731`, `descent 223`, `space 254 127 85`, so at 10000 a line's ascent
is 7310, its depth 2230, and the inter-word glue is `2540 / 1270 / 850`.

### Example 1 — measuring a fragment

The fragment `The` in `serif` at size 10000. From `serif.cfm`,
`adv('T') = 606`, `adv('h') = 509`, `adv('e') = 448`, and the pairs `(T,h)`
and `(h,e)` have no `kern` record, so

```
box_units = 606 + 509 + 448 = 1563
box_width = scale(1563, 10000) = (1563 * 10000) div 1000 = 15630
```

The fragment `Tu` has `kern(T,u) = -60`, so `box_units = 606 + 508 - 60 =
1054` and `box_width = 10540`. The same fragment at size 11000 is
`scale(1054, 11000) = (1054 * 11000) div 1000 = 11594`, which is *not* the
same as scaling each glyph separately and adding
(`6666 + 5588 - 660 = 11594` here, but in general the two differ).

### Example 2 — Liang hyphenation

See [Worked trace](#worked-trace) for `winter` and `typesetting`. Two more
with the `english` set:

```
national      -> matches "tion" (3tion) at i=3 and "io" (i1o) at i=4
                 v = [0,0,0,3,0,1,0,0,0,0,0]
                 odd q = 2, 4 ;  2 <= q <= 8-3=5  ->  na-tio-nal
Introduction  -> matches ".in" (.in3), "nt" (n1t), "tr" (1tr), "ct" (c1t),
                 "tion" (3tion), "o." (2o.)
                 odd q = 2, 8 ;  2 <= q <= 12-3=9  ->  In-troduc-tion
```

so `Introduction` becomes the three boxes `In`, `troduc`, `tion`. In
`sans-bold` at 20000 those measure 19140, 59360 and 35840, summing to 114340.

### Example 3 — badness and fitness

A line with `L = 142000`.

| `W` | `Y` | `Z` | `d` | badness | fitness |
|---|---|---|---|---|---|
| 142000 | 1270 | 850 | 0 | 0 | decent |
| 130980 | 6350 | 4250 | 11020 | `(100 * 11020^3) div 6350^3 = 522` | very-loose (`d > Y`) |
| 145890 | 7620 | 5100 | -3890 | `(100 * 3890^3) div 5100^3 = 44` | tight (`2e > Z`) |
| 111050 | 5080 | 3400 | 30950 | clamped to 10000 | very-loose |
| 164800 | 8890 | 5950 | -22800 | overfull (`e > Z`) | — |
| 15630 | 0 | 0 | 126370 | unstretchable (`Y == 0`) | — |

With `tolerance = 1000` the first three are feasible in pass 1 and the last
three are not.

### Example 4 — distributing glue

`L = 142000`, `W = 145890`, six glues of `2540 / 1270 / 850`. `align` is
`justify` and `E = -3890`, so the shrinks are the weights with `T = 5100`:

```
P = 850, 1700, 2550, 3400, 4250, 5100
C = (-3890 * P) div 5100
  = -649, -1297, -1945, -2594, -3242, -3890
increments: -649, -648, -648, -649, -648, -648     (sum = -3890)
set widths: 1891, 1892, 1892, 1891, 1892, 1892
```

Note `(-3890 * 850) div 5100 = -3307000 div 5100 = -649` by **floor**
division; truncating division would give -648 and the line would be one
millipoint too wide.

### Example 5 — one paragraph, one line

`document.cdx`:

```
The quick brown fox.
```

The horizontal list is

```
0 BOX "The" 15630      5 GLUE 2540/1270/850
1 GLUE 2540/1270/850   6 BOX "fox." 15810
2 BOX "quick" 22240    7 PENALTY 10000
3 GLUE 2540/1270/850   8 GLUE infinite
4 BOX "brown" 25140    9 PENALTY -10000
```

No word has a hyphenation point. The breakpoints are 1, 3, 5 and 9. A first
line ending at 1 is unstretchable (`Y = 0`) and ones ending at 3 or 5 have
badness 10000, so the only feasible breaking in pass 1 is the single line
ending at 9: measure `160000 - 18000 = 142000`, it contains the infinite
glue, hence badness 0, fitness decent, demerits `(10 + 0)^2 = 100`. The
finite glues keep their natural widths and the line starts at
`20000 + 18000 = 38000`; the baseline is `20000 + 7310 = 27310`.

`layout.txt`:

```
layout 1
pages 1
page 1 1 200000 120000 20000 20000 160000 80000
  text body serif 10000 38000 27310 15630 "The"
  text body serif 10000 56170 27310 22240 "quick"
  text body serif 10000 80950 27310 25140 "brown"
  text body serif 10000 108630 27310 15810 "fox."
```

`report.txt`:

```
report 1
pages 1
front-pages 0
body-pages 1
lines 1
paragraphs 1
headings 0
tables 0
figures 0
footnotes 0
footnote-split-lines 0
hyphenated-lines 0
overfull-lines 0
emergency-lists 0
total-demerits 100
```

### Example 6 — two justified lines

`document.cdx`:

```
The quick brown fox jumps over the lazy dog.
```

Nine boxes, eight glues, no hyphenation points. Cumulative natural widths at
each glue breakpoint: 15630, 40410, 68090, 83910, 111050, 130980, 145890,
164800, and 184820 at the end. With `L = 142000` on the first line only two
breaks are feasible:

| break after | `W` | badness | fitness |
|---|---|---|---|
| `over` | 130980 | 522 | very-loose |
| `the` | 145890 | 44 | tight |

From `over` the second line costs `100 + adj-demerits = 10100` (decent next
to very-loose), total `(10+522)^2 + 10000 + 10100 = 303124`. From `the` the
second line costs 100 and the total is `(10+44)^2 + 100 = 3016`. No
three-line breaking is feasible, so the engine breaks after `the`.

The first line shrinks by 3890 as in Example 4. The second line holds the
infinite glue, so its glue is natural and it starts at `body-x`. Baselines are
27310 and `27310 + max(12000, 2230 + 1000 + 7310) = 39310`.

```
layout 1
pages 1
page 1 1 200000 120000 20000 20000 160000 80000
  text body serif 10000 38000 27310 15630 "The"
  text body serif 10000 55521 27310 22240 "quick"
  text body serif 10000 79653 27310 25140 "brown"
  text body serif 10000 106685 27310 13280 "fox"
  text body serif 10000 121856 27310 24600 "jumps"
  text body serif 10000 148348 27310 17390 "over"
  text body serif 10000 167630 27310 12370 "the"
  text body serif 10000 20000 39310 16370 "lazy"
  text body serif 10000 38910 39310 17480 "dog."
```

`report.txt` differs from Example 5 only in `lines 2` and
`total-demerits 3016`.

### Example 7 — the three ragged alignments

The same document with `align = left`, `align = right` and `align = center`
added to `settings.cfg`. In a ragged alignment every glue becomes
`2540 / 7620 / 0` (`ragged-stretch = 3`), which changes the breaking:

| break after | `W` | `Y` | badness | fitness |
|---|---|---|---|---|
| `fox` | 83910 | 22860 | 1640 | — (over tolerance) |
| `jumps` | 111050 | 30480 | 104 | very-loose |
| `over` | 130980 | 38100 | 2 | decent |
| `the` | 145890 | 45720 | overfull (`Z = 0`) | — |

Breaking after `over` costs `(10+2)^2 + 100 = 244`. Breaking after `jumps`
costs `(10+104)^2 + adj-demerits` for line 1 (very-loose after decent) and
`100 + adj-demerits` for line 2 (decent after very-loose), a total of
`12996 + 10000 + 100 + 10000 = 33096`. So all three alignments break after
`over`, with `W_set = 130980` on line 1 and `51300` on line 2.

`align = left` places both lines at their left edges:

```
  text body serif 10000 38000 27310 15630 "The"
  text body serif 10000 56170 27310 22240 "quick"
  text body serif 10000 80950 27310 25140 "brown"
  text body serif 10000 108630 27310 13280 "fox"
  text body serif 10000 124450 27310 24600 "jumps"
  text body serif 10000 151590 27310 17390 "over"
  text body serif 10000 20000 39310 12370 "the"
  text body serif 10000 34910 39310 16370 "lazy"
  text body serif 10000 53820 39310 17480 "dog."
```

`align = right` offsets line 1 by `142000 - 130980 = 11020` and line 2 by
`160000 - 51300 = 108700`:

```
  text body serif 10000 49020 27310 15630 "The"
  text body serif 10000 67190 27310 22240 "quick"
  text body serif 10000 91970 27310 25140 "brown"
  text body serif 10000 119650 27310 13280 "fox"
  text body serif 10000 135470 27310 24600 "jumps"
  text body serif 10000 162610 27310 17390 "over"
  text body serif 10000 128700 39310 12370 "the"
  text body serif 10000 143610 39310 16370 "lazy"
  text body serif 10000 162520 39310 17480 "dog."
```

`align = center` offsets by `11020 div 2 = 5510` and `108700 div 2 = 54350`:

```
  text body serif 10000 43510 27310 15630 "The"
  text body serif 10000 61680 27310 22240 "quick"
  text body serif 10000 86460 27310 25140 "brown"
  text body serif 10000 114140 27310 13280 "fox"
  text body serif 10000 129960 27310 24600 "jumps"
  text body serif 10000 157100 27310 17390 "over"
  text body serif 10000 74350 39310 12370 "the"
  text body serif 10000 89260 39310 16370 "lazy"
  text body serif 10000 108170 39310 17480 "dog."
```

All three report `lines 2` and `total-demerits 244`.

### Example 8 — a hyphenated break

`settings.cfg` adds `par-indent = 0`. `document.cdx`:

```
Algorithm integer column every typesetting.
```

`algorithm` is an exception (`al-go-rithm`, points 2 and 4), `integer` has
the point 2 (`in-teger`), `typesetting` has 7 and 8, and `column` and `every`
have none. The list is

```
 0 BOX "Al"      10030      11 GLUE
 1 PEN 50 flag "-" 3250     12 BOX "every"   22030
 2 BOX "go"       9910      13 GLUE
 3 PEN 50 flag "-" 3250     14 BOX "typeset" 28370
 4 BOX "rithm"   21680      15 PEN 50 flag "-" 3250
 5 GLUE                     16 BOX "t"        2800
 6 BOX "in"       7770      17 PEN 50 flag "-" 3250
 7 PEN 50 flag "-" 3250     18 BOX "ing."    15320
 8 BOX "teger"   20030      19 PEN 10000
 9 GLUE                     20 GLUE infinite
10 BOX "column"  29880      21 PEN -10000
```

With `L = 160000` the only feasible first line (pass 1, `tolerance = 1000`)
is the break at item 15: `W = 163110` (including the 3250 hyphen),
`Z = 4 * 850 = 3400`, `e = 3110`, badness
`(100 * 3110^3) div 3400^3 = 76`, fitness tight. Its demerits are
`(10 + 76)^2 + 50^2 = 9896`. The second line holds the infinite glue, so
badness 0 and demerits `100 + final-hyphen-demerits = 5100` (the previous
breakpoint is flagged and this is the final breakpoint). Total 14996.

Line 1 shrinks by 3110 over four glues: `C = -778, -1555, -2333, -3110`,
increments `-778, -777, -778, -777`, set widths `1762, 1763, 1762, 1763`.
Boxes 0, 2 and 4 come from one fragment with only penalties between them, so
they merge into one run `Algorithm` of width `10030 + 9910 + 21680 = 41620`;
likewise `integer` is 27800 and the pre-break hyphen merges onto `typeset`
giving `typeset-` of width `28370 + 3250 = 31620`. On line 2, boxes 16 and 18
merge into `ting.` of width 18120.

```
layout 1
pages 1
page 1 1 200000 120000 20000 20000 160000 80000
  text body serif 10000 20000 27310 41620 "Algorithm"
  text body serif 10000 63382 27310 27800 "integer"
  text body serif 10000 92945 27310 29880 "column"
  text body serif 10000 124587 27310 22030 "every"
  text body serif 10000 148380 27310 31620 "typeset-"
  text body serif 10000 20000 39310 18120 "ting."
```

```
report 1
pages 1
front-pages 0
body-pages 1
lines 2
paragraphs 1
headings 0
tables 0
figures 0
footnotes 0
footnote-split-lines 0
hyphenated-lines 1
overfull-lines 0
emergency-lists 0
total-demerits 14996
```

### Example 9 — a numbered heading

`document.cdx`:

```
@h1 Introduction
The quick brown fox.
```

The heading is numbered `1`, set in `sans-bold` (`heading-font = sans`,
`heading-bold = on`) at `h1-size = 20000`, where the ascent is
`scale(773, 20000) = 15460` and the depth `scale(243, 20000) = 4860`. Its
list is `BOX "1" 11400`, a rigid box of `heading-number-gap = 6000`, then the
three boxes of `Introduction` (114340 in total). A break at one of the
hyphenation points would leave `Y = 0` (there is no glue in the list), so it
is unstretchable and infeasible; the whole list is one line with badness 0.

The heading's first baseline is `20000 + 15460 = 35460` and the cursor ends at
40320. `h1-space-after = 9000` is the only pending space, so the paragraph
starts at 49320 and its baseline is `49320 + 7310 = 56630`.

```
layout 1
pages 1
page 1 1 200000 120000 20000 20000 160000 80000
  text body sans-bold 20000 20000 35460 11400 "1"
  text body sans-bold 20000 37400 35460 114340 "Introduction"
  text body serif 10000 38000 56630 15630 "The"
  text body serif 10000 56170 56630 22240 "quick"
  text body serif 10000 80950 56630 25140 "brown"
  text body serif 10000 108630 56630 15810 "fox."
```

with `lines 2`, `paragraphs 1`, `headings 1`, `total-demerits 200`.

### Example 10 — nested lists

`document.cdx`:

```
@ul
@li First item.
@li Second item.
@ul
@li Nested one.
@end
@end
```

The outer list indents to `left = 38000` with `measure = 142000`; the inner
one to `left = 56000` with `measure = 124000`. `Nested` has the hyphenation
point 3, so it is the two boxes `Nes` (15750) and `ted` (12320) — merged in
the output. Vertical items: `LINE`, `LINE`, `GLUE(6000)` (the inner list's
`list-space`), `LINE`. Baselines 27310, `27310 + 12000 = 39310`, then
`41540 + 6000 = 47540` plus the ascent, giving 54850.

Markers: depth 1 is `U+2022` (width 3440 in `serif` at 10000) placed at
`38000 - 4000 - 3440 = 30560`; depth 2 is `U+2013` (width 4940) placed at
`56000 - 4000 - 4940 = 47060`.

```
layout 1
pages 1
page 1 1 200000 120000 20000 20000 160000 80000
  text body serif 10000 30560 27310 3440 "•"
  text body serif 10000 38000 27310 18360 "First"
  text body serif 10000 58900 27310 20350 "item."
  text body serif 10000 30560 39310 3440 "•"
  text body serif 10000 38000 39310 29430 "Second"
  text body serif 10000 69970 39310 20350 "item."
  text body serif 10000 47060 54850 4940 "–"
  text body serif 10000 56000 54850 28070 "Nested"
  text body serif 10000 86610 54850 16950 "one."
```

with `lines 3`, `paragraphs 0` (list items are not paragraphs) and
`total-demerits 300`.

### Example 11 — preformatted text

`document.cdx`:

```
@pre
let x = 1
  y = x + 2
@end
```

`mono` at `pre-size = 9000`: every glyph advances 600 units, so a line of `n`
characters is `scale(600n, 9000) = 5400n` wide. Ascent
`scale(700, 9000) = 6300`, depth `scale(215, 9000) = 1935`. The first
baseline is `20000 + 6300 = 26300`; the second is
`26300 + max(11000, 1935 + 1000 + 6300) = 37300`. Pre lines are never broken,
so they add nothing to `total-demerits`.

```
layout 1
pages 1
page 1 1 200000 120000 20000 20000 160000 80000
  text body mono 9000 20000 26300 48600 "let x = 1"
  text body mono 9000 20000 37300 59400 "  y = x + 2"
```

with `lines 2`, `paragraphs 0`, `total-demerits 0`.

### Example 12 — table column widths

A table that fits naturally:

```
@table cols=3 align=llr
Item | Qty | Price
@hrule
Widget | 2 | 4.50
Gadget | 11 | 19.95
@end
```

No cell has a hyphenation point, so `min` equals `nat` for every cell.

| column | cells | `nat` | `min` |
|---|---|---|---|
| 1 | 18470, 29530, 29060 | 29530 | 29530 |
| 2 | 15000, 4990, 9840 | 15000 | 15000 |
| 3 | 20440, 17480, 22460 | 22460 | 22460 |

`A = 160000 - 2 * 8000 = 144000` and `sum(nat) = 66990 <= A`, so
`w = (29530, 15000, 22460)`, `TW = 82990`, and the column left edges are
20000, 57530 and 80530. Every row is one line high:
`7310 + 0 + 2230 = 9540`. The vertical items are `ROW`,
`GLUE(2000)`, `RULE`, `GLUE(2000)`, `ROW`, `GLUE(2000)`, `ROW`, giving row
tops 20000, 33940 and 45480 and baselines 27310, 41250 and 52790, with the
rule's top edge at 31540.

```
layout 1
pages 1
page 1 1 200000 120000 20000 20000 160000 80000
  text body serif 10000 20000 27310 18470 "Item"
  text body serif 10000 57530 27310 15000 "Qty"
  text body serif 10000 82550 27310 20440 "Price"
  rule body 20000 31540 82990 400
  text body serif 10000 20000 41250 29530 "Widget"
  text body serif 10000 57530 41250 4990 "2"
  text body serif 10000 85510 41250 17480 "4.50"
  text body serif 10000 20000 52790 29060 "Gadget"
  text body serif 10000 57530 52790 9840 "11"
  text body serif 10000 80530 52790 22460 "19.95"
```

The third column is right aligned, so its cells start at
`80530 + 22460 - W_set`.

A table that must shrink:

```
@table cols=2 align=ll
Column heading one | Column heading two
A rather long cell value here | Short
@end
```

`heading` has the point 4, so the cell `Column heading one` has breakpoints
after `Column`, inside `heading` and after `heading`, and its widest
unbreakable line is `Column` at 32190. The four cells measure

| cell | `nat` | `min` |
|---|---|---|
| `Column heading one` | 83520 | 32190 |
| `Column heading two` | 83990 | 32190 |
| `A rather long cell value here` | 114120 | 23300 (`rather`) |
| `Short` | 21660 | 21660 |

so `nat = (114120, 83990)`, `min = (32190, 32190)`,
`A = 160000 - 8000 = 152000`, `sum(nat) = 198110 > A` and
`sum(min) = 64380 < A`. Therefore

```
D = 198110 - 152000 = 46110
S = (114120 - 32190) + (83990 - 32190) = 81930 + 51800 = 133730
C_1 = (46110 * 81930) div 133730 = 28249        w_1 = 114120 - 28249 = 85871
C_2 = (46110 * 133730) div 133730 = 46110       w_2 = 83990 - 17861 = 66129
```

and `TW = 85871 + 66129 + 8000 = 160000`, exactly the measure.

### Example 13 — a footnote

`document.cdx`:

```
Delta{n|A short note.} gamma.
```

`Delta` and `gamma.` have no hyphenation points. The mark is `1` in `serif`
at `mark-size = 7000`, width 3444, raised by `mark-raise = 3000`; it ends the
`Delta` fragment. The line's ascent is therefore
`max(7310, scale(731,7000) + 3000) = max(7310, 8117) = 8117` and its depth is
`max(2230, max(0, 1561 - 3000)) = 2230`. The baseline is
`20000 + 8117 = 28117` and the mark's own baseline is `28117 - 3000 = 25117`.

The footnote's text is set at `footnote-size = 8000` with
`left = 20000 + 10000 = 30000` and `measure = 150000`: one line of width
`5864 + 2032 + 15984 + 2032 + 15800 = 41712`, ascent
`scale(731,8000) = 5848`, depth `scale(223,8000) = 1784`, so
`H_fn = 7632`. The area is

```
rule_top  = 100000 - 7632 - 3000 - 400 = 88968
stack_top = 88968 + 400 + 3000 = 92368
baseline  = 92368 + 5848 = 98216        (and 98216 + 1784 = 100000)
```

The footnote mark is `1` at `footnote-mark-size = 6000`, width 2952, placed at
`20000 + 10000 - 2000 - 2952 = 25048` with baseline `98216 - 2000 = 96216`.
The page needs `10347 + (6000 + 400 + 3000 + 7632) = 27379` of its 80000, so
one page suffices.

```
layout 1
pages 1
page 1 1 200000 120000 20000 20000 160000 80000
  text body serif 7000 59720 25117 3444 "1"
  text body serif 10000 38000 28117 21720 "Delta"
  text body serif 10000 65704 28117 32050 "gamma."
  rule footnote 20000 88968 120000 400
  text footnote serif 6000 25048 96216 2952 "1"
  text footnote serif 8000 30000 98216 5864 "A"
  text footnote serif 8000 37896 98216 15984 "short"
  text footnote serif 8000 55912 98216 15800 "note."
```

with `lines 2`, `footnotes 1`, `total-demerits 200`. Note how the items are
sorted: the mark at `y = 25117` precedes the two body runs at `y = 28117`
because the sort is by region, then `y`, then `x`.

### Example 14 — splitting a footnote

This example is arithmetic only. Suppose `footnote-max-height = 30pt`, a page
has `goal = 80000`, the chosen cut leaves `B = 40600`
(`40600 + min(56664, 30000) = 70600 <= 80000`, and the next legal break would
have exceeded the goal), and the page's footnote candidate lines are two
groups: footnote 4 with 2 lines and footnote 5 with 3 lines, all at the
default footnote metrics
(ascent 5848, depth 1784, `footnote-leading = 10000`,
`footnote-item-space = 2000`). The stack heights of the prefixes are

```
1 line   : 5848 + 1784                                 =  7632
2 lines  : 5848 + 10000 + 1784                         = 17632
3 lines  : 17632 + 2000 + 5848 + 1784                  = 27264
4 lines  : 27264 + 10000                               = 37264
5 lines  : 37264 + 10000                               = 47264
```

(each next line in a group adds `max(footnote-leading, depth + line-skip +
ascent) = max(10000, 8632) = 10000`, and a new group adds
`footnote-item-space` and then the ascent and depth of its first line).

```
avail = 80000 - 40600 - 6000 - 400 - 3000 = 30000
```

The longest prefix that fits is 3 lines (27264 <= 30000 < 37264). That ends
inside footnote 5 with 1 of its 3 lines placed. With the default
`footnote-min-split = 1` the prefix stands: 3 lines are placed and 2 are
carried, so `footnote-split-lines` grows by 2. With
`footnote-min-split = 2` the prefix is shortened to exclude footnote 5
entirely, so 2 lines are placed and 3 are carried. On the next page the
carried lines form one group with no mark and a stack height of
`5848 + 10000 + 10000 + 1784 = 27632` for three lines.

### Example 15 — a deferred figure

`document.cdx`:

```
@fig height=30pt
A framed box.
@end
Alpha one.

Beta two.
```

The figure contributes only a `FLOATMARK` to the body, so page 1 holds the
two paragraphs (baselines 27310 and 39310, both starting at
`20000 + 18000 = 38000`). `Alpha` has the hyphenation point 2 but breaking
there leaves `Y = 0`, so each paragraph is one line. When page 1 is finished
its `FLOATMARK` queues figure 1.

Page 2 has no body material, so the first queued figure is always taken. Its
block is

```
fw   = 160000 (figure-width is 0, so the full measure)
fx   = 20000 + ((160000 - 160000) div 2) = 20000
FRAME at (20000, 20000, 160000, 30000)
caption_top = 20000 + 30000 + 4000 = 54000
```

The caption list is `BOX "Figure"` (boxes `Fig` 12042 and `ure` 11529 at
`figure-caption-size = 9000`), a glue of 2286, `BOX "1."` 6705, a rigid box
of `figure-caption-gap = 4000`, then `A` 6597, glue, `framed` 25515, glue,
`box.` 15642 — a natural width of 88888 on one line. `figure-caption-align`
is `center`, so the offset is `(160000 - 88888) div 2 = 35556` and the line
starts at 55556. The caption's ascent is `scale(731,9000) = 6579` and its
depth 2007, so its baseline is `54000 + 6579 = 60579`.

```
layout 1
pages 2
page 1 1 200000 120000 20000 20000 160000 80000
  text body serif 10000 38000 27310 24510 "Alpha"
  text body serif 10000 65050 27310 16950 "one."
  text body serif 10000 38000 39310 18290 "Beta"
  text body serif 10000 58830 39310 17420 "two."
page 2 2 200000 120000 20000 20000 160000 80000
  box float 20000 20000 160000 30000
  text float serif 9000 55556 60579 23571 "Figure"
  text float serif 9000 81413 60579 6705 "1."
  text float serif 9000 92118 60579 6597 "A"
  text float serif 9000 101001 60579 25515 "framed"
  text float serif 9000 128802 60579 15642 "box."
```

with `pages 2`, `lines 3`, `paragraphs 2`, `figures 1` and
`total-demerits 300`. The frame comes first on page 2 because the sort is by
region, then `y`: the frame's `y` is 20000 and the caption's baseline is
60579.

### Example 16 — a table of contents

`document.cdx`:

```
@toc
@h1 Introduction
Alpha one.
@newpage
@h1 Results
Beta two.
```

The body makes two pages: page 1 carries heading `1 Introduction` (baseline
35460, number at 20000 width 11400, title at
`20000 + 11400 + 6000 = 37400` width 114340) and the paragraph `Alpha one.`
at baseline `40320 + 9000 + 7310 = 56630`; the `@newpage` forces page 2,
which carries `2 Results` (number width 11320, title at 37320 width 68900)
and `Beta two.`.

The TOC is laid out afterwards, so its entries can use the final labels `1`
and `2`. Its title `Contents` is `sans-bold` at `toc-title-size = 20000`
(ascent 15460, depth 4860), baseline `20000 + 15460 = 35460`, cursor 40320,
then `toc-title-space-after = 12000` gives 52320. Entry 1 is
`BOX "1"` (4920 in `serif` at `toc-size = 10000`), a rigid box of
`toc-number-gap = 6000`, then `Introduction` (49280), at
`left = 20000`, `measure = 160000 - 30000 = 130000`; its baseline is
`52320 + 7310 = 59630`. Entry 2's baseline is
`59630 + max(14000, 2230 + 1000 + 7310) = 73630`.

The leaders of entry 1: the line's content ends at
`30920 + 49280 = 80200`; the label `1` is 4920 wide so
`label_x = 20000 + 160000 - 4920 = 175080`; `x_from = 83200`,
`x_to = 172080`, `unit = 2530` (the width of `.`), and
`k = 88880 div 2530 = 35`, so 35 dots of total width 88550 start at
`172080 - 88550 = 83530`. For entry 2 the content ends at 60730, the label
`2` is 4990 wide, `x_from = 63730`, `x_to = 172010` and
`k = 108280 div 2530 = 42`, giving 42 dots of width 106260 at 65750.

```
layout 1
pages 3
page 1 i 200000 120000 20000 20000 160000 80000
  text body sans-bold 20000 20000 35460 82500 "Contents"
  text body serif 10000 20000 59630 4920 "1"
  text body serif 10000 30920 59630 49280 "Introduction"
  text body serif 10000 83530 59630 88550 "..................................."
  text body serif 10000 175080 59630 4920 "1"
  text body serif 10000 20000 73630 4990 "2"
  text body serif 10000 30990 73630 29740 "Results"
  text body serif 10000 65750 73630 106260 ".........................................."
  text body serif 10000 175010 73630 4990 "2"
page 2 1 200000 120000 20000 20000 160000 80000
  text body sans-bold 20000 20000 35460 11400 "1"
  text body sans-bold 20000 37400 35460 114340 "Introduction"
  text body serif 10000 38000 56630 24510 "Alpha"
  text body serif 10000 65050 56630 16950 "one."
page 3 2 200000 120000 20000 20000 160000 80000
  text body sans-bold 20000 20000 35460 11320 "2"
  text body sans-bold 20000 37320 35460 68900 "Results"
  text body serif 10000 38000 56630 18290 "Beta"
  text body serif 10000 58830 56630 17420 "two."
```

```
report 1
pages 3
front-pages 1
body-pages 2
lines 7
paragraphs 2
headings 2
tables 0
figures 0
footnotes 0
footnote-split-lines 0
hyphenated-lines 0
overfull-lines 0
emergency-lists 0
total-demerits 700
```

### Example 17 — errors

`settings.cfg`:

```
page-width = 200pt
margin-left = 20px
```

`20px` is not a valid length. The value starts at column 15 of line 2, so the
only output file is `error.txt` containing

```
settings.cfg:2:15: bad-length
```

With a valid `settings.cfg` and this `document.cdx`:

```
@h1 Title
{z|oops}
```

the `{` on line 2 opens no known tag, so the output is

```
document.cdx:2:1: unknown-inline
```

### Example 18 — running headers

Adding to `small.cfg`:

```
header-baseline = 10pt
footer-baseline = 112pt
header-right = {chapter}
footer-center = {page}
```

and using the document of Example 16. Header and footer text is set in
`sans` (`header-font = sans`, bold and italic off) at
`header-size = 9000`, where `adv` gives `1` = 505, `i` = 271 and
`Introduction` = 5057 units, and the glue is `scale(281, 9000) = 2529`.

On the front page (label `i`) `{chapter}` is empty, so no header item is
emitted; the footer reads `i`, width `scale(271, 9000) = 2439`, centred at
`20000 + ((160000 - 2439) div 2) = 98780`.

On body page 1 (label `1`, an odd label so the plain keys are used)
`{chapter}` substitutes to `1 Introduction`: two fragments separated by one
glue, so `W = 4545 + 2529 + 45513 = 52587` and the right-aligned slot starts
at `20000 + 160000 - 52587 = 127413`. The footer reads `1`, width 4545,
centred at `20000 + ((160000 - 4545) div 2) = 97727`.

```
page 1 i 200000 120000 20000 20000 160000 80000
  … the table of contents items …
  text footer sans 9000 98780 112000 2439 "i"
page 2 1 200000 120000 20000 20000 160000 80000
  text header sans 9000 127413 10000 4545 "1"
  text header sans 9000 134487 10000 45513 "Introduction"
  … the body items …
  text footer sans 9000 97727 112000 4545 "1"
```

(The `header` items sort before every `body` item and the `footer` items
after them, whatever their `y`.) Body page 2 has the even label `2`, so the
`*-even` keys are consulted first; neither was assigned, so each falls back to
the value of its plain key and the page gets `2 Results` in the header and `2`
in the footer.
## Guarantees

Every test input either is valid as described here, or violates it in exactly
one way that this specification assigns an error code to. In addition, every
test input satisfies all of the following, so an implementation never has to
decide what to do outside the rules above.

1. The input directory exists. Apart from the `missing-document` test cases,
   it contains `document.cdx`; `settings.cfg` may or may not be present.
2. `document.cdx` and `settings.cfg` are valid UTF-8 encoding only Unicode
   scalar values (no surrogates). `document.cdx` contains no TAB, no CR and
   no C0 control character other than LF. `settings.cfg` may contain TABs as
   whitespace but no CR.
3. Every file ends with a newline, and the last line is therefore never
   truncated. An empty `document.cdx` is possible and produces no pages.
4. Every length, integer, count and coordinate that the engine computes fits
   in a signed 64-bit integer with a wide margin; the largest coordinate in
   any test is under 10^8 and the largest total demerits under 10^13.
5. `body-width >= 36000` and `body-height >= 36000`, and no block's `measure`
   is ever driven below 1000, so the clamp of
   [Contexts](#contexts) never fires.
6. `body-height` is at least
   `footnote-space-before + footnote-rule-thickness + footnote-space-after +
   2 * footnote-leading + 2 * leading`, so a page whose body is empty always
   has room for at least one footnote line.
7. Every figure block's height plus `float-space-after` is at most
   `body-height`, so every queued figure is eventually placed.
   `footnote-max-height` is at least
   `footnote-space-before + footnote-rule-thickness + footnote-space-after +
   footnote-leading` and at most `body-height - 2 * leading`, so a page always
   has room for at least one footnote line and at least two body lines.
8. `toc-reserve` is at least the width of the widest page label plus
   `toc-leader-gap`, and `toc-leader`'s width `unit` is at least 1000.
9. No document produces more than 3000 pages in total, so every page label
   is in the range the roman numeral and decimal rules cover.
10. Inside a `@pre` block, no line other than the terminator has `@end` as its
    first non-space characters.
11. Table rows always have exactly `cols` cells, and `align` always has
    exactly `cols` letters, except in the `cell-count` and
    `bad-attribute-value` error tests.
12. Footnotes appear only where they are allowed, are never nested, and never
    number more than 999.
13. Heading levels may be used in any order. The counters start at 0 and a
    numbered `@hN` increments only `cN`, so a `@h3` with no preceding `@h1`
    or `@h2` is numbered `0.0.1`. The tests include such documents; the rule
    of [The heading number](#the-heading-number) is the whole rule.
14. The nine `.cfm` files and two `.chp` files in `data/` are exactly as
    shipped and are well formed.

## Architecture and size

A complete implementation has roughly these parts.

1. **Metric and pattern loading** — the `.cfm` and `.chp` readers, the face
   table, `scale`, the face-resolution table, and a Liang pattern structure
   (a trie or a hash map from key to value vector). *Roughly 300–500 lines.*
2. **The settings parser** — the line format, the length/integer/boolean/
   enum/family/patterns/text value parsers, the 126-key table with defaults
   and ranges, the derived page geometry, and the error positions.
   *Roughly 600–900 lines*, most of it the key table.
3. **The Codexa parser** — line classification, the block stack, attribute
   parsing, the inline scanner with its style stack and footnote extraction,
   the `@doc` metadata, table rows, `@pre`, and the error codes with their
   precedence. It produces a block tree with inline content already resolved
   into styled character runs. *Roughly 1200–1800 lines.*
4. **Horizontal list building** — fragment formation, box measurement with
   kerning, glue (including the sentence rule), rigid spaces, marks,
   discretionary points, and the hyphenator (core extraction, segments,
   Liang, exceptions, `left`/`right` minima). *Roughly 500–800 lines.*
5. **Line breaking** — badness, fitness, demerits, the node table, the two
   passes, the tie-breaking rules, and reading the chosen breaking back.
   *Roughly 400–600 lines.*
6. **Line setting** — glue distribution with floor division, the four
   alignments, run merging, ascents and depths. *Roughly 300–500 lines.*
7. **Block layout** — the context stack, the space registers, headings and
   their counters, list markers with their three numbering styles, quotes,
   `@block`, `@pre`, rules, `@vspace`, and the vertical item list with its
   group identities. *Roughly 900–1300 lines.*
8. **Tables** — cell measurement (`nat` and `min`), the column algorithm, row
   assembly and the table's vertical items. *Roughly 400–600 lines.*
9. **Footnotes and floats** — footnote lists, marks, the area layout and the
   splitting rule; figure blocks, captions with their numbering, and the FIFO
   queue with its fitting rule. *Roughly 600–900 lines.*
10. **Page breaking** — the per-page scan with its vertical placement rules,
    break legality (widows, orphans, keep-with-next, forced breaks), the
    footnote interaction, and the page records. *Roughly 700–1000 lines.*
11. **Headers, footers and the table of contents** — placeholder
    substitution, the three slots on each side, roman numerals, entry
    collection, the entry lists, leaders and labels, and the second
    pagination pass. *Roughly 500–800 lines.*
12. **Output** — the item formatter, the sort, `layout.txt`, `report.txt`,
    `error.txt`, and the counters. *Roughly 300–500 lines.*

Total: roughly nine to twelve thousand lines in a typical systems language.
The pieces are strongly layered, and the order above is a good
implementation order: parts 1–6 can be tested on single paragraphs before any
block or page logic exists, and nothing after part 6 changes a line's
contents.

The three places where implementations most often diverge are floor division
(see [Floor division and `scale`](#floor-division-and-scale)), the
single-`scale` rule for box widths (see
[Items](#items)), and the exact tie-breaking of the
line-breaking node table (see [The algorithm](#the-algorithm)). Getting
`total-demerits` to agree is a good sign that all three are right.

## Limits and performance

The test suite ranges from one-line documents to a 38-page book with headings
at all four levels, nested lists, eight tables, nine figures, forty-one
footnotes and a table of contents. The largest document is about 110 KB of
`document.cdx` producing 45 pages and about 16000 lines of `layout.txt`; the
document with the most pages produces 176 small pages; the longest single
paragraph has 1800 words; the widest table has 12 columns; one test has a
600-line `@pre` block; and one test sets `tolerance = 0` so that every
paragraph falls back to pass 2.

The line-breaking algorithm as specified is quadratic in the number of
breakpoints of a paragraph, which is fine at these sizes (the worst paragraph
has a few thousand breakpoints, so at most about 16 million candidate lines,
each a handful of integer operations). The page scan is quadratic in
the number of vertical items per page in the worst case. A straightforward
implementation of exactly what is written here runs every test in a fraction
of a second in a compiled language; a per-test limit of 120 seconds is ample.
