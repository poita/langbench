# btregex

A from-scratch backtracking regular-expression engine for a small, well-defined
syntax, with Perl-style leftmost, greedy, ordered-choice semantics. It reports
the first match in a subject and the span of every capture group. Pure Python
(3.14), standard library only; no `re` module is used.

## Supported syntax

Literals, `.`, `^`, `$`, classes (`[a-z]`, `[^...]`, ranges, `\d \w \s` and
complements inside classes), escapes (`\d \D \w \W \s \S`, `\` + punctuation),
capturing groups `( )`, alternation `|`, and the quantifiers
`* + ? {n} {n,} {n,m}` (all greedy, `n,m <= 100`). Groups are numbered by their
opening parenthesis. Class complements are taken over ASCII.

## How it works

1. `parser.py` – recursive-descent parser producing a tree (`ast.py`).
2. `analysis.py` – computes the set of possible first characters and whether a
   pattern is anchored at the start, so impossible start positions are skipped.
3. `compiler.py` – compiles the tree to a flat program; counted quantifiers are
   expanded, runs of single-character atoms become one `REP` instruction.
4. `vm.py` – executes the program with an explicit backtracking stack (no
   recursion, so `.*` over very long subjects is fine). Capture writes go on a
   trail and are undone on backtracking at a cost proportional to the writes.
5. `pattern.py` – the public API; `cli.py` – the batch command-line tool.

Semantics follow the operational definition in the problem specification,
including the rule that an optional iteration matching the empty string ends
the repetition.

## Build

There is no real build step:

```sh
./build.sh      # byte-compiles src/
```

For a normal install use `pip install .` (setuptools, `pyproject.toml`).

## Command-line use

```sh
./run.sh < input.txt > output.txt     # or: PYTHONPATH=src python3 -m btregex
```

Input (stdin), strictly line-positional:

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

Output: one line per subject, in order: `no`, or
`match <start> <end>` followed by `|<s>,<e>` (or `|-` when unset) for each group.
For example `(a|ab)(c|bcd)(d*)` on `abcd` prints `match 0 4|0,1|1,4|4,4`.
Exit status is 0 on success, 2 for malformed input or an invalid pattern
(message on stderr).

## Library use

```python
import btregex

pat = btregex.compile(r"(\w+)@(\w+)\.com")
m = pat.search("mail bob@example.com now")
if m:
    print(m.span())      # (5, 20)
    print(m.group(1))    # 'bob'
    print(m.groups)      # ((5, 8), (9, 16))

btregex.search("a|ab", "ab").span()   # (0, 1): ordered choice, not longest
```

Public names: `compile`, `search`, `Pattern` (`.search`, `.group_count`),
`Match` (`.start`, `.end`, `.groups`, `.span(g)`, `.group(g)`) and
`PatternSyntaxError`.

## Tests

```sh
python3 -m pytest        # needs only pytest
```

The suite includes unit tests for the parser, matching semantics, the CLI, and
a differential fuzz test against `tests/oracle.py`, a direct recursive
transcription of the specification.
