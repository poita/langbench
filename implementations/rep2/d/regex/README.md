# regex

A small backtracking regular-expression engine written in D, with Perl-style
leftmost, greedy, ordered-choice semantics for a defined pattern subset, and a
command-line tool that matches batches of patterns against batches of subjects.
It uses only the D standard library (and druntime); the engine is implemented
from scratch.

## Supported syntax

Literals, `.`, `^`, `$`, classes (`[a-z_]`, `[^...]`, with `\d \w \s \D \W \S`
and escaped characters inside), escapes (`\d \w \s \D \W \S`, `\` + any
punctuation), capturing groups `( )`, alternation `|`, and the greedy
quantifiers `* + ? {n} {n,} {n,m}` (counts up to 100). Matching is defined
operationally: the first start position that matches wins, alternatives are
tried left to right, quantifiers are greedy, an empty optional iteration ends a
loop, and a group reports the last text it matched on the successful path.

## Design

| Module            | Responsibility                                              |
|-------------------|-------------------------------------------------------------|
| `regex.parser`    | recursive-descent parser, pattern → syntax tree             |
| `regex.ast`       | tree nodes, nullability / first-character / anchor analysis |
| `regex.charset`   | 256-bit character sets                                      |
| `regex.compiler`  | tree → flat program (counted repeats are expanded)          |
| `regex.vm`        | backtracking interpreter with an explicit stack; capture writes are trailed and undone on failure |
| `regex.regex`     | public `Regex` class and `Match` / `Capture` results        |
| `regex.batch`     | batch input parsing and output formatting                   |
| `source/app.d`    | the CLI                                                     |

Because the interpreter uses an explicit backtrack stack, deep matches such as
`.*` over a 10,000-character subject do not depend on the native stack size.
Start positions are tried in order; positions whose character cannot begin a
match are skipped, and patterns anchored with `^` are tried only at offset 0.

## Build

Requires LDC and dub.

```
./build.sh            # dub build -b release --compiler=ldc2  → ./regex
dub test --compiler=ldc2
```

## CLI

`regex` (or `./run.sh`) reads the whole batch from stdin and writes one line
per subject to stdout:

```
N
pattern_1
M_1
subject_1_1
...
```

Each pattern line is followed by the count `M` of subject lines. The format is
strictly positional: empty lines, spaces and numeric-looking lines are data.
Output is `no`, or `match <start> <end>` followed by `|<gs>,<ge>` (or `|-` if
unset) for each group. Example:

```
$ printf '1\n(a|(b))+\n2\nba\nab\n' | ./run.sh
match 0 2|1,2|0,1
match 0 2|1,2|1,2
```

Malformed input or an invalid pattern prints a message to stderr and exits 1.

## Library

Add the package as a dependency (use `subConfiguration "regex" "library"`),
then:

```d
import regex;

void main()
{
    auto re = new Regex("(a|ab)(c|bcd)(d*)");
    auto m = re.match("abcd");
    if (m)
    {
        assert(m.start == 0 && m.end == 4);
        auto g2 = m.group(2);            // 1-based group access
        assert(g2.set && g2.start == 1 && g2.end == 4);
    }
}
```

`Regex.matchInto(subject, ref Match)` reuses the result's storage for
allocation-free matching in loops; `processInput` runs the whole batch format
from a string into a sink. Invalid patterns throw `RegexException`.
A `Regex` holds scratch buffers and is not thread-safe.

## Tests

Tests are `unittest` blocks, run by `dub test`. They include the worked
examples from the specification, per-module checks, and a differential test
that compares the VM with a direct recursive transcription of the matching
definition on thousands of random patterns (`source/regex/reference_test.d`).
