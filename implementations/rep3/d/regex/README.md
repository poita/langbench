# regex

A small backtracking regular-expression engine for D, plus a batch
command-line tool. It implements a defined Perl-style subset with leftmost,
greedy, ordered-choice semantics and reports the position of every capture
group. Only the D standard library (and druntime) is used; the engine itself is
written from scratch.

## Supported syntax

Literals, `.`, `^`, `$`, classes (`[a-z_]`, `[^...]`, ranges, `\d \w \s \D \W \S`
inside), escapes (`\d \w \s \D \W \S`, `\` + punctuation for a literal),
capturing groups `( )`, alternation `|`, and greedy quantifiers
`* + ? {n} {n,} {n,m}`. Matching is case-sensitive and byte-oriented (ASCII).
Semantics follow the definition in `problems/regex/SPEC.md`: the first start
position that matches wins, alternatives are tried left to right, and an
optional loop iteration that consumes nothing ends the loop.

## Design

```
pattern --parser--> syntax tree --compiler--> Program --vm (Matcher)--> match + captures
                         \--analysis--> anchored? first-character set?
```

* `regex.parser` is a recursive-descent parser; classes are resolved to
  bitmaps at parse time.
* `regex.analysis` computes whether a pattern is anchored with `^` and which
  characters a match can start with, so impossible start positions are skipped.
* `regex.compiler` emits a flat program for a backtracking VM
  (`char any class bol eol split jmp save mark check charLoop match`).
  Single-character repeats become one `charLoop` instruction; `mark`/`check`
  guards are only emitted for loop bodies that can match the empty string.
* `regex.vm` is one iterative interpreter loop with an explicit choice-point
  stack and an undo trail for captures. No recursion, so subject length does
  not affect native stack use; buffers are reused across searches.
* `regex.batch` implements the line-oriented protocol used by the CLI.

## Build

Requires LDC and dub.

```
./build.sh                       # dub build -b release --compiler=ldc2
dub test --compiler=ldc2         # unit tests (tests/regex/*.d)
```

The tool is produced as `bin/regex-cli`; `run.sh` runs it from any directory.

## Command-line tool

`regex-cli` reads a batch on stdin and writes results to stdout:

```
N                      number of patterns
pattern_1              taken verbatim (may be empty or contain spaces)
M_1                    number of subjects for this pattern
subject_1_1 ...        M_1 lines, taken verbatim
pattern_2 ...
```

For each subject, one output line: `no`, or `match <start> <end>` followed by
`|<gs>,<ge>` (or `|-` if unset) for each group in order, with exclusive end
offsets.

```
$ printf '1\n(a|(b))+\n2\nba\nab\n' | ./run.sh
match 0 2|1,2|0,1
match 0 2|1,2|1,2
```

Exit status is 0 on success, 2 for malformed input or an invalid pattern
(with a message on stderr).

## Library example

Add the package as a dependency (`dependency "regex" path="../regex"`), then:

```d
import regex;

void main()
{
    auto re = new Regex(`(\w+)@(\w+)`);
    enum subject = "mail bob@example now";

    auto m = re.search(subject);               // self-contained Match
    assert(m.matched && m.start == 5 && m.end == 16);
    assert(m.groupText(subject, 1) == "bob");  // groups are 1-based
    assert(m.groupStart(2) == 9 && m.groupEnd(2) == 16);

    // High-volume use: reuse one Matcher, nothing is allocated per search.
    auto matcher = new Matcher;
    foreach (line; ["a@b", "none", "x@y"])
        if (re.search(matcher, line))
            assert(matcher.captures.length == 4); // [g1s, g1e, g2s, g2e]
}
```

Invalid patterns throw `RegexException`.

## Layout

```
dub.sdl            manifest (configurations: cli, library, unittest)
source/regex/      the library
app/main.d         the command-line tool
tests/regex/       unit tests (kept separate from the library source)
build.sh run.sh    build and run wrappers
```
