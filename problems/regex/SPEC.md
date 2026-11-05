# Regex engine (defined subset)

Implement a backtracking regular-expression matcher for the subset defined
below, with Perl-style leftmost, greedy, ordered-choice semantics, and report
the first match together with the positions of every capture group.

Write the regular-expression engine yourself: don't use a regex engine from a
library, the standard library or the language.

Everything is defined operationally in section 3. Two implementations that
follow that definition produce byte-identical output; there is no freedom in
which match or which capture values are reported.

## 1. Input format (stdin)

```
N
pattern_1
M_1
subject_1_1
...
subject_1_M1
pattern_2
M_2
...
```

- Line 1: integer `N` (1 ≤ N ≤ 15000), the number of patterns.
- For each pattern: one line holding the pattern (taken verbatim, including
  any leading/trailing spaces; it may be empty), then a line with integer
  `M` (0 ≤ M ≤ 100000), then `M` subject lines, each taken verbatim (may be
  empty, may contain spaces anywhere). `M` may be 0, in which case the next
  line is already the next pattern.
- The format is strictly positional. Never skip, trim or merge lines: a
  pattern or subject line may be empty, may consist only of spaces, may have
  leading or trailing spaces (which are part of it), and may itself look like
  an integer.
- `N` and `M` are written in plain decimal (no sign, no leading zeros, no
  surrounding whitespace).
- Lines are terminated by `\n` only (no `\r`), including the last line of the
  input. Patterns and subjects consist solely of printable ASCII characters
  0x20–0x7E; they never contain tabs or other control characters. Every
  pattern is syntactically valid per section 2.
- Sizes: pattern length ≤ 300; subject length ≤ 10000; the sum of M over
  all patterns ≤ 3000000; total input size ≤ 200 MB.

## 2. Pattern syntax

```
regex      := branch ( '|' branch )*
branch     := piece*                       (may be empty)
piece      := atom quantifier?
atom       := literal | '.' | '^' | '$' | class | escape | '(' regex ')'
quantifier := '*' | '+' | '?' | '{' n '}' | '{' n ',' '}' | '{' n ',' m '}'
```

- **literal**: any character except the metacharacters `\ . [ ] ( ) | * + ? { } ^ $`
  (space and all other printable characters are ordinary literals; matching
  is case-sensitive).
- **`.`** matches any single character (subjects never contain newlines).
- **`^`** matches only at position 0 of the subject; **`$`** matches only at
  position len(subject). They consume nothing, may appear anywhere in a
  pattern (e.g. `a^b` can never match), and never carry a quantifier.
