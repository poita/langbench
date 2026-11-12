# commonmark — CommonMark subset to HTML

Read a Markdown document from stdin and write the HTML that the CommonMark
reference implementation `cmark` 0.31.2 (default options, no `--unsafe`)
produces for it. The expected outputs of every test were produced by
`cmark`; this document describes precisely what it does on the supported
subset of CommonMark 0.31.2. Section numbers in square brackets, e.g.
[§4.2], refer to the sections of the CommonMark specification
(https://spec.commonmark.org/0.31.2/) whose rules are kept.

Write the Markdown parser and HTML renderer yourself: don't use a Markdown or
CommonMark implementation from a library, the standard library or the language.

## Input and output

- The **entire** stdin is the document, as UTF-8 text. Line endings are
  LF (`\n`) only. The document may or may not end with a newline; it may be
  empty.
- Output is the HTML, as UTF-8, on stdout and nothing else. Every output
  line ends with `\n` (there is no trailing whitespace on any line except
  inside code blocks where it is part of the content). An empty document
  produces empty output. Exit code 0. stderr is ignored.
- The runner ignores trailing whitespace at the end of each output line
  and trailing newlines at the end of the output; everything else must
  match byte for byte.

## The subset

Supported: thematic breaks [§4.1], ATX headings [§4.2], setext headings
[§4.3], indented code blocks [§4.4], fenced code blocks [§4.5], paragraphs
[§4.8], blank lines [§4.9], block quotes [§5.1], list items [§5.2] and
lists [§5.3], backslash escapes [§2.4], entity references [§2.5] (named
references limited to `&amp;` `&lt;` `&gt;` `&quot;`, plus decimal and
hexadecimal numeric references), code spans [§6.1], emphasis and strong
emphasis [§6.2] with the full delimiter-run rules, inline links [§6.3] and
images [§6.4] with all destination and title forms, autolinks [§6.5], hard
line breaks [§6.7], soft line breaks [§6.8] and textual content [§6.9].

Excluded: HTML blocks [§4.6], raw inline HTML [§6.6], link reference
definitions [§4.7] and reference links, and all extensions (tables,
strikethrough, footnotes, ...). The input never contains any of these (see
the guarantees below), so a `<` that is not the start of an autolink is
ordinary text, a `[...]` that is not followed by `(` is ordinary text, and
`&name;` for any name other than the four above is ordinary text.

### What the input never contains (guarantees)

An implementation may rely on all of the following. Tests never violate
them.

1. The input is valid UTF-8 without a byte-order mark. It contains no NUL,
   no CR (`\r`), no DEL (U+007F) and no control character other than TAB
   (U+0009) and LF (U+000A).
2. **No HTML.** Every `<` that is immediately followed by an ASCII letter,
   `/`, `!` or `?` is one of:
   (a) the start of a valid autolink (see "Autolinks"; this is decided by
       the autolink syntax alone, wherever the `<` occurs);
   (b) on a line that belongs to a fenced code block (its opening fence
       line, content lines or closing fence line) or an indented code
       block; or
   (c) inside a code span, or the first character of the `<...>` form of
       the destination of an inline link or image that parses successfully
       (so a correct inline parser consumes that `<` as part of the code
       span or the link and never has to decide what it is). In this case
       the `<` is never the first non-blank character of a line's content
       (its text after any block quote markers `>` and list markers).
   Consequently no HTML block ever starts and no raw inline HTML ever
   occurs. A `<` followed by anything else (space, digit, `>`, `-`, end of
   line, a non-ASCII character, ...) is always plain text.
3. **No link reference definitions.** No paragraph (and no line of any
   block) begins with a link label followed by `:`, i.e. with `[`, then any
   characters other than `]` (possibly spanning lines), then `]`, optional
   spaces or tabs, then `:`. Therefore `[text]` not followed by `(` is
   always literal text, as are `[text][label]` and `[text][]`.
4. **Named entities.** Other than `&amp;`, `&lt;`, `&gt;` and `&quot;`, no
   `&name;` in the input is a valid HTML5 named character reference. So an
   implementation recognizes exactly these four names (case-sensitively)
   and treats every other `&` as text.
5. **Delimiter neighbours.** A character immediately before or after a run
   of `*` or of `_` is never a non-ASCII whitespace, punctuation, symbol or
   control character (Unicode categories Z*, P*, S*, C*). So for the
   emphasis flanking rules, every non-ASCII character can be treated as an
   ordinary (letter-like) character, and only the ASCII definitions of
   whitespace and punctuation below are needed.
6. No run of backticks is longer than 100, and no code fence is longer
   than 100 characters.
7. **Empty list items.** When a list item's first line contains nothing
   after the list marker (e.g. a line `-` or `> 1.`), the following line
   is either non-blank or, after removing its block quote prefixes (each
   `>` with the one optional following space), completely empty. (A
   whitespace-only line after an empty item is excluded.)
8. Size limits are given at the end of this document.

## Preliminaries

- **Whitespace character** (ASCII, the `cmark_isspace` set): space, TAB,
  LF, VT (U+000B), FF (U+000C), CR. Only space, TAB and LF can occur in
  the input, but where the rules say "trim whitespace" this set is meant.
- **Space or tab** means exactly U+0020 or U+0009.
- **ASCII punctuation character**: any of `` !"#$%&'()*+,-./:;<=>?@[\]^_`{|}~ ``.
- **Line**: the document is split into lines at every `\n`. The `\n` is
  not part of the line, but every line is processed as if it were followed
  by exactly one `\n` (so "end of line" below means that terminator). A
  final line that is not newline-terminated is still a line; a trailing
  `\n` at the end of the document does not create an extra empty line.
- **Blank line**: a line containing only spaces and tabs (or nothing).
- **Tabs and columns** [§2.2]: tabs are not expanded to spaces, but for
  all indentation computations a tab advances to the next multiple of 4
  columns, counting columns from the start of the line (column 0). When a
  rule "consumes N columns" of indentation and a tab straddles the
  boundary, the tab is *partially consumed*: the remaining columns of that
  tab are treated as that many spaces belonging to the content. The
  "indent" of a position is the number of columns of spaces and tabs
  between the current position and the next non-space/tab character.

The conversion works in two phases exactly as in [Appendix A] of the
CommonMark specification: phase 1 builds the tree of blocks line by line;
phase 2 parses the raw content of paragraphs and headings into inlines.
The tree is then rendered to HTML.

## Phase 1: block structure

Block kinds: **document**, **block quote**, **list**, **list item**
(containers) and **paragraph**, **ATX/setext heading**, **thematic
break**, **indented code block**, **fenced code block** (leaves). Only the
document, block quotes and list items can contain arbitrary blocks; a
list contains only list items. Paragraphs, headings and code blocks
accumulate raw text lines. A block is *open* until it is *closed*; at any
time the open blocks form a single chain from the document down to the
*tip* (the innermost open block).

### Processing one line

The parser keeps a position `offset` (character index into the line) and
`column` (the column of that position, tabs expanded as above), both 0 at
the start of the line, and `partially_consumed_tab` (initially false). The
"rest of the line" always means the text from `offset` to the end of line,
with a partially consumed tab replaced by its remaining columns as
spaces. `indent` is the number of columns from `column` to the first
non-space/tab character after `offset`; the line is *blank at this point*
if that character is the end of line.

**Step 1 — continue open blocks.** Walk down the chain of open blocks:
the document's last child if it is open, then that block's last child if
it is open, and so on. For each block B (with `indent` and blankness
recomputed at the current position):

- *block quote*: continues if `indent <= 3` and the first non-space/tab
  character is `>`. Consume `indent + 1` columns (the spaces and the `>`),
  then, if the next character is a space or tab, consume one more column
  of it (a tab may be partially consumed). Otherwise it fails.
- *list item* (with marker offset `M` and padding `P` recorded when it
  was opened): if `indent >= M + P`, consume `M + P` columns and continue.
  Otherwise, if the line is blank at this point and the item already has
  at least one child block, advance to the first non-space/tab character
  and continue. Otherwise it fails.
- *list*: always continues.
- *indented code block*: if `indent >= 4`, consume 4 columns and
  continue; else if blank at this point, advance to the first
  non-space/tab character and continue; else fail.
- *fenced code block* (fence character `c`, fence length `L`, fence
  offset `F`): if `indent <= 3` and the rest of the line starts with a run
  of at least `L` characters `c` followed only by spaces/tabs to the end of
  line, this is the closing fence: close the code block and **stop
  processing this line entirely**. Otherwise consume up to `F` columns of
  leading spaces/tabs, one column at a time, stopping at the first
  non-space/tab character (a tab may be partially consumed), and continue.
- *heading*: always fails (it is single-line).
- *thematic break*: always matches. It has no children, so the walk ends with it as `last_matched` and `all_matched` true. This matters for the last-line-blank rule below: a blank line after a thematic break inside a list item is attributed to the thematic break, not the item, so the list stays tight.
- *paragraph*: continues unless the line is blank at this point.

Stop at the first block that fails; call the last block that continued
`last_matched` (the document if none) and remember whether *all* open
blocks continued (`all_matched`).

**Step 2 — start new blocks.** Let `container = last_matched`. Unless
`container` is a code block, repeat: recompute `indent` and the first
non-space/tab character `c` at the current position, let
`indented = indent >= 4`, and try, in this order:

1. **Block quote start** [§5.1]: not `indented` and `c == '>'`. Advance
   past the `>`; if the next character is a space or tab consume one
   column of it. Open a block quote as a child of `container` (closing
   blocks as described under "Adding a child").
2. **ATX heading start** [§4.2]: not `indented` and the rest matches
   `#{1,6}` followed by one or more spaces/tabs or by the end of line.
   Advance past the `#`s and *all* of those spaces/tabs. Open a heading
   with level = number of `#`.
3. **Fenced code start** [§4.5]: not `indented` and the rest starts with
   three or more backticks and the remainder of the line contains no
   backtick, or three or more tildes (remainder arbitrary). Open a fenced
   code block with `c` = the fence character, `L` = the run length, and
   `F` = the number of characters between the current position and the
   fence (0–3 spaces). Advance past the fence (the info string stays as
   the rest of the line).
4. **Setext underline** [§4.3]: not `indented`, `container` is a
   paragraph (so it was matched in step 1 with all blocks matched), and
   the rest is a run of `=` or a run of `-` followed only by spaces/tabs
   to the end of line. Turn the paragraph into a setext heading (level 1
   for `=`, 2 for `-`) keeping its content; advance to the end of line.
5. **Thematic break** [§4.1]: not `indented`, `c` is `*`, `_` or `-`, and
   the rest consists of three or more of that same character interleaved
   with any spaces/tabs, up to the end of line. Open a thematic break and
   advance to the end of line. (Because 4 is tried first, `---` under a
   paragraph is a setext heading; `***` cannot be a list item because 5
   precedes 6.)
6. **List item** [§5.2]: `indent < 4` and a list marker is present: a
   bullet marker `-`, `+` or `*`, or an ordered marker of 1–9 ASCII digits
   followed by `.` or `)`; the character after the marker must be a
   whitespace character (a space, tab or the end of line). If `container`
   is a paragraph (the marker would interrupt it), additionally the marker
   must be followed by non-blank content on the same line, and an ordered
   marker must have the number 1 (`1.`/`1)`); otherwise there is no list
   item start. Let `W` = width of the marker in characters (including the
   `.`/`)`). Advance past the marker, then count the columns `n` of
   spaces/tabs that follow (counting may stop once `n` exceeds 5; a tab
   counts its columns). If `n` is 0 or `n >= 5`, or the first character
   after those spaces/tabs is the end of line (blank item): padding
   `P = W + 1`, and only one column of whitespace after the marker is
   consumed (if there is any; a tab may be partially consumed);
   otherwise `P = W + n` and all `n` columns are consumed. Marker offset `M = indent` (the
   indentation before the marker, measured from the current position).
   If `container` is a list of the same type (same bullet character, or
   ordered with the same delimiter), add the item to it; otherwise open a
   new list (as a child of `container`) with the item's type, and start
   number = the marker's number for ordered lists (leading zeros ignored,
   e.g. `003.` is 3). Then open the item inside the list.
