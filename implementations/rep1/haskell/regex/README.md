# regex-backtrack

A small, from-scratch **backtracking regular-expression engine** for Haskell,
with Perl-style semantics: leftmost match, greedy quantifiers, ordered
alternation, and the position of *every* capture group in the result. It
depends only on GHC's bundled packages (`base`, `array`, `bytestring`).

The package has three parts:

| Part | What it is |
| --- | --- |
| library `regex-backtrack` | `Regex` (public API) plus `Regex.Syntax`, `Regex.CharSet`, `Regex.Parser`, `Regex.Analysis`, `Regex.Matcher`, `Regex.Batch` |
| executable `regex-backtrack` | thin CLI that runs a batch of patterns and subjects from stdin |
| test suite `regex-backtrack-test` | hspec unit tests plus QuickCheck properties checked against a naive oracle |

## Supported syntax

```
regex      := branch ( '|' branch )*
branch     := piece*                       (may be empty)
piece      := atom quantifier?
atom       := literal | '.' | '^' | '$' | class | escape | '(' regex ')'
quantifier := '*' | '+' | '?' | '{n}' | '{n,}' | '{n,m}'      (always greedy)
```

* `.` any character; `^` / `$` match only at the start / end of the subject.
* Escapes `\d \w \s \D \W \S`; a backslash before any other non-alphanumeric
  character is that character literally.
* Classes `[abc]`, `[^a-z]`, `[\d_-]` with ranges and set escapes.
* Groups `( ... )` are always capturing, numbered by opening parenthesis.
* Matching follows a continuation-passing definition: alternatives are tried
  left to right, an optional iteration that consumes nothing ends a loop, a
  group keeps the value of its last completed iteration, and groups not on the
  successful path are unset. The search tries start positions `0..len` in
  order and reports the first match only.

Subjects are `ByteString`s; characters are matched as bytes. Patterns are
`String`s with characters in U+0000..U+00FF.

## Building

Requires GHC 9.14 and cabal 3.18.

```sh
./build.sh            # cabal build, then copies the CLI to bin/regex-backtrack
cabal test            # run the test suite
```

## Command-line use

`./run.sh` (or `bin/regex-backtrack`) reads on stdin:

```
N
pattern_1
M_1
subject_1_1
...
```

Lines are taken verbatim (empty lines and leading/trailing spaces are
significant). For every subject it prints one line:

* `no` if the pattern matches nowhere, otherwise
* `match <start> <end>` followed by `|<gs>,<ge>` for each group in order, or
  `|-` for a group that is unset. Offsets are 0-based, ends exclusive.

```console
$ printf '2\n(a|(b))+\n2\nba\nab\n[^a-c]\\d{2,3}x?\n2\nzz123xx\nabc9\n' | ./run.sh
match 0 2|1,2|0,1
match 0 2|1,2|1,2
match 1 6
no
```

Malformed input or an invalid pattern prints a message on stderr and exits
with status 1 (results already computed are still written).

## Library example

```haskell
{-# LANGUAGE OverloadedStrings #-}
import qualified Data.ByteString.Char8 as BC
import Regex

main :: IO ()
main = do
  case compile "(a|(b))+" of
    Left (ParseError off msg) -> putStrLn ("bad pattern at " ++ show off ++ ": " ++ msg)
    Right re -> do
      print (groupCount re)              -- 2
      print (search re (BC.pack "ba"))
      -- Just (Match {matchStart = 0, matchEnd = 2, matchGroups = [Just (1,2),Just (0,1)]})
      print (matches re (BC.pack "xyz")) -- False
```

`compile :: String -> Either ParseError Regex` parses once; `search :: Regex ->
ByteString -> Maybe Match` can then be applied to any number of subjects, and
a compiled `Regex` can be shared between threads.

## Design notes

* The parser builds a syntax tree (`Regex.Syntax`); classes become 256-entry
  character tables at parse time.
* `Regex.Matcher` compiles the tree to closures in continuation-passing style,
  following the definition literally. Capture writes are restored, one group at
  a time, when a continuation fails, so abandoned paths cost only what they
  wrote. One-character atoms under a quantifier use an equivalent
  count-and-give-back loop, so `.*` over a long subject does not consume
  stack.
* `Regex.Analysis` computes the set of characters that can begin a match and
  whether the pattern is anchored with `^`; searches skip start positions that
  cannot begin a match, and an anchored pattern is tried at position 0 only.
  There is no DFA/NFA simulation, memoisation or literal prefiltering, so
  pathological patterns remain exponential, as with any backtracking engine.