- **escape** (outside a class): `\d` = `[0-9]`, `\w` = `[A-Za-z0-9_]`,
  `\s` = space, tab, `\n`, `\r`, `\f`, `\v` (only space can actually occur);
  `\D`, `\W`, `\S` are their complements (over ASCII); `\` followed by any
  non-alphanumeric printable character matches that character literally
  (`\. \\ \( \) \[ \] \{ \} \| \* \+ \? \^ \$ \-` and also `\ ` (space), `\@`,
  etc.). No other escapes appear (no `\b`, `\n`, `\t`, `\1`, ...).
- **class**: `[` optional `^` item+ `]`. An item is a single character, a
  range `x-y`, or one of the set escapes `\d \D \w \W \s \S`. A single
  character is any character except `\` and `]`, or `\` followed by a
  non-alphanumeric character (meaning that character). Ranges `x-y` are
  between two single characters with `x ≤ y` in ASCII order. A `-` is
  literal when it is the first item (right after `[` or `[^`), the last
  character before `]`, or escaped as `\-`; any other `-` is the range
  operator between two single characters. A `-` directly following a set
  escape or directly following a range (as in `[a-c-e]`) never occurs.
  `^` not in first position is a literal. `[` inside a
  class always appears escaped. `]` inside a class always appears escaped.
  A class is never empty. `[^...]` matches any character not in the set.
  The class contents are matched against ASCII code points only.
- **group** `( regex )` is always capturing; groups are numbered 1, 2, 3, ...
  by the position of their `(` from left to right (at most 50 per pattern). Groups may be empty `()`
  and branches may be empty (`a|`, `(|b)`, `||`).
- **quantifiers** apply to the immediately preceding atom (a literal, `.`,
  class, escape, or parenthesised group) and are always greedy. `{n}` means
  exactly n, `{n,}` at least n, `{n,m}` between n and m inclusive, with
  0 ≤ n ≤ m ≤ 100 (`{0}` and `{0,0}` are legal and match the empty string
  without ever running the atom). A quantifier never follows another
  quantifier, an anchor, `(`, `|`, or the start of a regex/group. `n` and
  `m` are plain decimal integers with no leading zeros (other than `0`
  itself), and there is no whitespace inside the braces.
  `{` and `}` only ever appear as part of a valid quantifier (or escaped);
  `]` only ever appears as the end of a class (or escaped).
- `|` has the lowest precedence, then concatenation, then quantifiers.
- Expanding every counted quantifier into copies of its atom never yields
  more than 20000 atoms in total (so expansion-based implementations are fine).

## 3. Matching semantics (normative)

Let `s` be the subject and `len` its length. Positions are 0-based offsets
between characters, 0..len. A capture table `caps[g]` holds either *unset* or
a pair `(gs, ge)` for each group `g`.

The matcher is defined by a function `m(node, i, k)` that tries to match
`node` starting at position `i` and, for each way it can end at position `j`
(tried in the order given below), calls the continuation `k(j)`. It returns
true as soon as some continuation returns true, and false when all
possibilities are exhausted. Any change made to `caps` along a path that
ultimately returns false is undone before the next alternative is tried.

```
m(literal c, i, k)   = i < len and s[i] == c and k(i+1)
m('.', i, k)         = i < len and k(i+1)
m(class C, i, k)     = i < len and s[i] in C and k(i+1)
m('^', i, k)         = i == 0 and k(i)
m('$', i, k)         = i == len and k(i)
m(seq x1 x2 ... xn, i, k)
                     = m(x1, i, j => m(seq x2 ... xn, j, k));  m(seq ⟨empty⟩, i, k) = k(i)
m(alt b1 | b2 | ... | bn, i, k)
                     = m(b1, i, k) or m(b2, i, k) or ... or m(bn, i, k)   (left to right, short-circuit)
m(group g: x, i, k)  = m(x, i, j => { old = caps[g]; caps[g] = (i, j);
                                      if k(j) return true; caps[g] = old; return false })
m(x{min,max}, i, k)  = rep(x, min, max, i, 0, k)        (`*` = {0,∞}, `+` = {1,∞}, `?` = {0,1})

rep(x, min, max, i, count, k):
    if count < min:  return m(x, i, j => rep(x, min, max, j, count+1, k))
    if count == max: return k(i)
    if m(x, i, j => (j == i) ? k(j) : rep(x, min, max, j, count+1, k)): return true
    return k(i)
```

Consequences of this definition, spelled out:

- **Ordered choice**: the first alternative that leads to an overall match
  wins, even if a later alternative would match more text. `a|ab` on `ab`
  matches `a` (0..1).
- **Greedy quantifiers**: once the minimum is satisfied, an extra iteration
  is always tried before stopping, and iterations are given back one at a
  time on backtracking.
- **Empty iterations**: an optional (beyond-the-minimum) iteration that
  consumes no characters ends the repetition: the continuation is invoked
  once with the captures set by that empty iteration, and no further
  iteration is attempted. If that continuation fails, the matcher backtracks
  into the empty iteration's other alternatives and finally tries stopping
  before that iteration. Iterations required by the minimum are always run,
  even when they match empty (`(a*){3}` on `""` matches with group 1 = 0,0).
- **Captures**: a group's value is the text it matched the *last* time it
  was completed on the successful path. A group inside a repetition keeps
  the value from an earlier iteration if a later iteration does not pass
  through it (`(a|(b))+` on `ba` gives g1 = 1,2 and g2 = 0,1). A group that
  is never completed on the successful path (e.g. in an alternative that
  was not taken, or inside `x{0}`) is unset. Values set on abandoned paths
  are always discarded.
- **Search**: the overall match is found by trying start positions
  0, 1, ..., len in order. For each start, reset all captures to unset and
  evaluate `m(regex, start, j => success(start, j))`. The first start that
  succeeds gives the reported match `(start, j)` and its capture table. A
  match may be empty (start == j). If no start succeeds, the answer is `no`.
  Only the first match is reported (no global matching).

## 4. Output format (stdout)

One line per subject, in input order, nothing else:

- `no` when the pattern does not match anywhere in the subject.
- Otherwise `match <start> <end>` followed, for every group `g = 1..G` in
  order (G = number of `(` in the pattern), by `|<gs>,<ge>` if the group is
  set or `|-` if it is unset. Fields are separated by a single `|` with no
  spaces. `<end>` and `<ge>` are exclusive end offsets. Example:
  `match 2 7|2,4|-|7,7`.
- A pattern with no groups produces just `match <start> <end>`.
- All numbers are plain decimal with no sign, leading zeros or padding.
  Every line ends with `\n`. A pattern with `M = 0` produces no lines at all
  (so the whole output may be empty).
- Exit code 0.

Group positions (rather than group text) are reported so that which
occurrence was captured is verified, not just its content.

## 5. Worked examples

### Example 1

Input:
```
3
(a|ab)(c|bcd)(d*)
1
abcd
a*
2
bbb

^(a+)+$
2
aaaa
aaab
```
Output:
```
match 0 4|0,1|1,4|4,4
match 0 0
match 0 0
match 0 4|0,4
no
```
`(a|ab)(c|bcd)(d*)` takes `a` first; then `c` fails at `b`, `bcd` succeeds,
leaving `d*` empty. `a*` on `bbb` matches empty at 0 (leftmost wins over
longer matches elsewhere). On the empty subject the match is `0 0`.

### Example 2

Input:
```
2
(a|(b))+
2
ba
ab
[^a-c]\d{2,3}x?
2
zz123xx
abc9
```
Output:
```
match 0 2|1,2|0,1
match 0 2|1,2|1,2
match 1 6
no
```
In `ba`, iteration 1 sets g2 = 0,1 and g1 = 0,1; iteration 2 matches `a`
and sets g1 = 1,2 without passing through g2, which keeps 0,1. For the
class pattern, start 0 fails (`z` is followed by `z`, not a digit); start 1
matches `z123x`, with `\d{2,3}` greedily taking three digits and `x?` one `x`.

### Example 3

Input:
```
3
(a*)*b
2
aab
ccc
x$|^(y)?z
3
xz
yz
zzz
(a){0}b|(c)?(d)
3
xb
xcd
d
```
Output:
```
match 0 3|2,2
no
no
match 0 2|0,1
match 0 1|-
match 1 2|-|-|-
match 1 3|-|1,2|2,3
match 0 1|-|-|0,1
```
`(a*)*b` on `aab`: the first iteration takes `aa`, the second matches empty
at position 2 and ends the loop, so g1 = 2,2. `x$|^(y)?z` on `xz`: at start 0
`x$` fails (not at end) and `^(y)?z` fails (`x` is not `z`); at start 1 `^`
fails, so `no`. `(a){0}b` never runs group 1, so it stays unset; on `xb`
the first alternative matches `b` at 1..2 and groups 2 and 3 are unset.

## 6. Performance expectations

- Largest tests: about 2.8 MB of input in one file, subjects up to 10000
  characters, up to 90000 subjects in one file, patterns up to 250
  characters with up to 30 groups, counted quantifiers up to `{100}`.
- Some tests are deliberately pathological for backtracking (nested
  quantifiers such as `(a*)*b`, `(x+x+)+y`, `(a|aa)+c` on short non-matching
  subjects, and quadratic scans such as `a*b` on about a thousand `a`s).
  They are bounded: no single test file requires more than about 8 million
  backtracking steps in total for a straightforward implementation of
  section 3, and the reference Python implementation finishes every test
  in under 15 s (the whole suite in about 35 s). A compiled implementation
  should finish every test in well under a second or two.
- A recursive implementation of section 3 can need recursion depth on the
  order of a few frames per subject character (e.g. `.*` over a 10000
  character subject); make sure the stack allows that, or use an explicit
  backtracking stack.
- Suggested timeout: 30 s per test for compiled languages.