7. **Indented code start** [§4.4]: `indented`, the line is not blank at
   this point, and *not* (`maybe_lazy`), where `maybe_lazy` is true at the
   first iteration of this step if the tip (the innermost block that was
   open before this line) is a paragraph, and becomes false as soon as
   any block has been opened in this step. (So an indented line after a
   paragraph is a paragraph continuation, lazy or not, never code.)
   Consume 4 columns (a tab may be partially consumed) and open an
   indented code block.
8. Otherwise stop repeating.

After opening a block quote, list or list item, repeat the step (with
`container` = the new block). After opening a leaf (heading, code block,
thematic break) stop.

**Adding a child** to `container`: if `container` cannot hold the new
block (a list can only hold items; anything else can hold anything but an
item), close `container` and try its parent, repeatedly. Closing a block
closes all its open descendants first. The new block becomes the last
child of the first suitable ancestor.

**Step 3 — add the text of the line.** Recompute blankness at the current
position. Then update the "last line blank" flags used for list
tightness: if the line is blank and `container` has a last child, set
that child's flag to true. Set `container`'s own flag to true if the line
is blank and `container` is not a block quote, heading, thematic break or
fenced code block, and is not a list item that has no children and was
opened on this very line; otherwise false. Set the flag of every ancestor
of `container` to false.

