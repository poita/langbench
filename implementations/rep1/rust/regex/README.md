# btregex

A small, dependency-free backtracking regular-expression engine for Rust with
Perl-style **leftmost, greedy, ordered-choice** semantics and exact capture
positions, plus a batch command-line tool.

The engine is written from scratch (no `regex` crate, no external engine). A
pattern is parsed by recursive descent into a syntax tree, compiled to a small
instruction set and executed by a backtracking VM with an explicit stack, so
very deep backtracking (`.*` over a 10 000-character subject) cannot overflow
the call stack. Capture writes are recorded on the backtrack stack, so undoing
a failed path costs time proportional to the writes it made. Searches skip start
offsets whose byte cannot begin a match and try only offset 0 for patterns that
begin with `^`.

## Supported syntax

| Construct | Meaning |
|-----------|---------|
| `a`, `\.`, `\ ` | literal (a backslash before any non-alphanumeric character is literal) |
| `.` | any single character |
| `^`, `$` | start / end of the subject (zero-width, no quantifier) |
| `[abc]`, `[^a-z]`, `[\d_-]` | character classes, ranges, negation |
| `\d \w \s`, `\D \W \S` | digit / word / whitespace sets and complements |
| `( ... )` | capturing group, numbered by opening parenthesis |
| `a\|b` | ordered alternation (empty branches allowed) |
| `* + ? {n} {n,} {n,m}` | greedy quantifiers (`n`, `m` ≤ 1000) |

There are no non-capturing groups, lazy quantifiers, backreferences or
lookaround. An optional iteration that matches the empty string ends its
repetition; a group keeps the value from its last completed iteration on the
successful path. Subjects are matched byte by byte.

## Building

```
cargo build --release      # or ./build.sh
cargo test                 # unit, integration, differential and doc tests
```

The binary is `target/release/btregex` (`./run.sh` runs it from any directory).

## Command-line usage

The tool reads a batch from stdin and writes results to stdout:

```
N
pattern_1
M_1
subject_1_1
...
```

Every line is taken verbatim (patterns and subjects may be empty or contain
spaces). For each subject one line is printed: `no`, or
`match <start> <end>` followed by `|<gs>,<ge>` (or `|-` if unset) for each
group, in order. Offsets are 0-based; ends are exclusive.

```
$ printf '2\n(a|ab)(c|bcd)(d*)\n1\nabcd\n(a|(b))+\n2\nba\nab\n' | ./run.sh
match 0 4|0,1|1,4|4,4
match 0 2|1,2|0,1
match 0 2|1,2|1,2
```

Malformed input or an invalid pattern prints a message to stderr and exits
non-zero.

## Library usage

```rust
use btregex::{Regex, Scratch};

fn main() -> Result<(), btregex::Error> {
    let re = Regex::new(r"(\w+)@(\w+)\.com")?;

    // One-off search.
    let m = re.find("mail bob@example.com now").unwrap();
    assert_eq!((m.start(), m.end()), (5, 20));
    assert_eq!(m.get(1), Some((5, 8)));   // "bob"
    assert_eq!(m.get(2), Some((9, 16)));  // "example"

    // Many subjects: reuse the working memory.
    let mut scratch = Scratch::new();
    for subject in ["a@b.com", "nothing here"] {
        if re.search(subject.as_bytes(), &mut scratch) {
            println!("{:?} group1={:?}", scratch.range(), scratch.group(1));
        }
    }
    Ok(())
}
```

## Layout

| Module | Responsibility |
|--------|----------------|
| `parser` | pattern bytes → `ast::Node` |
| `ast` | syntax tree |
| `charset` | 256-bit byte sets |
| `analysis` | nullability, first-byte sets, `^` anchoring |
| `compile` | syntax tree → instruction program |
| `vm` (private) | backtracking executor |
| `batch` | the stdin/stdout batch format used by the CLI |

Tests: unit tests in each module, `tests/spec_examples.rs` (semantics),
`tests/cli.rs` (end-to-end), and `tests/oracle.rs`, which compares the VM with
a literal recursive transcription of the matching definition on thousands of
random patterns.
