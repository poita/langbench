# regexbt

`regexbt` is a small backtracking regular-expression engine written in Go
using only the standard library. It implements Perl-style semantics for a
deliberately small dialect — leftmost match, greedy quantifiers, ordered
alternation — and reports the first match together with the position of every
capture group. It ships as a reusable library and as a batch command-line tool.

## Layout

| Path | Responsibility |
| --- | --- |
| `syntax/` | Pattern parser (recursive descent), syntax tree, character sets |
| `compile.go`, `prog.go` | Syntax tree → backtracking program (counted repeats are expanded) |
| `machine.go` | Interpreter with an explicit backtrack stack and an undo trail for captures |
| `analysis.go` | First-byte set and `^`-anchoring analysis used to skip impossible start positions |
| `regexp.go` | Public API (`Compile`, `Find`, ...) |
| `internal/batch/` | The line-oriented batch protocol used by the CLI |
| `cmd/regexbt/` | The command-line tool (a thin wrapper over `internal/batch`) |

## Building

Requires Go 1.27 or later.

```
./build.sh          # builds bin/regexbt  (equivalent to: go build -o bin/regexbt ./cmd/regexbt)
go test ./...       # runs the test suite
```

## Command-line use

`regexbt` (or `./run.sh`) reads from standard input:

```
N
pattern_1
M_1
subject_1_1
...
subject_1_M1
pattern_2
M_2
...
```

`N` is the number of patterns; each pattern line is followed by the number of
subjects `M` and then `M` subject lines. Lines are taken verbatim (they may be
empty or have leading/trailing spaces). It prints one line per subject:

* `no` if the pattern does not match anywhere in the subject;
* otherwise `match <start> <end>` followed by `|<gs>,<ge>` for each group
  `1..G` in order, or `|-` for a group that is unset. Offsets are 0-based,
  and end offsets are exclusive.

```
$ printf '2\n(a|(b))+\n2\nba\nab\n[^a-c]\\d{2,3}x?\n2\nzz123xx\nabc9\n' | ./run.sh
match 0 2|1,2|0,1
match 0 2|1,2|1,2
match 1 6
no
```

A syntax error in a pattern, or malformed input, is reported on standard error
and gives exit status 1 (results produced earlier are still written).

## Pattern syntax

```
regex      := branch ( '|' branch )*
branch     := piece*
piece      := atom quantifier?
atom       := literal | '.' | '^' | '$' | class | escape | '(' regex ')'
quantifier := '*' | '+' | '?' | '{n}' | '{n,}' | '{n,m}'
```

* `.` matches any byte; `^` / `$` match only at the start / end of the subject
  (and cannot be quantified).
* Escapes: `\d \D \w \W \s \S`; a backslash before any other non-alphanumeric
  character is that literal character.
* Classes: `[abc]`, `[^abc]`, ranges `[a-z]`, set escapes inside classes. A
  `-` is literal when first, last or escaped.
* Groups `( ... )` always capture and are numbered by their opening
  parenthesis. Quantifiers are always greedy; there are no lazy forms,
  lookaround or backreferences. Counts are limited to 1000.

Semantics are those of a depth-first backtracking matcher: the first
alternative that leads to an overall match wins, and an optional iteration of a
loop that matches the empty string ends the loop. A group inside a loop keeps
the value from the last iteration that passed through it. Start positions are
tried left to right and only the first match is reported.

Backtracking can be exponential on adversarial patterns such as `(a*)*b`.

## Library use

```go
package main

import (
	"fmt"

	"example.com/regexbt"
)

func main() {
	re, err := regexbt.Compile(`(\w+)@(\w+)\.com`)
	if err != nil {
		panic(err)
	}
	m, ok := re.Find("mail bob@example.com now")
	if !ok {
		return
	}
	fmt.Println(m.Start, m.End) // 5 20
	for i, g := range m.Groups {
		if g.IsSet() {
			fmt.Printf("group %d: [%d,%d)\n", i+1, g.Start, g.End)
		}
	}
}
```

`Regexp` is safe for concurrent use. `FindInto` reuses a `Match` to avoid
allocation when searching many subjects with one pattern.