Then:

- **Lazy continuation** [§5.1, §5.2]: if not `all_matched`, no block was
  opened in step 2 (`container` is still `last_matched`), the line is not
  blank, and the tip is a paragraph, append the rest of the line (from
  the current `offset`, **without** removing leading whitespace) plus
  `\n` to that paragraph. Nothing is closed.
- Otherwise close every open block below `last_matched` (the tip up to
  but not including `last_matched`), then:
  - if `container` is a code block: append the rest of the line plus `\n`
    to its content (for a blank line this is the whitespace after the
    consumed indentation, or nothing);
  - else if the line is blank: nothing;
  - else if `container` is a heading or paragraph: for an ATX heading
    first remove the optional closing sequence (see ATX headings); then
    skip the spaces/tabs at the current position and append the rest of
    the line plus `\n` to the block;
  - else: open a new paragraph in `container` (closing blocks as
    needed), skip spaces/tabs and append the rest of the line plus `\n`.

The tip is now `container` (or the new paragraph). After the last line,
close all open blocks.

### Block details

**ATX headings.** The content is the rest of the line after the `#`s and
the following whitespace, with: trailing whitespace removed; then, if what
remains ends in one or more `#` preceded by a space or tab, those `#`s
and the whitespace before them removed (again trimming trailing
whitespace). `# foo #`, `# foo ###   `, `#`, `# #`, `### ###` give
`foo`, `foo`, ``, ``, ``. A `#` run not preceded by whitespace stays:
`# foo#` → `foo#`; `# foo \#` → `foo #` (the `\#` is an escape).

