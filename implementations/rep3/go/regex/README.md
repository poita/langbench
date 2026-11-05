# regex

A backtracking regular-expression engine for a defined Perl-style subset
(leftmost match, greedy quantifiers, ordered alternation, capture groups
reported as positions), written in Go with no dependencies beyond the
standard library. It does not use `regexp` or any other engine: patterns are
parsed to a syntax tree, compiled to a flat program and run on a small
backtracking virtual machine with an explicit choice-point stack and an undo
trail (so deep subjects do not grow the call stack).

## Layout

| Path            | Role                                                              |
|-----------------|-------------------------------------------------------------------|
| `syntax/`       | Parser, syntax tree, character sets, start-position analysis      |
| `prog/`         | Instruction set and tree-to-program compiler                      |
| `regex.go`, `vm.go` | Public API (`Regexp`, `Matcher`) and the interpreter          |
| `cmd/regex/`    | Command-line tool                                                 |

## Build and test

```
./build.sh          # builds bin/regex   (go build)
go test ./...       # unit tests
./run.sh < input    # runs the CLI
```

Requires Go 1.27.1.

## Pattern syntax

Literals, `.`, `^`, `$`, classes (`[a-z]`, `[^x]`, with `\d \D \w \W \s \S` and
escaped characters inside), the escapes `\d \D \w \W \s \S` and `\` + any
non-alphanumeric character, capturing groups `( )`, alternation `|`, and the
greedy quantifiers `* + ? {n} {n,} {n,m}` (counts up to 1000). There are no
non-capturing groups, lazy quantifiers, lookaround or backreferences. Matching
is defined operationally by the continuation-passing semantics in the
problem's SPEC.md; the unit tests check the VM against a literal
transcription of that definition on random patterns.

## Command-line tool

The tool reads everything from stdin and writes to stdout:

```
N                  number of patterns
pattern_1          taken verbatim (may be empty or contain spaces)
M_1                number of subjects for this pattern
subject_1_1        M_1 subject lines, taken verbatim
...
```

For every subject it prints one line, `no` or `match START END` followed by
`|S,E` (or `|-` when unset) for each group in order; offsets are 0-based with
an exclusive end.

```
$ printf '1\n(a|(b))+\n2\nba\nab\n' | ./run.sh
match 0 2|1,2|0,1
match 0 2|1,2|1,2
```

Exit status is 0 on success and 1 if the input is malformed or a pattern does
not compile (output produced so far is still written).

## Library example

```go
package main

import (
	"fmt"

	"regex"
)

func main() {
	re := regex.MustCompile(`(\w+)@(\w+)\.com`)

	// One-shot: returns [start end g1start g1end g2start g2end], or nil.
	fmt.Println(re.FindStringSubmatchIndex("mail bob@example.com now"))
	// [5 20 5 8 9 16]

	// Reusing a Matcher avoids allocation across many subjects.
	m := re.NewMatcher()
	for _, s := range []string{"a@b.com", "nothing"} {
		if m.Find([]byte(s)) {
			g1s, g1e, _ := m.Group(1)
			fmt.Println(s, "->", m.Start(), m.End(), s[g1s:g1e])
		} else {
			fmt.Println(s, "-> no match")
		}
	}
}
```

A `Regexp` is immutable and safe for concurrent use; a `Matcher` is not. The
compiled program can be inspected with `fmt.Print(re.Program())`.

## Design notes

* Single-character repetitions (`.*`, `\d{2,5}`, `[^,]+`) compile to one
  `charloop` instruction that pushes a single choice point and gives back one
  character per backtrack.
* Loop bodies that can match the empty string get `mark`/`check` guards that
  implement the "an empty optional iteration ends the repetition" rule.
* Start positions are skipped using a static analysis: patterns beginning
  with `^` only try position 0, and non-nullable patterns skip positions whose
  character cannot begin a match.
* Counted quantifiers expand into copies of their body; programs larger than
  4M instructions are rejected with `prog.ErrTooLarge`.
