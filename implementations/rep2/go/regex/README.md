# regexvm

A small backtracking regular-expression engine in Go with Perl-style
semantics (leftmost start, ordered choice, greedy quantifiers, last-iteration
captures), a reusable library, and a batch command-line tool. Standard library
only; no `regexp` package is used.

## Supported syntax

Literals, `.`, `^`, `$`, classes `[a-z_]` / `[^...]`, escapes `\d \w \s \D \W \S`
and escaped punctuation, capturing groups `( )`, alternation `|`, and the greedy
quantifiers `* + ? {n} {n,} {n,m}`. Only the first match in a subject is reported.

## How it works

`parse.go` builds a syntax tree; `syntax.go` computes start-position filters
(anchored-at-start, first-byte set); `compile.go` emits a flat program for a
backtracking VM (`char`, `any`, `class`, `split`, `jmp`, `save`, `mark`,
`check`, `charloop`, `match`); `matcher.go` runs it iteratively with an explicit
choice-point stack and an undo trail for captures, so there is no recursion and
no per-match allocation. Single-character loops (`.*`, `\w+`, `[^,]{2,5}`) use
one choice point each.

## Build and test

```
./build.sh          # produces bin/regexvm
go test ./...       # unit tests
```

## Command line

`run.sh` (or `bin/regexvm`) reads stdin and writes stdout:

```
N
pattern_1
M_1
subject_1_1
...
```

Lines are taken verbatim (empty, space-only and integer-looking lines are
fine). For each subject one line is printed: `no`, or
`match <start> <end>` followed by `|<gs>,<ge>` (or `|-` if unset) for each
group in order.

```
$ printf '2\n(a|(b))+\n2\nba\nab\n[^a-c]\\d{2,3}x?\n1\nzz123xx\n' | ./run.sh
match 0 2|1,2|0,1
match 0 2|1,2|1,2
match 1 6
```

Exit status is 0 on success, 1 on malformed input or an invalid pattern.

## Library

```go
package main

import (
	"fmt"

	"example.com/regexvm"
)

func main() {
	re, err := regexvm.Compile(`(\w+)@(\w+)\.com`)
	if err != nil {
		panic(err)
	}

	// Reuse one Matcher across many subjects to avoid allocation.
	var m regexvm.Matcher
	m.Reset(re)
	if m.Match([]byte("mail bob@example.com now")) {
		fmt.Println(m.Start(), m.End()) // 5 20
		s, e, ok := m.Group(2)
		fmt.Println(s, e, ok) // 9 16 true
	}

	// One-shot helper: [start end g1start g1end ...], -1 for unset groups.
	fmt.Println(re.FindSubmatchIndex([]byte("a@b.com")))
}
```

A `*Regexp` is immutable and safe for concurrent use; a `*Matcher` is not.
Invalid patterns return a `*regexvm.SyntaxError`.

## Notes

Backtracking is exponential on pathological patterns such as `(a*)*b` against
long non-matching input; that is inherent in the specified semantics.