**Setext headings.** The content is the paragraph's accumulated lines (a
multi-line paragraph becomes a multi-line heading; lazy lines included).
Only a paragraph that was continued in step 1 with all blocks matched can
become a setext heading, so `> foo\n---` is a block quote followed by a
thematic break, and `- foo\n---` is a list followed by a thematic break.

**Indented code blocks.** The content is the concatenation of the lines
appended (each line with its first 4 columns of indentation removed, blank
lines contributing their remaining whitespace and `\n`); then trailing
blank lines are removed: strip all trailing spaces, tabs and newlines, and
cut at the first newline at or after that point; then append one `\n`.
Trailing spaces on the last non-blank line are kept (`    foo  ` gives
`foo  \n`).

**Fenced code blocks.** The first appended line (the rest of the opening
fence line) is the **info string**: decode entity references (same rules
as for inline entities), trim whitespace at both ends, then remove
backslash escapes (a backslash before
an ASCII punctuation character is deleted; this happens *after* entity
decoding, so `&#92;*` becomes `*` and `\&amp;` becomes `&`). The content
is every following appended line, each with up to `F` leading columns of
spaces/tabs removed (as done in step 1) — content is never otherwise
altered, and a block left open at the end of the document ends there. An
opening fence that is not closed before its container closes simply ends
with the container.

**Paragraphs.** Content is the appended lines; each non-lazy line has its
leading spaces/tabs removed, lazy lines are appended verbatim. Phase 2
strips trailing whitespace of the whole content.

