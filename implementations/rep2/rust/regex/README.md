# btregex

A small, dependency-free **backtracking regular-expression engine** for a
compact Perl-style syntax, written in Rust. It finds the first match in a
subject (leftmost start, greedy quantifiers, ordered alternation) and reports
the position of every capture group.

It consists of a reusable library (`btregex`) and a thin command-line tool
(`btregex`) that evaluates batches of patterns and subjects read from stdin.

## Supported syntax

| Construct | Meaning |
|-----------|---------|
| `a`, `\.`, `\ ` | literal byte (escape any non-alphanumeric to make it literal) |
| `.` | any single character |
| `^`, `$` | start / end of the subject (zero width, usable anywhere) |
| `[abc]`, `[^a-z0-9_]`, `[\d\-x]` | character classes, ranges, negation |
| `\d \w \s`, `\D \W \S` | digit / word / whitespace sets and complements |
| `( … )` | capturing group, numbered by opening parenthesis |
| `a\|b` | ordered alternation (first alternative that succeeds wins) |
| `* + ?`, `{n}`, `{n,}`, `{n,m}` | greedy quantifiers, counts up to 100 |

Matching is byte-oriented and case-sensitive. There are no lazy quantifiers,
lookaround, back-references or non-capturing groups.

Semantics follow a precise operational definition: alternatives are tried
left to right, quantifiers take as many iterations as possible and give them
back one at a time, and an optional iteration that consumes nothing ends its
repetition. A group's capture is the text it matched the last time it
completed on the successful path; groups that never completed are unset.

## Building

```sh
./build.sh                 # or: cargo build --release
```

The binary is `target/release/btregex`; `./run.sh` runs it from any directory.

Run the tests with `cargo test`.

## Command-line usage

The tool reads stdin and writes stdout; it takes no arguments.

```
N                  number of patterns
pattern_1          one line, verbatim (may be empty or contain spaces)
M_1                number of subjects for this pattern
subject_1_1        M_1 lines, verbatim
...
```

For every subject one line is printed: `no` if the pattern matches nowhere,
otherwise `match <start> <end>` followed by `|<s>,<e>` (or `|-` if unset) for
each group in order. Offsets are 0-based and the end is exclusive.

```console
$ printf '2\n(a|(b))+\n2\nba\nab\n[^a-c]\\d{2,3}x?\n1\nzz123xx\n' | ./run.sh
match 0 2|1,2|0,1
match 0 2|1,2|1,2
match 1 6
```

If the input is malformed or a pattern is invalid, a message is printed to
stderr and the exit status is non-zero.

## Library usage

```rust
use btregex::Regex;

fn main() -> Result<(), btregex::Error> {
    let re = Regex::new(r"(a|ab)(c|bcd)(d*)")?;
    let m = re.find("abcd").expect("should match");
    assert_eq!(m.range(), 0..4);
    assert_eq!(m.group(1), Some(0..1));
    assert_eq!(m.group(2), Some(1..4));
    assert_eq!(m.group(3), Some(4..4));

    // Reuse one matcher (and its scratch memory) across many subjects.
    let re = Regex::new(r"\d+")?;
    let mut matcher = re.matcher();
    for subject in ["abc123", "none", "7"] {
        println!("{subject}: {:?}", matcher.find(subject).map(|m| m.range()));
    }
    Ok(())
}
```

`Regex::new` returns an `Error` (with `kind()` and `position()`) for invalid
patterns.

## Design

```
pattern ──parser──▶ AST ──analysis──▶ first-byte set, nullable, anchored
                     └──compiler──▶ program ──matcher (explicit stack)──▶ Match
```

* `parser` – recursive descent into an AST; classes become 256-bit sets.
* `analysis` – computes which bytes can start a match and whether a match
  must start at position 0, so the search skips impossible start positions.
* `compiler` – flattens the AST into a small instruction set (`Char`, `Set`,
  `Split`, `Jmp`, `Mark`, `Close`, `EmptyExit`, …); counted quantifiers are
  expanded into copies of their body.
* `matcher` – a backtracking VM with an explicit stack of branch points and
  undo records. Capture writes are logged as they happen, so undoing a failed
  path costs time proportional to its writes, and deep backtracking (e.g.
  `.*` over a long subject) cannot overflow the call stack.
* `batch` – the stdin/stdout format used by the CLI.

Worst-case matching time is exponential, as with any backtracker (`(a*)*b`
on a long run of `a`s).
