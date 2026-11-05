# regex

A small backtracking regular-expression engine written in D, plus a batch
command-line tool built on it. It implements a defined Perl-style subset
(leftmost match, greedy quantifiers, ordered alternation) and reports the
first match of a pattern in a subject together with the position of every
capture group. The engine is written from scratch; it uses nothing from
`std.regex`.

## Supported syntax

| Construct | Meaning |
|---|---|
| `a`, `\.`, `\ ` | literal (any non-metacharacter, or `\` + non-alphanumeric) |
| `.` | any character |
| `^`, `$` | start / end of the subject (zero-width, may appear anywhere) |
| `[abc]`, `[^a-z]`, `[\d_-]` | character class, negated class, ranges, set escapes |
| `\d \D \w \W \s \S` | digit, word, whitespace sets and complements |
| `(...)` | capturing group (numbered by opening parenthesis) |
| `a\|b` | ordered choice |
| `* + ? {n} {n,} {n,m}` | greedy quantifiers (`n ≤ m ≤ 100`) |

Matching semantics are those of a classic backtracking matcher: the first
alternative that leads to an overall match wins, quantifiers take as much as
possible and give back one iteration at a time, an optional iteration that
matches the empty string ends its loop, and a group reports the text it
matched the last time it completed on the successful path.

## Design

Each pattern is parsed once into a syntax tree (`regex.parser`), analysed for
anchoring and first-character set (`regex.analysis`) and compiled to a flat
program (`regex.compiler`, `regex.program`). The program runs on an iterative
backtracking VM (`regex.vm`) with an explicit choice-point stack and an undo
trail for captures, so there is no recursion proportional to the subject
length. Loops over a single character (`.*`, `\w+`, `[^,]{2,5}`) compile to
one `charLoop` instruction that pushes a single choice point. All buffers are
allocated once and reused across subjects and patterns.

| Module | Responsibility |
|---|---|
| `regex.pattern` | public `Regex`, `Match`, `Span` API |
| `regex.parser`, `regex.ast`, `regex.charset` | pattern → syntax tree |
| `regex.analysis` | nullability, `^`-anchoring, first-character sets |
| `regex.compiler`, `regex.program` | syntax tree → VM program |
| `regex.vm` | `Matcher`: the backtracking interpreter |
| `regex.batch` | the batch input/output protocol used by the CLI |
| `regex.exception` | `RegexException` |

## Building

Requires LDC and dub (tested with LDC 1.41.0, dub 1.40.0).

```sh
./build.sh            # = dub build -b release --compiler=ldc2
dub test --compiler=ldc2   # unit tests (tests/)
```

The executable is written to `./regex`.

## Command-line usage

The tool takes no arguments. It reads everything from standard input and
writes the results to standard output (`./run.sh` runs it from any directory).

Input:

```
N
pattern_1
M_1
subject_1_1
...
subject_1_M1
pattern_2
...
```

`N` is the number of patterns; each pattern is followed by the number of
subjects `M` and then exactly `M` subject lines. Lines are taken verbatim
(empty lines and leading/trailing spaces are significant) and terminated by
`\n`.

Output: one line per subject, `no` if there is no match, otherwise
`match <start> <end>` followed by `|<start>,<end>` (or `|-` if unset) for each
group in order. Offsets are 0-based with an exclusive end.

```
$ printf '1\n(a|(b))+\n2\nba\nab\n' | ./run.sh
match 0 2|1,2|0,1
match 0 2|1,2|1,2
```

An invalid pattern makes the tool print a message to stderr and exit with
status 1.

## Using the library

Add the package as a dependency (use the `library` configuration so the
command-line `main` is not included):

```sdl
dependency "regex" path="../regex"
subConfiguration "regex" "library"
```

```d
import regex;

void main()
{
    auto re = new Regex(`(\w+)@(\w+)\.com`);
    auto m = re.search("mail bob@example.com now");

    assert(m.matched);
    assert(m.begin == 5 && m.end == 20);
    assert(m.group(1) == Span(5, 8));    // "bob"
    assert(m.group(2) == Span(9, 16));   // "example"
    assert(re.groupCount == 2);
}
```

To match many subjects without per-call allocations, share a `Matcher`:

```d
Matcher scratch;
foreach (line; lines)
    if (re.search(line, scratch).matched) { /* ... */ }
```

Invalid patterns throw `RegexException`.

## Layout

```
dub.sdl            package manifest (configurations: cli, library, unittest)
source/regex/      the library
app/main.d         the command-line tool
tests/             unit tests (run by `dub test`)
build.sh, run.sh   build and run scripts
```