**Lists: tight or loose.** When a list is closed, it is *tight* unless
either (a) some item other than the last has its last-line-blank flag
set, or (b) some item I has a child block B such that (I is not the last
item, or B is not the last child of I) and B "ends with a blank line",
defined recursively: for a list or a list item that has children, whether
its last child ends with a blank line; for any other block, its own
last-line-blank flag. As in cmark, this test is memoised per block and the
memo changes some answers: the first time "ends with a blank line" is
evaluated for a block (directly or as part of the recursion) the block is
marked as checked, and every later evaluation for a checked block returns
its own last-line-blank flag without recursing. The test is evaluated only
when the (I is not the last item, or B is not the last child of I)
condition holds. Items are visited in document order, each one's own flag
(rule (a)) before its children in order (rule (b)), and the visit stops as
soon as the list is known to be loose. Lists are closed innermost first, so a nested
list's evaluations happen before its enclosing list's. (This is [§5.3]'s definition — items separated by
blank lines, or two blocks in an item separated by a blank line — made
operational; blank lines inside fenced code blocks or inside a block quote
never count, and a blank line ending an item's indented code block
counts.)

## Phase 2: inlines

The **content** of a paragraph or heading is its accumulated text with
trailing whitespace removed (all of the whitespace set, including the
final `\n`). It is parsed left to right into a sequence of inline nodes:
*text*, *softbreak*, *linebreak*, *code*, *emph*, *strong*, *link*,
*image*. Maintain a *delimiter stack* (for `*`/`_` runs) and a *bracket
stack* (for `[` and `![`), and a flag `link_closed` (initially true).

Repeat while not at the end of the content, looking at the character `ch`
at the current position:

- `\n`: **line break** [§6.7, §6.8]. If the two characters before the
  `\n` are both spaces, emit a *linebreak*, else a *softbreak*. Advance
  past the `\n` and past all spaces and tabs that follow it.
- `` ` ``: **code span** [§6.1]. Let `n` be the length of the backtick
  run and `p` the position just after it. Search forward from `p` for a
  run of exactly `n` backticks (a longer or shorter run does not count),
  using cmark's backtick memo exactly as follows, because it decides some
  outcomes (it can report "not found" although a run of length `n` exists
  further on, and the tests depend on this). The memo belongs to the
  inline parse of one leaf block's content: an array `last[k]` of
  positions, all initially 0, and a flag `scanned`, initially false. If
  `scanned` is set and `last[n] <= p`, the search fails at once without
  scanning. Otherwise scan forward from `p` over the backtick runs; for
  each run met, of length `k` starting at position `s`, set `last[k] = s`
  (overwriting any earlier value, even a larger one), and stop with
  success if `k = n`. If the scan reaches the end of the content without
  success, set `scanned` and fail. If found, the code span's content is the
  text between the runs with every `\n` replaced by a space; if it both
  begins and ends with a space and is not entirely spaces, one space is
  removed from each end. Emit a *code* node and continue after the closing
  run. If not found, emit the opening run as text and continue after it.
- `\`: **backslash** [§2.4]. If the next character is an ASCII
  punctuation character, emit it as text (two characters consumed). Else
  if the next character is `\n`, emit a *linebreak* and consume both (the
  following line's leading whitespace is **not** skipped here). Otherwise
  emit `\` as text.
- `&`: **entity** [§2.5]. Try to match, starting right after the `&`:
  `#` + 1–7 decimal digits + `;`, or `#x`/`#X` + 1–6 hex digits + `;`, or
  one of `amp;` `lt;` `gt;` `quot;`. Numeric references give the
  character with that code point, except that 0, surrogates
  (U+D800–U+DFFF) and values above U+10FFFF give U+FFFD. Emit the decoded
  character as text and continue after the `;`. If nothing matches
  (including `&#12345678;` with 8 digits, `&#;`, `&#x;`, `&foo;`, `&amp`),
  emit `&` as text and continue after it.
- `<`: **autolink** [§6.5]. If the text after `<` matches
  `[A-Za-z][A-Za-z0-9.+-]{1,31}:[^\x00-\x20<>]*>` (URI autolink) or
  `[a-zA-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*>`
  (email autolink; tried second), emit a *link* whose destination is the
  text between the brackets with entity references decoded (an email
  destination is prefixed with `mailto:`), whose title is absent, and
  whose single child is that same text (entities decoded) as a text node.
  Backslash escapes are not processed in autolinks. Otherwise emit `<` as
  text.
