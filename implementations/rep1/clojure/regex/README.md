# regex

A small backtracking regular-expression engine for Clojure, written from
scratch (no `java.util.regex`), with Perl-style leftmost, greedy,
ordered-choice semantics. It reports the first match in a subject together
with the position of every capture group. The repository contains

* a **library** (`regex.core`) with a small public API, and
* a **command-line tool** (`regex.cli`) that runs batches of patterns and
  subjects in the line-oriented format described in `problems/regex/SPEC.md`.

## Supported syntax

Literals, `.`, `^`, `$`, classes (`[a-z_]`, `[^...]`, ranges, `\d \w \s`
and their complements inside classes), escapes (`\d \D \w \W \s \S`, and `\`
plus any punctuation for a literal), capturing groups `( )`, alternation `|`,
and the greedy quantifiers `* + ? {n} {n,} {n,m}`. The matching rules —
including how empty iterations and captures inside repetitions behave — are
defined operationally in SPEC.md section 3.

## Building

Requires Java and the Clojure CLI (`clojure`), Clojure 1.12.

```sh
./build.sh      # AOT-compiles the CLI into classes/ and records the classpath
```

## Command-line use

```sh
./run.sh < input.txt > output.txt
```

Input is `N`, then for each pattern: the pattern line, a count `M`, and `M`
subject lines. Output is one line per subject: `no`, or
`match <start> <end>` followed by `|<gs>,<ge>` (or `|-` when unset) for each
group. Example:

```console
$ printf '2\n(a|(b))+\n2\nba\nab\n[^a-c]\\d{2,3}x?\n2\nzz123xx\nabc9\n' | ./run.sh
match 0 2|1,2|0,1
match 0 2|1,2|1,2
match 1 6
no
```

The matcher recurses, so the CLI runs it on a thread with a 1 GiB stack to
cope with long subjects (`.*` over 10 000 characters needs a few frames per
character).

## Library use

Add the project as a `deps.edn` dependency (or put `src` on the classpath):

```clojure
(require '[regex.core :as re])

(re/match (re/compile "(a|ab)(c|bcd)(d*)") "abcd")
;; => {:start 0, :end 4, :groups [[0 1] [1 4] [4 4]]}

(re/re-match "(a|(b))+" "ba")        ; compile and match in one call
;; => {:start 0, :end 2, :groups [[1 2] [0 1]]}

(re/re-match "x(y)?" "x")
;; => {:start 0, :end 1, :groups [nil]}   ; unset group => nil

(re/re-match "^b" "abc")              ; no match
;; => nil
```

Public API (`regex.core`):

| function | description |
|---|---|
| `(compile pattern)` | Parse and compile a pattern string to an immutable, thread-safe `Pattern`; throws `ex-info` for invalid syntax |
| `(match pattern subject)` | First match of a compiled pattern: `nil` or `{:start :end :groups}` |
| `(re-match pattern-string subject)` | `compile` + `match` |
| `(group-count pattern)` | number of capture groups |
| `(call-with-stack-size bytes f)` | run `f` on a thread with a large stack, for very long subjects |

## Design

| namespace | responsibility |
|---|---|
| `regex.charset` | ASCII character sets (`boolean-array`s), class escape sets |
| `regex.parser` | recursive-descent parser: pattern string → syntax tree |
| `regex.analysis` | first-character set and start-anchoring analysis, used to skip impossible start positions |
| `regex.compiler` | compiles the tree into continuation-linked `Step` objects implementing the backtracking semantics; capture writes are undone only for the writes made on failed paths |
| `regex.core` | public API and the start-position search loop |
| `regex.cli` | batch input/output |

Counted quantifiers are expanded into copies of the atom (the spec bounds the
total at 20 000 atoms); repetitions of single-character atoms are matched with
a loop instead of recursion. Match state lives in a per-call `long[]`, so
compiled patterns can be shared between threads.

## Tests

```sh
clojure -M:test
```

runs unit tests (parser, matcher, CLI) with the Cognitect test-runner, plus a
`test.check` property test that compares the compiled matcher against a naive
transcription of the specification on random patterns and subjects.
