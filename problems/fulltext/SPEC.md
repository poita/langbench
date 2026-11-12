# fulltext — full-text search engine

Index a corpus of plain-text documents, evaluate a list of boolean/phrase
queries against it, and write a ranked answer with BM25 scores and snippets.

This is a **directory-mode** problem. The program is invoked with exactly two
arguments:

```
<command> <input directory> <output directory>
```

The output directory already exists and is empty (an implementation may also
create it if it is missing). The program writes exactly two files into it and
writes nothing anywhere else. Nothing is read from stdin; anything written to
stdout or stderr is ignored. The exit code must be 0.

All text, input and output, is UTF-8 with LF (`\n`) line endings and no
byte-order mark.

Every input in the test suite is valid as described here. An implementation
may do anything at all on an input that violates this specification — the
tests never contain one — but it must not fail on a valid input.

Write the indexing, stemming and ranking yourself: don't use a search, stemming
or text-analysis routine from a library, the standard library or the language.
Sorting, containers, file I/O, regular expressions and `log` from the standard
library are fine.

## Contents

1. [Architecture and size](#architecture-and-size)
2. [Input layout](#input-layout)
3. [Text analysis](#text-analysis)
4. [The Porter stemmer](#the-porter-stemmer)
5. [The index](#the-index)
6. [queries.txt](#queriestxt)
7. [The query language](#the-query-language)
8. [Boolean matching](#boolean-matching)
9. [Scoring](#scoring)
10. [Ranking](#ranking)
11. [Snippets](#snippets)
12. [Output](#output)
13. [Worked example](#worked-example)
14. [Guarantees](#guarantees)
15. [Input sizes](#input-sizes)

## Architecture and size

A complete implementation has six parts:

1. **The analyser** (~120 lines) — a tokeniser, ASCII case folding, apostrophe
   removal, the stop-word set.
2. **The Porter stemmer** (~250 lines) — the 1980 algorithm, spelled out in
   full below. This is fiddly but entirely mechanical.
3. **The index** (~100 lines) — term → document → sorted positions, plus
   document lengths and the corpus statistics.
4. **The query parser** (~200 lines) — a lexer for words, quoted phrases,
   parentheses and the three operators, and a recursive-descent parser.
5. **Matching and scoring** (~150 lines) — positional phrase matching,
   boolean set algebra, BM25.
6. **Snippets and output** (~120 lines) — the best-window search and the
   result formatting.

Total: roughly 900–1400 lines in a typical systems language. The stemmer is
the single largest piece and is worth implementing and testing first; the
official Porter test vocabulary is a public data set that makes this easy.

## Input layout

```
<input>/
    docs/
        <id>.txt          zero or more documents
    queries.txt           the queries
```

- A **document** is a regular file directly inside `docs/` whose name ends
  with `.txt`. Nothing else in `docs/` is read; `docs/` itself may be missing
  or empty, in which case the corpus has no documents. `docs/` never contains
  subdirectories in the tests.
- The **document id** is the file name with the trailing `.txt` removed. Ids
  are unique. They are compared and ordered by Unicode code point
  (equivalently, by UTF-8 byte order — ids in the tests are ASCII).
- The document **text** is the file's contents, decoded as UTF-8, with no
  further transformation: no line-ending translation, no trimming, no
  normalisation. A document may be empty.
- `queries.txt` is always present.

## Text analysis

Documents and queries are analysed by the same three steps: tokenise, fold,
stem.

### Token characters

A code point is a **token character** if and only if it lies in one of these
ranges:

| From | To | What |
|------|----|------|
| U+0030 | U+0039 | ASCII digits |
| U+0041 | U+005A | ASCII upper case |
| U+0061 | U+007A | ASCII lower case |
| U+00C0 | U+00D6 | Latin-1 letters (À … Ö) |
| U+00D8 | U+00F6 | Latin-1 letters (Ø … ö) |
| U+00F8 | U+024F | Latin-1 letters (ø … ɏ), Latin Extended-A and -B |
| U+0370 | U+03FF | Greek and Coptic |
| U+0400 | U+04FF | Cyrillic |

Every other code point — including U+00D7 (×), U+00F7 (÷), all punctuation,
all whitespace, the em dash, the curly quotation marks and everything above
U+04FF — is a separator.

An **apostrophe** is U+0027 (`'`) or U+2019 (`’`).

### Tokenising

Scan the text from left to right. A **token** is a maximal run that matches

```
TOKENCHAR+ ( APOSTROPHE TOKENCHAR+ )*
```

that is: one or more token characters, optionally continued by single
apostrophes each of which is immediately preceded *and* immediately followed
by a token character. A leading, trailing or doubled apostrophe is a
separator, not part of a token. Tokens never overlap and never touch: the
scanner takes the longest match at each starting position and resumes after
it.

Examples (the text, then its tokens):

| Text | Tokens |
|------|--------|
| `The cat sat.` | `The`, `cat`, `sat` |
| `don't stop` | `don't`, `stop` |
| `'quoted'` | `quoted` |
| `rock'n'roll` | `rock'n'roll` |
| `a''b` | `a`, `b` |
| `well-known` | `well`, `known` |
| `Version 1.2.3` | `Version`, `1`, `2`, `3` |
| `X1 XY2Z` | `X1`, `XY2Z` |
| `Don’t` | `Don’t` |

The **position** of a token is its 0-based index in the document's token
sequence. The **character span** of a token is the half-open range of code
point offsets `[start, end)` it occupies in the original text.

### Folding

The **token text** is obtained from a token by

1. deleting every apostrophe, then
2. mapping every code point in U+0041…U+005A (`A`–`Z`) to the code point
   32 greater (`a`–`z`).

No other case mapping is applied. `Café` folds to `café`; `CAFÉ` folds to
`cafÉ`; these are two different token texts, and that is intended — the
analyser is deliberately ASCII-only in its case handling. `don't` and
`Don’t` both fold to `dont`.

A folded token is never empty.

### Stop words

The stop-word set is exactly these 33 token texts:

```
a       an      and     are     as      at      be      but     by
for     if      in      into    is      it      no      not     of
on      or      such    that    the     their   then    there   these
they    this    to      was     will    with
```

Stop words are **indexed like any other token** — they occupy positions and
they take part in phrase matching. The stop-word set matters only when a
query produces a single-token search atom; see
[The query language](#the-query-language).

The set is tested against the token text, *before* stemming.

### Stemming

The **term** of a token is:

- the Porter stem of its token text, if the token text consists only of the
  ASCII letters `a`–`z`;
- the token text unchanged otherwise (so any token containing a digit or a
  non-ASCII character is never stemmed).

## The Porter stemmer

The stemmer is the original Porter algorithm of 1980, in the form of Martin
Porter's own reference implementation `porter.c`, including its two documented
departures from the published paper. The rules below are complete and
authoritative for this problem; the algorithm is also described at
<https://tartarus.org/martin/PorterStemmer/>, and Porter's test vocabulary
(`voc.txt` with its `output.txt`) is vendored in `corpus/porter/` — a correct
implementation reproduces all 23531 of those stems exactly.

Throughout, the word being stemmed is a non-empty string `b` of ASCII lower
case letters. Write `b[i]` for its `i`-th letter, 0-based.

### Definitions

- **Consonant.** `b[i]` is a consonant unless it is one of `a e i o u`, or it
  is `y` and `i > 0` and `b[i-1]` is *not* a consonant. So `y` at the start of
  a word is a consonant, and `y` after a consonant is a consonant, while `y`
  after a vowel is a vowel. A letter that is not a consonant is a **vowel**.
- **Measure.** Any word can be written `[C] (VC){m} [V]`, where `C` is a
  non-empty run of consonants, `V` a non-empty run of vowels, and the
  bracketed parts are optional. `m` is the **measure** of the word. Examples:
  `tr`, `ee`, `tree`, `y`, `by` have m = 0; `trouble`, `oats`, `trees`, `ivy`
  have m = 1; `troubles`, `private`, `oaten` have m = 2.
- Every rule below is written `(condition) SUFFIX -> REPLACEMENT` and applies
  to the whole word: `SUFFIX` is matched at the end of the word, and the
  condition — when there is one — is evaluated on the **stem**, meaning the
  part of the word that would remain once `SUFFIX` is removed.
- `m > 0`, `m = 1`, `m > 1` mean the measure of that stem.
- `*v*` means the stem contains a vowel.
- `*d` means the stem ends with two identical consonants.
- `*o` means the stem ends consonant-vowel-consonant, where the final
  consonant is not `w`, `x` or `y`.

If the word is one or two letters long, it is returned unchanged and no step
is applied.

**How a rule is chosen.** Within one step the rules are tried in the order
printed and **at most one of them fires**. A rule is *selected* by its suffix
alone: the first rule whose `SUFFIX` matches the end of the word is selected,
and no later rule is looked at. Its condition is then evaluated; if the
condition fails, the step does nothing at all — the word is *not* handed on to
the rules below it.

This matters wherever one suffix ends with another. In step 1b, `feed` selects
`EED` (its stem `f` has m = 0, so the condition fails) and step 1b therefore
leaves `feed` alone; it does **not** go on to try `ED`, which would give `fe`.
Likewise `bleed` stays `bleed` and `need` stays `need`.

Two places in the tables below depart from that scheme, and both are called
out again where they appear:

- **Step 5a** has two rules with the same suffix `E`. They are tried in order
  and the second *is* considered when the first one's condition fails, so the
  step is really the single rule `(m>1 or (m=1 and not *o)) E ->`.
- The **second block of step 1b** (the `AT`/`BL`/`IZ` block) ends with two
  rules that have no suffix at all; those two are selected by their condition
  instead. It is written out as an ordered chain there.

In the rule tables below, the examples show what that one rule does to the
word, not the word's final stem: later steps may shorten it further, so
`agreed` reaches step 1b's `EE` but leaves the stemmer as `agre`.

### Step 1a

The first rule whose suffix matches fires; none has a condition. A word that
does not end in `s` is left alone.

```
SSES -> SS      caresses -> caress
IES  -> I       ponies   -> poni      ties -> ti
SS   -> SS      caress   -> caress
S    ->         cats     -> cat
```

### Step 1b

```
(m>0)  EED -> EE        feed -> feed      agreed -> agree
(*v*)  ED  ->           plastered -> plaster    bled -> bled
(*v*)  ING ->           motoring -> motor        sing -> sing
```

The selection rule above applies here in full: a word ending in `EED` selects
the first rule and nothing else, whether or not its `m>0` condition holds.
`feed`, `need`, `bleed` and `deed` are therefore unchanged by step 1b, while
`agreed` becomes `agree`.

If, and only if, the second or third of those rules removed a suffix, the
following is applied to what is left. These five are an ordered chain, each
tried only when the one above it did not fire; the last two have no suffix and
are selected by their condition:

```
AT -> ATE                       conflat(ed)  -> conflate
BL -> BLE                       troubl(ed)   -> trouble
IZ -> IZE                       siz(ed)      -> size
(*d)                            hopp(ing) -> hop    tann(ed) -> tan
   -> single letter, but the    fall(ing) -> fall   fizz(ed) -> fizz
   word is left alone when it
   ends with l, s or z
(m=1 and *o) -> E               fil(ing)  -> file
                                fail(ing) -> fail   (*o fails, no E added)
```

So a word ending in a doubled consonant selects the fourth rule: if that
doubled consonant is `l`, `s` or `z` the word is left as it is, and the fifth
rule is **not** tried (it could not fire anyway, since `*o` needs the last two
letters to be a consonant and a vowel). The fifth rule is reached only when
`*d` is false.

Here `*L`, `*S`, `*Z` mean "ends with `l`", "ends with `s`", "ends with `z`",
and `*d` and `*o` are evaluated on the word as it stands at that moment.

### Step 1c

```
(*v*)  Y -> I           happy -> happi      sky -> sky
```

### Step 2

At most one rule fires: the first whose **suffix** matches the word. If that
rule's condition then fails, step 2 does nothing (no later rule is tried).

```
(m>0) ATIONAL -> ATE      relational     -> relate
(m>0) TIONAL  -> TION     conditional    -> condition
(m>0) ENCI    -> ENCE     valenci        -> valence
(m>0) ANCI    -> ANCE     hesitanci      -> hesitance
(m>0) IZER    -> IZE      digitizer      -> digitize
(m>0) BLI     -> BLE      conformabli    -> conformable
(m>0) ALLI    -> AL       radicalli      -> radical
(m>0) ENTLI   -> ENT      differentli    -> different
(m>0) ELI     -> E        vileli         -> vile
(m>0) OUSLI   -> OUS      analogousli    -> analogous
(m>0) IZATION -> IZE      vietnamization -> vietnamize
(m>0) ATION   -> ATE      predication    -> predicate
(m>0) ATOR    -> ATE      operator       -> operate
(m>0) ALISM   -> AL       feudalism      -> feudal
(m>0) IVENESS -> IVE      decisiveness   -> decisive
(m>0) FULNESS -> FUL      hopefulness    -> hopeful
(m>0) OUSNESS -> OUS      callousness    -> callous
(m>0) ALITI   -> AL       formaliti      -> formal
(m>0) IVITI   -> IVE      sensitiviti    -> sensitive
(m>0) BILITI  -> BLE      sensibiliti    -> sensible
(m>0) LOGI    -> LOG      apologi        -> apolog
```

The `BLI -> BLE` and `LOGI -> LOG` rules are the two departures from the
published paper (which has `ABLI -> ABLE` and no `LOGI` rule). They are what
Porter's own implementation does, and they are what this problem requires.

### Step 3

The same rule applies: first matching suffix, then its condition.

```
(m>0) ICATE -> IC         triplicate  -> triplic
(m>0) ATIVE ->            formative   -> form
(m>0) ALIZE -> AL         formalize   -> formal
(m>0) ICITI -> IC         electriciti -> electric
(m>0) ICAL  -> IC         electrical  -> electric
(m>0) FUL   ->            hopeful     -> hope
(m>0) NESS  ->            goodness    -> good
```

### Step 4

```
(m>1) AL    ->            revival     -> reviv
(m>1) ANCE  ->            allowance   -> allow
(m>1) ENCE  ->            inference   -> infer
(m>1) ER    ->            airliner    -> airlin
(m>1) IC    ->            gyroscopic  -> gyroscop
(m>1) ABLE  ->            adjustable  -> adjust
(m>1) IBLE  ->            defensible  -> defens
(m>1) ANT   ->            irritant    -> irrit
(m>1) EMENT ->            replacement -> replac
(m>1) MENT  ->            adjustment  -> adjust
(m>1) ENT   ->            dependent   -> depend
(m>1 and (*S or *T)) ION -> adoption   -> adopt
(m>1) OU    ->            homologou   -> homolog
(m>1) ISM   ->            communism   -> commun
(m>1) ATE   ->            activate    -> activ
(m>1) ITI   ->            angulariti  -> angular
(m>1) OUS   ->            homologous  -> homolog
(m>1) IVE   ->            effective   -> effect
(m>1) IZE   ->            bowdlerize  -> bowdler
```

The suffixes are tried in the order shown, and only the first whose suffix
matches is considered; if its condition then fails, step 4 does nothing.
`(*S or *T)` means the stem left after removing `ION` ends with `s` or `t`.

### Step 5a

Both rules share the suffix `E`, and this is the one step where the second
rule is still tried after the first one's condition fails:

```
(m>1)              E ->      probate -> probat     rate -> rate
(m=1 and not *o)   E ->      cease   -> ceas
```

`rate` has m = 1 for the stem `rat` and `*o` holds there, so neither rule
fires and the `e` stays; `cease` has m = 1 for `ceas` and `*o` fails there, so
the second rule fires and gives `ceas`.

### Step 5b

This rule has no suffix, so its condition is evaluated on the whole word as
step 5a left it:

```
(m>1 and *d and *L) -> single letter     controll -> control
                                         roll     -> roll
```

### Worked stems

| Word | Stem | | Word | Stem |
|------|------|-|------|------|
| `running` | `run` | | `happiness` | `happi` |
| `runs` | `run` | | `happier` | `happier` |
| `runner` | `runner` | | `relational` | `relat` |
| `connection` | `connect` | | `relativity` | `rel` |
| `connections` | `connect` | | `sensibility` | `sensibl` |
| `connecting` | `connect` | | `national` | `nation` |
| `cats` | `cat` | | `controlled` | `control` |
| `dogs` | `dog` | | `abandoned` | `abandon` |

## The index

The index is built once, over all documents, before any query is evaluated.

- For every document, analyse its text into the sequence of its terms. The
  **length** of the document, written `|d|`, is the number of tokens it
  contains — every token, stop words included.
- The **postings** of a term are, for each document that contains it, the
  sorted list of the positions at which it occurs.
- `N` is the number of documents.
- `avgdl` is the mean document length, `(sum of |d|) / N`, as a
  floating-point value. If `N = 0`, `avgdl` is 0.

## queries.txt

`queries.txt` is a sequence of LF-terminated lines. A final LF may be present
or absent. Each line, after stripping leading and trailing whitespace
(U+0009, U+000A, U+000B, U+000C, U+000D, U+0020 and U+00A0), is one of:

- **empty** — ignored;
- a **comment**, its first character being `#` — ignored;
- a **`k` directive**, matching exactly `%k` followed by one or more spaces or
  tabs, then one or more ASCII digits, then optionally spaces or tabs — it
  sets the result limit `k` for every query *after* it, and produces no
  output of its own;
- otherwise, a **query**.

`k` starts at 10. Queries are numbered 1, 2, 3, … in file order; directives,
comments and blank lines are not numbered.

The **query text** of a query is the line with leading and trailing
whitespace stripped, exactly as it will be echoed in the output.

## The query language

### Lexing

Scan the query text left to right:

- Whitespace (the same seven code points as above) separates tokens and is
  otherwise discarded.
- `(` and `)` are punctuation tokens.
- `"` opens a **phrase**: the phrase body is everything up to the next `"`,
  or to the end of the line if there is none. Both quotes are consumed.
  The body may be empty.
- Otherwise a **word** runs to the next whitespace character, `(`, `)` or
  `"`. If the word is exactly `AND`, `OR` or `NOT` — upper case, nothing
  else — it is an operator. Any other word is a phrase whose body is the word
  itself. (Lower-case `and`, `or`, `not` are ordinary words, and all three
  happen to be stop words.)

### Atoms

A phrase body — whether it came from a quoted phrase or from a bare word — is
analysed exactly like document text, producing a sequence of terms. The
result is an **atom**:

- zero terms (`""`, or a word made only of separators): the atom is **empty**;
- exactly one term, whose *token text* is a stop word: the atom is **empty**;
- otherwise the atom is the tuple of its terms.

So a bare word and a one-word phrase behave identically, a word such as
`well-known` yields the two-term atom `(well, known)` — matching `well known`
adjacently, exactly like `"well known"` — and the stop-word rule applies to
one-term atoms whether or not they were quoted. Stop words inside a
multi-term atom are kept: `"to be or not to be"` is a six-term atom.

Two atoms are the **same atom** when their term tuples are equal.

### Grammar

```
query    := or
or       := and ( "OR" and )*
and      := ( "AND" | not )*
not      := "NOT"* primary
primary  := "(" or ")" | atom
```

`NOT` binds tightest, then `AND`, then `OR`. Juxtaposition means `AND`:
`cat dog` is `cat AND dog`.

The parse produces a tree whose leaves are atoms, or the **empty tree**. It
is built by this exact procedure, which never fails:

- **or**: parse an *and*; then, while the next token is `OR`, consume it and
  parse another *and*. Collect the results that are not empty. No result:
  the empty tree. One result: that result. Otherwise an `OR` node over them,
  in order.
- **and**: repeat — stop at end of input, at `)`, or at `OR`; on `AND`,
  consume it and continue; otherwise parse a *not*. Collect the results that
  are not empty, and combine them the same way (empty tree / the single
  result / an `AND` node).
- **not**: consume any run of `NOT` tokens, counting them; parse a *primary*.
  If the primary is empty, the result is empty (the `NOT`s are discarded);
  otherwise wrap it in that many `NOT` nodes.
- **primary**: on `(`, consume it, parse an *or*, then consume a following
  `)` if there is one, and return what the *or* returned. On `)`, return
  empty without consuming. On an atom token, consume it and return that atom,
  or empty if the atom is empty. On any other token, consume it and return
  empty.
- After the top-level *or*, any tokens still left (stray `)`s) are discarded.

Consequences, all of which occur in the tests:

- `()`, `the` and `NOT` parse to the empty tree.
- `cat AND`, `OR cat`, `cat ()`, `cat NOT ()`, `cat NOT (` and `(cat` all
  parse to just `cat`: an empty group is an operand, so the `NOT` in
  `cat NOT ()` applies to it and disappears with it rather than negating
  `cat`, and a `(` that is never closed simply ends at the end of the line.
- `"cat` is an unterminated phrase and parses to `cat`.
- A `)` that closes nothing ends the query: `cat ) dog` is `cat`, and so is
  `cat ) ) dog`, because the *and* loop stops there and the rest of the line
  is discarded.
- Adjacent binary operators are absorbed: `cat OR AND dog` and
  `cat AND OR dog` are both `cat OR dog` — the *and* loop consumes the run
  until it meets the `OR`, which then splits the query — while
  `cat AND AND dog` is `cat AND dog`.
- `dog NOT ( cat` is `dog AND NOT cat`: the unterminated group still yields
  the atom inside it.

### Positive atoms

Walk the tree depth-first, left to right. An atom is **positive** when the
number of `NOT` nodes above it is even. The **positive atom list** of a query
is the positive atoms in the order in which they are first met, with
duplicates (same term tuple) dropped. It may be empty — for example for
`NOT cat` — and for the empty tree it is empty.

## Boolean matching

An atom **occurs** in a document at position `p` when, for every `i`, the
`i`-th term of the atom is at position `p + i` in that document. Occurrences
may overlap: `"aa aa"` occurs three times in `aa aa aa aa`. The **frequency**
`f(a, d)` of atom `a` in document `d` is its number of occurrences there, and
`df(a)` is the number of documents in which it occurs at least once.

The set of documents a query matches is computed over the parse tree:

- an atom matches the documents in which it occurs;
- `NOT x` matches every document that `x` does not;
- `AND` is intersection, `OR` is union, in the order the children appear;
- the **empty tree matches no document at all** — not every document.

## Scoring

Every matched document is scored with BM25, using `k1 = 1.2` and `b = 0.75`:

```
score(d) = sum over the positive atom list, in order, of

               f * (k1 + 1)
    idf(a) * ------------------------------ ,   where f = f(a, d)
             f + k1 * (1 - b + b * |d| / avgdl)

                  N - df(a) + 0.5
    idf(a) = ln( ----------------- + 1 )
                    df(a) + 0.5
```

- The sum is taken over the positive atom list **in that order**, so every
  implementation performs the same additions in the same sequence.
- An atom that does not occur in `d` contributes exactly nothing (its term
  would be zero anyway; skip it).
- When `avgdl` is 0 — only possible when every document is empty — the ratio
  `|d| / avgdl` is taken to be 0.
- This `idf` is always positive, so scores are never negative. A document
  matched by a query whose positive atom list is empty scores exactly `0`.

## Ranking

Sort the matched documents by score, highest first; break ties by document
id, smallest first (Unicode code point order). Keep the first `k`.

Scores are compared as computed, not as printed.

## Snippets

Each emitted document gets one snippet. Let `W = 30`, let `L = |d|`, and let
the **occurrence set** be every occurrence, in that document, of every atom
in the positive atom list.

A **window** is identified by its start `s`, an integer with
`0 ≤ s ≤ max(0, L - W)`. It covers the token positions `s` through
`min(s + W, L) - 1` inclusive — `W` tokens, or the whole document when
`L ≤ W`. An occurrence of an atom of `n` terms at position `p` is **inside**
the window when `p ≥ s` and `p + n - 1 ≤ min(s + W, L) - 1`.

The **best window** is the one with

1. the greatest number of distinct positive atoms having at least one
   occurrence inside it; then
2. the greatest total number of occurrences inside it; then
3. the smallest `s`.

When `L ≤ W`, or when the occurrence set is empty, the best window is `s = 0`.
An atom of more than `W` terms never fits inside any window, so its
occurrences never count; if the occurrence set contains nothing else, every
window scores `(0, 0)` and rule 3 again gives `s = 0`.

The snippet is then produced from the original document text:

1. take the substring from the first code point of the token at position `s`
   to the last code point of the token at position `min(s + W, L) - 1`,
   inclusive — everything between those tokens, separators and all;
2. replace every maximal run of the seven whitespace code points (U+0009,
   U+000A, U+000B, U+000C, U+000D, U+0020, U+00A0) with a single space
   (U+0020).

The substring begins and ends inside a token, so a snippet never begins or
ends with whitespace, and it never contains a tab or a newline. A document of
zero tokens has the empty snippet.

## Output

Exactly two files are written into the output directory. Both are UTF-8 with
LF line endings and a final LF (a file with no lines is empty).

### results.txt

For each query, in order, a block of `2 + h` lines, where `h` is the number
of documents emitted:

```
QUERY <number> <query text>
HITS <h>
<rank>\t<document id>\t<score>\t<snippet>
...
```

- `<number>` is the query's 1-based number and `<query text>` is its text,
  reproduced exactly.
- `HITS` is followed by a single space and the decimal count.
- Each result line has exactly four fields separated by single TAB
  characters. `<rank>` counts from 1. `<score>` is the score printed with
  exactly four digits after the decimal point, rounded to nearest (a score of
  0 prints as `0.0000`). `<snippet>` may be empty, in which case the line
  ends with the third TAB.
- Blocks follow one another with no separator line.

### stats.txt

Exactly four lines, in this order:

```
documents <N>
tokens <total number of tokens over all documents>
terms <number of distinct terms in the index>
avgdl <avgdl, four decimal places>
```

The distinct-term count includes terms that come only from stop words.

## Worked example

`docs/note.txt` contains one line:

```
The quick brown fox jumps over the lazy dog.
```

`queries.txt`:

```
fox
quick brown
cat
"lazy dog"
```

The document tokenises into 9 tokens — `The quick brown fox jumps over the
lazy dog` — so `|note| = 9`, `N = 1`, `avgdl = 9`. Their terms are `the`,
`quick`, `brown`, `fox`, `jump`, `over`, `the`, `lazi`, `dog`: 8 distinct.

For the query `fox`: one atom, `(fox)`, `df = 1`, so

```
idf = ln((1 - 1 + 0.5) / (1 + 0.5) + 1) = ln(4/3) = 0.287682...
```

`f = 1` and `|d| / avgdl = 1`, so the second factor is
`1 * 2.2 / (1 + 1.2 * 1) = 1`, and the score is `0.2877`.

`quick brown` is two atoms, each scoring the same `0.287682`, so the
document scores `0.5754`. `cat` matches nothing. `"lazy dog"` is one
two-term atom that occurs once, scoring `0.2877` again.

The whole document is 9 tokens, fewer than `W = 30`, so every snippet is the
whole text from `The` to `dog`, with the trailing `.` excluded because it
comes after the last token of the window.

`results.txt`:

```
QUERY 1 fox
HITS 1
1	note	0.2877	The quick brown fox jumps over the lazy dog
QUERY 2 quick brown
HITS 1
1	note	0.5754	The quick brown fox jumps over the lazy dog
QUERY 3 cat
HITS 0
QUERY 4 "lazy dog"
HITS 1
1	note	0.2877	The quick brown fox jumps over the lazy dog
```

`stats.txt`:

```
documents 1
tokens 9
terms 8
avgdl 9.0000
```

A second example shows the tie-break and the phrase rules. With four
documents `copy1`, `copy2`, `copy3` (all `alpha beta gamma`) and `other`
(`alpha alpha beta`), the query `alpha` gives

```
QUERY 1 alpha
HITS 4
1	other	0.1449	alpha alpha beta
2	copy1	0.1054	alpha beta gamma
3	copy2	0.1054	alpha beta gamma
4	copy3	0.1054	alpha beta gamma
```

— `other` wins on term frequency, and the three identical documents are
ordered by id.

## Guarantees

Every test input satisfies all of the following.

1. The input directory exists and contains `queries.txt`. `docs/` may be
   absent, empty, or contain only `.txt` regular files.
2. All input files are valid UTF-8 and contain no CR and no NUL.
3. Document ids are ASCII, non-empty, and unique.
4. No query line is longer than 200 characters. No query contains a `#` as
   its first non-blank character (that would be a comment) and none matches
   the `%k` directive shape.
5. `k` is between 1 and 1000.
6. Scores in the expected outputs are separated well enough to be reproduced:
   for every query, two neighbouring entries of the ranking (and the entries
   on either side of the `k` cut) either have bit-identical scores or scores
   more than 1e-9 apart. Equal scores arise only from documents whose
   relevant statistics are identical, so the order after the id tie-break is
   the same everywhere.

The suite is checked with `verify.py`, which requires the ranking, the
document ids, the hit counts and the snippets to match exactly, and the
scores and `avgdl` to be within 1e-3 of the expected values.

## Input sizes

The largest test has 2944 documents built from fourteen novels: 10 006 287
bytes of text, 1 813 933 tokens, 20 308 distinct terms and 11 queries. The
next largest has 201 chapter-sized documents from twelve books, and another
has ten whole books as ten documents, the largest single document being
637 838 bytes and 117 077 tokens. Everything else is tiny. No test has more than 20 000
queries, and `k` never exceeds 25 in a test with a real corpus.

Snippets only ever need to be produced for the documents that are actually
emitted, which is at most `k` per query.