- `*` or `_`: **delimiter run** [§6.2]. Take the whole run of that
  character (length `n`). Let `before` be the character before the run
  (or `\n` if at the start of the content) and `after` the character
  after it (or `\n` if at the end). Using *whitespace* = the whitespace
  set above (with `\n` counting) and *punctuation* = ASCII punctuation
  (guarantee 5 lets non-ASCII characters count as neither):
  - left-flanking = `after` is not whitespace, and (`after` is not
    punctuation, or `before` is whitespace or punctuation);
  - right-flanking = `before` is not whitespace, and (`before` is not
    punctuation, or `after` is whitespace or punctuation);
  - for `*`: can_open = left-flanking, can_close = right-flanking;
  - for `_`: can_open = left-flanking and (not right-flanking or `before`
    is punctuation); can_close = right-flanking and (not left-flanking or
    `after` is punctuation).
  Emit the run as a text node; if can_open or can_close, push a delimiter
  entry {char, original length `n`, can_open, can_close, that text node,
  position = index just after the run}.
- `[`: emit `[` as a text node and push a bracket entry {image=false,
  that node, position = index after `[`}; set `link_closed = false`.
- `!`: if followed by `[`, emit `![` as one text node and push a bracket
  entry {image=true, node, position after the `[`} (without changing
  `link_closed`: in `[x [a](/b) ![i](/j) y](/d)` the outer `[x` stays
  text because the `![` does not clear the flag set by `[a](/b)`);
  otherwise emit `!` as text.
- `]`: **close bracket** [§6.3, §6.4]. If the bracket stack is empty,
  emit `]` as text. Else let `opener` be the top entry. If it is not an
  image and `link_closed` is true, pop it and emit `]` as text. Otherwise
  try to parse an inline link right after the `]`:
  1. the next character must be `(`; then skip any whitespace characters
     (spaces, tabs, newlines);
  2. **destination**: either `<` ... `>` containing no `\n` and no
     unescaped `<` (a backslash skips the following character whatever it
     is; the first unescaped `>` ends it), the destination being the text
     between the brackets; or a bare destination scanned as follows: a
     backslash followed by ASCII punctuation is skipped as a pair; `(`
     increases a nesting count (more than 32 open parentheses makes the
     destination invalid); `)` at nesting 0 ends the destination,
     otherwise decreases the count; a whitespace character ends the
     destination; any other character is taken. The nesting count must
     be 0 at the end, and the end of the content must not have been
     reached. (So `[a]()` has an empty destination, `[a](<>)` too, and
     `[a](/my uri)` is invalid because the next step finds `u` instead of
     a title or `)`.)
  3. skip whitespace; if any was skipped and the next character starts a
     **title** — `"..."`, `'...'` or `(...)` — take the title as the
     *longest* match in which the closing delimiter character (and, for
     the `(...)` form, also `(`) appears inside only when immediately
     preceded by a backslash; titles may span lines. If no whitespace
     separated destination and title, there is no title (and the parse
     will fail at the next step unless the next character is `)`).
  4. skip whitespace; the next character must be `)`.
  If this succeeds: the raw destination is trimmed of whitespace at both
  ends, entity references are decoded, then backslash escapes are removed
  (backslash before ASCII punctuation is deleted — after entity decoding,
  so `\&amp;` gives `&` and `&#92;*` gives `*`). The title, if present,
  has its surrounding quotes/parentheses removed and is processed the
  same way (entities, then backslashes); a present-but-empty title (`""`)
  is still a title. Create a *link* or *image* node (per the opener),
  move all inline nodes after the opener's text node into it as its
  children, remove the opener's text node, run **process emphasis** with
  `stack_bottom` = the opener's position (see below) on the delimiters
  inside, pop the bracket entry, and if it was a link set
  `link_closed = true`. Continue after the `)`.
  If it fails: pop the bracket entry, emit `]` as text and continue right
  after the `]` (the `(` and following text are parsed normally).
  (`link_closed` implements [§6.3]'s rule that links may not contain
  links: once a link has been formed, an enclosing `[` cannot become a
  link; a `[` pushed afterwards clears the flag again. This single flag is
  exactly what cmark does and it is what the tests expect, even where it
  differs from the specification's "deactivate all earlier openers" rule:
  in `[x [a](/b) ![i [q] j](/k) y](/d)` the `[q` clears the flag, its `]`
  fails to parse a link and leaves the flag clear, so the outer `[x`
  becomes a link containing the link `a`: `<a href="/d">x <a href="/b">a</a>
  <img src="/k" alt="i [q] j" /> y</a>`.)
