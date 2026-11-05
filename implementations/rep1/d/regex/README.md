# regexvm

A small backtracking regular-expression engine written in D, with Perl-style
**leftmost, greedy, ordered-choice** semantics.  It reports the first match in
a subject together with the position of **every capture group**, and includes
a batch command-line tool that matches many subjects against many patterns.

The engine is written from scratch (no `std.regex`): patterns are parsed into
a syntax tree, analysed, compiled to a flat program, and run by an iterative
virtual machine with an explicit choice-point stack and an undo trail — no
recursion in the matcher, so very long subjects are fine.

## Supported syntax

| Construct | Meaning |
|---|---|
| `a`, ` `, … | literal (any char except `\ . [ ] ( ) \| * + ? { } ^ $`) |
| `.` | any single character |
| `^`, `$` | start / end of subject (zero width, may appear anywhere) |
| `\d \w \s`, `\D \W \S` | digit / word / space sets and their complements |
| `\` + non-alphanumeric | that character literally (`\.`, `\\`, `\(`, `\ `, …) |
| `[abc]`, `[^a-z0-9_]`, `[\d.\]-]` | classes: characters, ranges, set escapes, negation |
| `( … )` | capturing group, numbered by opening parenthesis |
| `x\|y` | ordered alternation (empty branches allowed) |
| `* + ? {n} {n,} {n,m}` | greedy quantifiers (`0 ≤ n ≤ m`) |

Semantics are exactly those of "section 3" of the specification: ordered
choice, greedy quantifiers that give iterations back one at a time, an empty
optional iteration ends a repetition, a group keeps the value from the last
iteration that completed it, and values set on abandoned paths are discarded.
There are no lazy quantifiers, back-references, lookaround or flags.

## Building

Requires LDC and dub (developed with LDC 1.41.0 and dub 1.40.0); only the D
standard library is used.

```sh
./build.sh          # dub build -b release --compiler=ldc2 --config=cli  -> bin/regex-cli
dub test --compiler=ldc2          # run the library's unit tests
```

## Command-line tool

`./run.sh` reads the whole of stdin and writes one result line per subject to
stdout.

Input (lines end with `\n`; patterns and subjects are taken verbatim, spaces
and all, and may be empty):

```
N                    number of patterns
pattern_1
M_1                  number of subjects for pattern 1
subject_1_1
...
pattern_2
...
```

Output, one line per subject in input order:

* `no` — no match anywhere in the subject;
* `match <start> <end>` followed, for each group `1..G`, by `|<gs>,<ge>` or
  `|-` if the group is unset.  Offsets are 0-based; ends are exclusive.

```console
$ printf '2\n(a|(b))+\n2\nba\nab\n[^a-c]\\d{2,3}x?\n2\nzz123xx\nabc9\n' | ./run.sh
match 0 2|1,2|0,1
match 0 2|1,2|1,2
match 1 6
no
```

Exit status is 0 on success; on malformed input or an invalid pattern a message
goes to stderr and the status is 2.

## Using the library

```d
import regexvm;

void main()
{
    auto re = new Regex(`(a|ab)(c|bcd)(d*)`);   // throws RegexException if invalid

    auto m = re.matchFirst("xabcd");
    assert(m.matched);
    assert(m.begin == 1 && m.end == 5);
    assert(m.groups.length == 3);                // groups[0] is group 1
    assert(m.groups[1].of("xabcd") == "bcd");
    assert(m.groups[2].begin == 5 && m.groups[2].end == 5);  // empty, but set

    // Reuse a Match (and its storage) when matching many subjects:
    Match reuse;
    foreach (subject; ["abcd", "zzz"])
        if (re.matchFirst(subject, reuse)) { /* use reuse.begin, reuse.groups … */ }

    // A group that did not take part in the match is unset:
    auto m2 = new Regex("(a)|(b)").matchFirst("b");
    assert(!m2.groups[0].isSet && m2.groups[1].isSet);
}
```

The batch driver is also available: `runBatch(inputBytes, outputBuffer)`.

A `Regex` owns reusable scratch memory and is not safe to share between threads.

## Layout

```
dub.sdl             project manifest (configurations: cli, library, unittest)
build.sh run.sh     build / run the CLI
source/regexvm/     the library
  package.d         public imports
  regex.d           Regex, Match, Span — the public API
  errors.d          RegexException, InputFormatException
  charset.d         256-entry byte sets for classes and escapes
  ast.d             syntax-tree nodes (+ S-expression dump)
  parser.d          recursive-descent pattern parser
  analysis.d        nullability, ^-anchoring, first-byte sets
  program.d         instruction set, Program, disassembler
  compiler.d        tree -> flat program (counted quantifiers expanded)
  vm.d              iterative backtracking interpreter
  input.d output.d  zero-copy line reader, buffered result formatting
  batch.d           the N-patterns/M-subjects driver
app/main.d          thin CLI over runBatch
tests/regexvm/      unit tests (separate from the library sources)
```

## How it works

* **Compilation.** `seq` concatenates; `a|b|c` becomes `split`/`jmp` chains
  with the preferred branch first; a group is `save 2g … save 2g+1`.
  `x{min,max}` emits `min` inline copies, then either a `split`/`jmp` loop
  (unbounded) or `max-min` nested optional copies.  `mark`/`check` are emitted
  only when the body can match the empty string, implementing "an empty
  optional iteration ends the repetition".
* **Single-character loops.** `a*`, `.+`, `[^,]{2,5}` compile to one
  `charloop` instruction that scans greedily and pushes a *single* choice point;
  backtracking gives back one character at a time.
* **VM.** One `pc` loop; a choice-point stack plus an undo trail of
  `(slot, old value)` pairs restores captures on backtracking; stack, trail and
  capture array are allocated once per `Regex` and reused.
* **Start positions.** Patterns that must begin with `^` only try position 0;
  non-nullable patterns skip start positions whose byte is not in the
  first-byte set.

## License

MIT
