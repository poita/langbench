# regex-backtrack

A small, from-scratch **backtracking regular-expression engine** in Haskell,
using only GHC's bundled packages (`base`, `bytestring`, `array`). It
implements a Perl-flavoured subset with leftmost, greedy, ordered-choice
semantics and reports the first match of a pattern in a subject together with
the span of **every capture group**.

It consists of

* a library (`Text.Regex.Backtrack` and friends), and
* a thin command-line tool, `regex-backtrack`, that evaluates batches of
  patterns against batches of subjects.

## Pattern syntax

```
regex      := branch ( '|' branch )*
branch     := piece*                       (may be empty)
piece      := atom quantifier?
atom       := literal | '.' | '^' | '$' | class | escape | '(' regex ')'
quantifier := '*' | '+' | '?' | '{n}' | '{n,}' | '{n,m}'     (always greedy)
```

* Literals: any character except `\ . [ ] ( ) | * + ? { } ^ $`; case-sensitive.
* `.` any one character; `^` / `$` match only at the very start / end of the
  subject and cannot be quantified.
* Escapes: `\d \w \s` and complements `\D \W \S`; `\` plus any
  non-alphanumeric character is that character literally.
* Classes: `[abc]`, `[^a-z0-9_]`, `[\d\-x]`; `-` is literal first, last or
  escaped.
* Groups `( … )` are always capturing and numbered by their `(`. Groups and
  branches may be empty.
* Counted quantifiers take `0 ≤ n ≤ m ≤ 100`.

Matching follows the continuation-passing definition: alternatives are tried
left to right, quantifiers take as much as possible and give back one
iteration at a time, an optional iteration that matches the empty string ends
its loop, and a group reports the text of the last time it completed on the
successful path (failed paths' captures are discarded). Start positions
`0..len` are tried in order. Subjects are treated as bytes.

## Building

Requires GHC 9.14 and cabal 3.18 (no packages beyond those bundled with GHC;
the test suite also needs `hspec` and `QuickCheck`).

```sh
./build.sh            # = cabal build exe:regex-backtrack
cabal test            # run the test suite
```

## Command-line use

`./run.sh` (or the `regex-backtrack` executable) reads a batch on stdin and
writes one line per subject on stdout:

```
N                      number of patterns
pattern_1              taken verbatim (may be empty or contain spaces)
M_1                    number of subjects for this pattern
subject_1_1            M_1 lines, taken verbatim
...
```

For each subject the output is `no`, or `match START END` followed by
`|gs,ge` (or `|-` when unset) for each group in order. Offsets are 0-based and
end-exclusive.

```console
$ printf '2\n(a|(b))+\n2\nba\nab\n[^a-c]\\d{2,3}x?\n2\nzz123xx\nabc9\n' | ./run.sh
match 0 2|1,2|0,1
match 0 2|1,2|1,2
match 1 6
no
```

Malformed input or an invalid pattern prints a message on stderr and exits
with status 1.

## Library use

```haskell
import qualified Data.ByteString.Char8 as BC
import Text.Regex.Backtrack

main :: IO ()
main = do
  case compile "(\\w+)@(\\w+)\\.com" of
    Left err -> print err                       -- ParseError offset message
    Right re -> do
      let subject = "mail bob@example.com now"
      case match re subject of
        Nothing -> putStrLn "no match"
        Just m  -> do
          print (matchStart m, matchEnd m)      -- (5,20)
          print (matchGroups m)                 -- [Just (5,8),Just (9,16)]
          print (groupText (BC.pack subject) m 2)  -- Just "example"
```

### Modules

| Module | Role |
| --- | --- |
| `Text.Regex.Backtrack` | Public facade: `compile`, `match`, `matchBytes`, `groupCount`, … |
| `Text.Regex.Backtrack.Syntax` | The pattern AST (`Node`, `Pattern`) |
| `Text.Regex.Backtrack.Parser` | Recursive-descent parser with offset-carrying errors |
| `Text.Regex.Backtrack.CharSet` | 256-entry table character sets |
| `Text.Regex.Backtrack.Analysis` | First-character set and start-anchor analysis |
| `Text.Regex.Backtrack.Matcher` | Closure compiler and backtracking search |
| `Text.Regex.Backtrack.Batch` | The batch input/output format used by the CLI |

## Implementation notes

* Each pattern is parsed once and compiled to a tree of closures in
  continuation-passing style; matching then follows the specification's
  `m(node, i, k)` directly.
* Captures live in one mutable unboxed array. A group saves its old values
  and restores them only if its continuation fails, so undoing costs
  proportional to the writes. A failed start position leaves the table
  untouched, so no per-start reset is needed.
* A repetition of a single-character atom (`a*`, `[0-9]{2,5}`, `.+`) is run
  as a tight scan followed by giving characters back one at a time — the same
  order of attempts, without per-character recursion.
* Start positions are skipped when the character there cannot begin a match
  (computed once per pattern), and a pattern that must begin with `^` is only
  tried at position 0. There is no memoisation and no reordering.

## Tests

`cabal test` runs an hspec suite: unit tests for the semantics, parser,
character sets and batch format (including the worked examples of the
specification), and QuickCheck properties that compare the engine against a
naive purely functional transcription of the specification
(`test/Reference.hs`) on thousands of random patterns and subjects.