- Any other character: emit as text the maximal run up to (not
  including) the next character among `` \n ` \ & < * _ [ ] ! ``; if that
  run ends right before a `\n`, remove its trailing whitespace first.

At the end run **process emphasis** with `stack_bottom = 0`.

**Process emphasis** [§6.2, Appendix A] over the delimiter stack entries
with position `>= stack_bottom`, using `openers_bottom[kind]` initialized
to `stack_bottom` for each of the 12 kinds (`*` or `_`) × (can_open or
not) × (*original* run length mod 3; the kind of an entry never changes
even after some of its characters have been used):

Let `closer` be the first entry (lowest position) with position
`>= stack_bottom`. While `closer` exists:
- if `closer.can_close`: let `kind` be its kind. Walk `opener` backwards
  from the entry before `closer` while `opener` exists and
  `opener.position >= openers_bottom[kind]`, looking for the first with
  `opener.can_open` and the same character such that **either** neither
  `closer.can_open` nor `opener.can_close` (neither is both an opener and
  a closer), **or** `closer.length % 3 == 0`, **or**
  `(opener.length + closer.length) % 3 != 0` (lengths are the original
  run lengths; this is the "rule of 3"). If found: `use = 2` if both
  text nodes currently have at least 2 characters, else 1; remove `use`
  characters from the end of the opener's text and the start of the
  closer's text; remove every delimiter entry strictly between opener and
  closer; wrap all inline nodes strictly between the two text nodes in a
  new *strong* (`use == 2`) or *emph* (`use == 1`) node placed between
  them; if the opener's text became empty remove its node and its entry;
  if the closer's text became empty remove its node and its entry and let
  `closer` be the next entry, else keep `closer` (it may close again).
  If no opener is found: set `openers_bottom[kind] = closer.position`,
  remove `closer` from the stack if it cannot open, and move to the next
  entry.
- else move to the next entry.
Finally remove all entries with position `>= stack_bottom`.

## HTML rendering

Render the tree in document order. `cr()` means: output `\n` unless the
output is empty or already ends with `\n`.

- document: nothing.
- block quote: `cr()`, `<blockquote>\n`, children, `cr()`,
  `</blockquote>\n`.
- list: `cr()`, then `<ul>\n`, or `<ol>\n` if ordered with start 1, or
  `<ol start="N">\n` otherwise (N in decimal, e.g. `<ol start="0">`);
  items; `</ul>\n` or `</ol>\n`.
- list item: `cr()`, `<li>`, children, `</li>\n`. (`- ` alone gives
  `<li></li>`.)
- paragraph: if its grandparent is a **tight** list (i.e. it is directly
  inside an item of a tight list): just its inlines. Otherwise `cr()`,
  `<p>`, inlines, `</p>\n`.
- heading level k: `cr()`, `<hk>`, inlines, `</hk>\n`.
- code block: `cr()`, then `<pre><code>` if the info string is empty,
  else `<pre><code class="language-X">` where X is the info string up to
  its first whitespace character, HTML-escaped, and the prefix
  `language-` is omitted when the info string already starts with
  `language-` (so info `language-foo` gives `class="language-foo"`); then
  the content HTML-escaped, then `</code></pre>\n`.
- thematic break: `cr()`, `<hr />\n`.
- text: HTML-escaped. softbreak: `\n`. linebreak: `<br />\n`.
- code: `<code>` + escaped content + `</code>`.
- emph: `<em>`...`</em>`; strong: `<strong>`...`</strong>`.
- link: `<a href="` + href(dest) + `"`, then ` title="` + escaped title
  + `"` if a title is present, then `>`, children, `</a>`.
- image: `<img src="` + href(dest) + `" alt="` + alt + `"`, then
  ` title="` + escaped title + `"` if present, then ` />`. **alt** is the
  plain text of the image's descendants: text and code nodes escaped,
  soft and hard breaks as a single space, everything else (emphasis
  tags, nested link/image markup) contributing only its own descendants.

**HTML-escaping** replaces `&` `<` `>` `"` with `&amp;` `&lt;` `&gt;`
`&quot;`; nothing else is escaped (not `'`, not non-ASCII).

