# regex

A backtracking regular-expression engine for a small Perl-flavoured subset,
written in Go with only the standard library. It has exactly specified
semantics — leftmost match, greedy quantifiers, ordered alternation — and
reports the position of every capture group. It comes as a reusable library
and a thin batch command-line tool.

The engine is written from scratch: the pattern is parsed to a tree, compiled
to a flat program, and run by an iterative backtracking virtual machine with an
explicit choice-point stack and an undo trail (no recursion, so a 10,000
character subject is no problem). A repeated single-character atom (`.*`,
`\w+`, `[^,]{2,5}`) costs one choice point, not one per character.

## Supported syntax

Literals, `.`, `^`, `$`, classes (`[a-z_]`, `[^,]`, with `\d \w \s` and their
complements inside), escapes (`\d \D \w \W \s \S` and `\` + any punctuation),
capturing groups `( )`, alternation `|`, and greedy quantifiers `* + ? {n}
{n,} {n,m}`. There are no lazy quantifiers, back-references or look-around;
non-capturing groups do not exist (every group captures). Matching is over
bytes.

## Build

```
./build.sh          # builds bin/regex using `go build`
go test ./...       # unit tests
```

Requires Go 1.27 or later; there are no dependencies.

## Command-line tool

`./run.sh` reads everything on standard input and writes results to standard
output:

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

Lines are positional and taken verbatim (patterns and subjects may be empty or
contain leading/trailing spaces). For every subject one line is printed: `no`,
or `match <start> <end>` followed by `|<gs>,<ge>` (or `|-` if unset) for each
group in order. Offsets are 0-based, ends exclusive.

```
$ printf '1\n(a|(b))+\n2\nba\nab\n' | ./run.sh
match 0 2|1,2|0,1
match 0 2|1,2|1,2
```

A malformed pattern or truncated input is reported on stderr with exit status 1.

## Library

```go
import "example.com/regex"

re, err := regex.Compile(`(\w+)@(\w+)\.com`)
if err != nil {
	log.Fatal(err) // *regex.SyntaxError or *regex.LimitError
}

// One-off use: [start end g1start g1end ...], -1 for unset groups, nil for no match.
fmt.Println(re.FindStringSubmatchIndex("mail bob@example.com now"))
// [5 20 5 8 9 16]

// Repeated use: a Matcher reuses its buffers across subjects and patterns.
var m regex.Matcher
m.Reset(re)
if m.Find([]byte("alice@host.com")) {
	start, end := m.Span()
	gs, ge, ok := m.Group(1)
	fmt.Println(start, end, gs, ge, ok) // 0 14 0 5 true
}
```

A `*Regex` is immutable and safe for concurrent use; a `Matcher` is not (use
one per goroutine). Full documentation: `go doc -all example.com/regex`.

## Layout

| Path | Responsibility |
|------|----------------|
| `regex.go` | public API: `Compile`, `Regex`, package documentation |
| `parse.go`, `ast.go`, `charset.go` | recursive-descent parser, syntax tree, 256-entry class tables |
| `analyze.go` | anchoring and first-character analysis used to skip start positions |
| `compile.go`, `prog.go` | compilation of the tree into the flat VM program |
| `matcher.go` | the VM interpreter and the reusable `Matcher` |
| `errors.go` | `SyntaxError`, `LimitError` |
| `internal/batch` | the stdin/stdout batch protocol |
| `cmd/regex` | the command-line entry point |
| `*_test.go` | unit tests, including a differential test against a naive transcription of the formal semantics |

## Limits

Counted-quantifier bounds are limited to 1000, and a pattern whose expansion
exceeds two million VM instructions is rejected with a `*LimitError`. As with
any backtracking engine, nested quantifiers over nullable bodies (such as
`(a*)*b`) can take exponential time on adversarial input.
