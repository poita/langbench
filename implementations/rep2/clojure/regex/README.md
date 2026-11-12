# regex

A small backtracking regular-expression engine written in Clojure, with a
command-line tool for batch matching. It implements a defined Perl-style
subset: leftmost match, greedy quantifiers, ordered alternation, and exact
capture-group positions. The engine is written from scratch and uses neither
`java.util.regex` nor `re-*`.

Requires Clojure 1.12.6 on Java 27 and the `clojure` CLI. There are no runtime
dependencies beyond Clojure itself.

## Supported syntax

| Construct | Meaning |
|-----------|---------|
| `a`, `\.`, `\@` | literal (any char but `\ . [ ] ( ) \| * + ? { } ^ $`), or an escaped non-alphanumeric |
| `.` | any character |
| `^`, `$` | start / end of subject (zero-width, may appear anywhere, no quantifier) |
| `[abc]` `[^a-z]` | character class with ranges, negation, and the escapes below |
| `\d \w \s` `\D \W \S` | class escapes (usable inside classes) |
| `(...)` | capturing group, numbered by opening parenthesis |
| `a\|b` | alternation, tried left to right |
| `* + ? {n} {n,} {n,m}` | greedy quantifiers (`0 <= n <= m <= 100`) |

Matching follows the operational definition in `SPEC.md`; in particular an
optional iteration that matches the empty string ends the repetition, and a
group inside a repetition keeps the value from the last iteration that
completed it.

## Build

```
./build.sh          # AOT-compiles the CLI into ./classes
```

## Command-line tool

```
./run.sh < input > output
```

Input (stdin), strictly positional, `\n`-terminated lines:

```
N                    number of patterns
pattern_1            taken verbatim (may be empty or contain spaces)
M_1                  number of subjects for this pattern
subject_1_1 ...      M_1 lines, each taken verbatim
pattern_2 ...
```

Output: one line per subject, in order — `no`, or
`match <start> <end>` followed by `|<gs>,<ge>` (or `|-` when unset) for each
group. Example:

```
$ printf '1\n(a|(b))+\n2\nba\nab\n' | ./run.sh
match 0 2|1,2|0,1
match 0 2|1,2|1,2
```

## Library

```clojure
(require '[regex.core :as re])

(def r (re/compile "(a|ab)(c|bcd)(d*)"))

(re/find-match r "abcd")
;=> {:start 0, :end 4, :groups [[0 1] [1 4] [4 4]]}

(re/match-text r "abcd")
;=> {:text "abcd", :groups ["a" "bcd" ""]}

(re/matches? (re/compile "^\\d+$") "12345")   ;=> true
(re/find-match (re/compile "(a)|(b)") "b")
;=> {:start 0, :end 1, :groups [nil [0 1]]}
```

`re/compile` throws an `ex-info` (`:type :regex.parser/syntax-error`) on an
invalid pattern. A compiled regex is immutable and thread-safe. Unmatched
groups are `nil`. Class contents are matched against ASCII only; non-ASCII
characters match `.` and negated classes.

### Modules

| Namespace | Responsibility |
|-----------|----------------|
| `regex.core` | public API: `compile`, `find-match`, `matches?`, `match-text`, `group-count` |
| `regex.parser` | recursive-descent parser: pattern → syntax tree |
| `regex.charset` | 129-slot boolean tables for classes and escapes |
| `regex.analysis` | nullability, first-character sets, start anchoring |
| `regex.compiler` | syntax tree → backtracking program (counted quantifiers expanded) |
| `regex.vm` | the explicit-stack backtracking machine (`search`, `workspace`) |
| `regex.cli` | stdin/stdout batch tool |

The matcher never recurses: choice points live on an explicit int stack and
every register write (captures, loop markers) is recorded on a trail, so
abandoning a path costs exactly the writes it made. Search tries start
positions in order, skipping those whose character cannot begin a match, and
tries only position 0 for patterns that must start with `^`. Greedy runs of a
single-character atom (`.*`, `[a-z]+`, `a{2,5}`) use one range-shaped choice
point instead of one per character.

## Tests

```
clojure -M:test
```

Unit tests cover the parser, analysis, engine, and CLI (including every worked
example from `SPEC.md`). A `test.check` property test compares the engine with
a naive, purely functional transcription of the specification
(`test/regex/reference.clj`) on random patterns and subjects.
