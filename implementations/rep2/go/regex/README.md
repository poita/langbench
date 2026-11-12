# regex

A small backtracking regular-expression engine for Go, with Perl-style
leftmost, greedy, ordered-choice semantics, plus a command-line tool that runs
many patterns over many subjects and reports every capture group's position.
It uses only the Go standard library and does not use `regexp`.

## Layout

| Path | Responsibility |
| --- | --- |
| `syntax/` | Pattern parser (recursive descent) and syntax tree; character classes become 256-bit sets |
| `regex.go` | Public API: `Compile`, `Find`, `FindIndex`, ... and the start-position search loop |
| `compile.go`, `prog.go` | Compiles the tree to a program; counted repetitions are expanded into copies |
| `vm.go` | Backtracking machine with an explicit stack (no recursion, so `.*` over huge subjects is fine) and an undo trail for capture writes |
| `analysis.go` | Per-pattern first-byte set and `^`-anchoring, used to skip impossible start positions |
| `internal/batch/` | The stdin/stdout batch protocol |
| `cmd/regex/` | The command-line entry point |

## Build

Requires Go 1.27.

```
./build.sh          # builds bin/regex
go test ./...       # runs the tests
```

## Command-line use

`./run.sh` (or `bin/regex`) reads from stdin and writes to stdout:

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

Lines are taken verbatim (they may be empty or have leading and trailing spaces).
For each subject one line is printed: `no`, or `match START END` followed by
`|S,E` for each capture group in order (`|-` if the group did not take part).

```
$ printf '2\n(a|(b))+\n2\nba\nab\n[^a-c]\\d{2,3}x?\n2\nzz123xx\nabc9\n' | ./run.sh
match 0 2|1,2|0,1
match 0 2|1,2|1,2
match 1 6
no
```

A malformed input or an invalid pattern prints a message to stderr and exits 1.

## Pattern syntax

Literals; `.`; `^` and `$` (zero-width anchors); classes `[a-z_]`, `[^0-9]`;
`\d \w \s` and their complements `\D \W \S`; `\` followed by punctuation for a
literal; capturing groups `( )`; alternation `|`; greedy quantifiers
`* + ? {n} {n,} {n,m}` (counts up to 1000). There are no lazy quantifiers,
non-capturing groups, backreferences or `\b`; they are reported as errors.

Matching is by bytes. Semantics are the usual backtracking ones: alternatives
are tried left to right and the first overall success wins; an optional loop
iteration that matches the empty string ends the loop; a group reports the last
span it completed on the successful path. Backtracking is exponential in the
worst case, so do not run untrusted patterns.

## Library example

```go
package main

import (
	"fmt"

	"example.com/regex"
)

func main() {
	re, err := regex.Compile(`(\w+)@(\w+)\.com`)
	if err != nil {
		panic(err)
	}
	if m := re.Find("mail bob@example.com now"); m != nil {
		fmt.Println(m.Start, m.End)           // 5 20
		fmt.Println(m.Groups[0], m.Groups[1]) // {5 8} {9 16}
	}

	// Allocation-free form: [start end g1start g1end ...], -1 for unset groups.
	loc, ok := regex.MustCompile(`(a|(b))+`).FindIndex("ba", nil)
	fmt.Println(loc, ok) // [0 2 1 2 0 1] true
}
```

A `*Regexp` is safe for concurrent use.

## Design notes

* Alternation, loops and quantifiers compile to `split`/`jmp` instructions;
  the machine pushes a frame per `split` and resumes the latest one on failure.
* Capture writes are recorded on a trail; backtracking undoes only the writes
  made since the choice point, so the cost is proportional to the writes.
* A loop body that can match empty gets a mark/check pair so an empty optional
  iteration ends the loop, as the semantics require.
* Search tries start offsets in order, skipping offsets whose byte cannot begin
  a match, and tries only offset 0 when every match begins with `^`.