**href(dest)**: if the destination, case-insensitively, starts with
`javascript:`, `vbscript:`, `file:` or `data:` — except when it starts
with `data:image/png`, `data:image/gif`, `data:image/jpeg` or
`data:image/webp` (case-insensitive) — the attribute value is empty.
Otherwise encode the destination's UTF-8 bytes: bytes for the characters
`A-Z a-z 0-9 - _ . ~ ! # $ % ( ) * + , / : ; = ? @` are copied; `&`
becomes `&amp;`; `'` becomes `&#x27;`; every other byte (space, `"`, `<`,
`>`, `[`, `\`, `]`, `^`, `` ` ``, `{`, `|`, `}`, control bytes and all
bytes >= 0x80) becomes `%XX` with uppercase hex. Existing `%` signs are
copied unchanged (`%20` stays `%20`).

## Worked examples

Input 1 (`→` stands for a tab character):
```
# Title #

Some *emphasis*, **strong**, `code` and a [link](</my uri> "t\"x").

- one
- two
  - nested

1. a

   b
2. c

> quote  
> line\
→lazy

    code <b>
```
Output (the lazy line after the backslash hard break keeps its tab; the
ordered list is loose because item `a` contains two paragraphs; the
bullet list is tight):
```
<h1>Title</h1>
<p>Some <em>emphasis</em>, <strong>strong</strong>, <code>code</code> and a <a href="/my%20uri" title="t&quot;x">link</a>.</p>
<ul>
<li>one</li>
<li>two
<ul>
<li>nested</li>
</ul>
</li>
</ul>
<ol>
<li>
<p>a</p>
<p>b</p>
</li>
<li>
<p>c</p>
</li>
</ol>
<blockquote>
<p>quote<br />
line<br />
	lazy</p>
</blockquote>
<pre><code>code &lt;b&gt;
</code></pre>
```

Input 2:
```
*foo**bar**baz* _a_b_ **a *b* c** ![alt *x* `y`](/i.png)
<http://a.b/?x=1&y=2> &amp;copy; &#65;&#x42;&#0; \*lit\* a\
b
```
Output (`*foo**bar**baz*` shows the rule of 3; the middle `_` of `_a_b_`
is intraword and neither opens nor closes; `&#0;` becomes U+FFFD, shown
here as its UTF-8 bytes rendered by your terminal):
```
<p><em>foo<strong>bar</strong>baz</em> <em>a_b</em> <strong>a <em>b</em> c</strong> <img src="/i.png" alt="alt x y" />
<a href="http://a.b/?x=1&amp;y=2">http://a.b/?x=1&amp;y=2</a> &amp;copy; AB� *lit* a<br />
b</p>
```

Input 3:
```
- a
- ```py
  x = "<>"
  ```
- c

  d
* e
***
Foo
---
[j](javascript:alert(1)) [k](/x "") [](<>)
```
Output (`  d` has indent 2 = the item's required indent, so it is a
second paragraph of item `c`, which makes the whole first list loose; `*`
starts a new list because the bullet character changes; `***` is a
thematic break, not an item; `Foo` + `---` is a setext heading; the
`javascript:` destination renders empty; the empty title is kept):
```
<ul>
<li>
<p>a</p>
</li>
<li>
<pre><code class="language-py">x = &quot;&lt;&gt;&quot;
</code></pre>
</li>
<li>
<p>c</p>
<p>d</p>
</li>
</ul>
<ul>
<li>e</li>
</ul>
<hr />
<h2>Foo</h2>
<p><a href="">j</a> <a href="/x" title="">k</a> <a href=""></a></p>
```

## Limits

- Inputs are at most 1 MB. The largest tests are a 770 KB fenced code
  block, a 750 KB ordered list of 12,000 items with inline links and code
  spans, a 360 KB single paragraph, 200 KB random documents mixing every
  construct, block quotes and lists nested 300 deep, a line with 5,000
  unmatched `[` followed by 5,000 `]`, 8,000 `_` runs, 12,000 `**`s and
  thousands of backtick runs.
- Nesting depth of blocks never exceeds 300; recursion of that depth is
  fine. Inline nesting (brackets, emphasis) can be several thousand deep
  in the delimiter/bracket stacks but the algorithms above are iterative.
- Avoid quadratic behaviour in the code-span search, the bracket handling
  and process-emphasis (the `openers_bottom` bounds make it linear).
