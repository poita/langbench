# btregex

A small, dependency-free **backtracking regular-expression engine** in pure
Python with Perl-style semantics: the leftmost match wins, quantifiers are
greedy, alternation is ordered, and the position of every capture group is
reported. It implements a deliberately small syntax and does not use `re` or
any other regex engine.

## Layout

| Module | Responsibility |
| --- | --- |
| `btregex.parser` | recursive-descent parser: pattern text → syntax tree |
| `btregex.nodes` | syntax-tree node types |
| `btregex.analysis` | first-character sets and start-anchor detection |
| `btregex.compiler` | tree → graph of closures (backtracking matcher) |
| `btregex.pattern` | public `compile`, `Pattern`, `Match` |
| `btregex.protocol` | batch input/output format |
| `btregex.cli` | command-line tool |

## Supported syntax

Literals, `.`, `^`, `$`, classes (`[a-z]`, `[^...]`, `\d \w \s \D \W \S`
inside or outside classes), escaped punctuation (`\.`, `\-`, ...), capturing
groups `( )`, alternation `|`, and greedy quantifiers `* + ? {n} {n,} {n,m}`
(up to 100). Groups are numbered by their opening parenthesis. An optional
iteration that matches the empty string ends its loop; required iterations
always run.

## Build

No install step is needed:

```sh
./build.sh      # byte-compiles the package
```

`pyproject.toml` describes the package (setuptools, `src/` layout) for
`pip install .` if you want it, but `run.sh` simply runs it from source with
`PYTHONPATH`.

## Command line

```sh
./run.sh < input.txt
```

Input on stdin: `N`, then for each pattern a line with the pattern, a line
with the subject count `M`, and `M` subject lines (all taken verbatim). Output
is one line per subject: `no`, or `match <start> <end>` followed by
`|<gs>,<ge>` (or `|-` if unset) for each group.

```
$ printf '1\n(a|(b))+\n2\nba\nab\n' | ./run.sh
match 0 2|1,2|0,1
match 0 2|1,2|1,2
```

## Library

```python
import btregex

rx = btregex.compile(r"(a|ab)(c|bcd)(d*)")
m = rx.search("abcd")
m.start, m.end      # (0, 4)
m.spans             # ((0, 1), (1, 4), (4, 4))
m.span(2)           # (1, 4); span(0) is the whole match; None if a group is unset
rx.search("xyz")    # None
```

Invalid patterns raise `btregex.PatternSyntaxError`. A `Pattern` holds
mutable match state and is not thread-safe.

## Design notes

Each pattern is parsed once into a tree and compiled into closures that each
know their static continuation, so matching is plain depth-first backtracking
with no allocation per step. Capture writes are undone by the code that made
them (cost proportional to the writes). Single-character loops (`a*`, `\d+`,
`.{2,5}`) scan and give back characters iteratively, keeping recursion shallow
for things like `.*`; the CLI also raises the recursion limit and runs on a
large-stack thread. Start positions are tried in order, skipping those whose
character cannot begin a match, and `^`-anchored patterns try only position 0.
There is no memoisation or automaton simulation, so pathological patterns are
exponential, as with any backtracker.

## Tests

```sh
python3 -m pytest regex      # from the repository root, or `pytest` here
```
