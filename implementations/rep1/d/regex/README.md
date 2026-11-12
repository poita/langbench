# btregex

A small, dependency-free regular-expression engine written in D. It is a
backtracking matcher with Perl-style semantics (leftmost match, greedy
quantifiers, ordered alternation) for a fixed pattern subset, and it reports the
offsets of **every capture group**. It comes as a library plus a command-line
tool that matches many subjects against many patterns in one run.

## Supported syntax

Literals, `.`, `^`, `$`, classes (`[a-z_]`, `[^...]`, with `\d \w \s` and their
complements inside), escapes (`\d \D \w \W \s \S`, `\.` and any other escaped
punctuation), capturing groups `( )`, alternation `|`, and the greedy
quantifiers `* + ? {n} {n,} {n,m}`. Matching is case-sensitive over ASCII.
Back-references, lazy/possessive quantifiers, look-around and flags are not
supported.

Semantics are the continuation-passing definition in the problem specification:
alternatives are tried left to right, optional iterations greedily, an optional
iteration that matches the empty string ends the loop, and captures written on
an abandoned path are undone.

## Building

Requires LDC and dub.

```
./build.sh          # builds bin/btregex (dub build -b release --compiler=ldc2 -c cli)
dub build -b release --compiler=ldc2   # builds just the library
dub test --compiler=ldc2               # runs the unit tests
```

## Command-line use

`./run.sh` (or `bin/btregex`) reads the batch format on stdin:

```
N
pattern_1
M_1
subject_1_1
...
```

and prints one line per subject: `no`, or `match <start> <end>` followed by
`|<gs>,<ge>` (or `|-` when unset) for each group.

```
$ printf '2\n(a|(b))+\n2\nba\nab\n[^a-c]\\d{2,3}x?\n1\nzz123xx\n' | ./run.sh
match 0 2|1,2|0,1
match 0 2|1,2|1,2
match 1 6
```

Exit status is 0 on success and 1 on malformed input or an invalid pattern.

## Library use

```d
import btregex;

void main()
{
    auto re = new Regex(`(\w+)@(\w+)\.com`);   // throws RegexException if invalid
    auto m = re.search("mail bob@example.com now");
    if (m.matched)
    {
        // m.start == 5, m.end == 20
        // m.groups[0] == Group(5, 8), m.groups[1] == Group(9, 16)
    }
}
```

`Regex.search(subject, ref Match)` reuses the caller's `Match` to avoid
allocation in loops. A `Regex` holds scratch buffers, so do not share one
instance between threads.

## Design

| Module | Responsibility |
| --- | --- |
| `btregex.parser` | recursive-descent parser to a syntax tree; `RegexException` |
| `btregex.ast`, `btregex.charset` | tree nodes and 256-bit character sets |
| `btregex.analysis` | first-character set and start-anchor analysis |
| `btregex.program` | compiles the tree to a small backtracking VM program |
| `btregex.engine` | the VM: explicit backtrack stack and an undo trail |
| `btregex.batch` | the line-oriented batch format used by the CLI |

The matcher uses an explicit choice stack, so deep backtracking (e.g. `.*` over
10 000 characters) does not consume call stack. Capture and loop registers are
written through a trail, so undoing a failed path costs time proportional to the
writes it made. Counted repeats are expanded at compile time. Start positions
whose character cannot begin a match are skipped, and patterns that must start
with `^` are tried only at offset 0.

## Tests

Unit tests live next to the code (`unittest` blocks) and in
`source/btregex/tests.d`, which checks the matching semantics, including all
worked examples from the specification. Run them with
`dub test --compiler=ldc2`.

## License

MIT
