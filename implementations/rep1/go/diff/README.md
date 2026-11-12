# diff — Myers diff and patch in Go

A small, dependency-free Go library and command-line tool that

- computes a **shortest** line-oriented edit script between two texts, using
  Myers' O(ND) algorithm in its linear-space "middle snake" form (exact: no
  cost cutoffs, no heuristics, no anchoring on unique lines), and
- **applies** an edit script to a text.

Lines are compared byte for byte (whitespace is significant). Lines are
interned to integer ids first, so comparisons in the search are O(1). Time is
O((N+M)·D), extra space O(N+M), recursion depth O(log D).

## Layout

| Path                | Purpose                                                          |
| ------------------- | ---------------------------------------------------------------- |
| `diff` (root pkg)   | public API: `Diff`, `Apply`, `Script`, `Edit`, `ParseScript`     |
| `internal/myers`    | the linear-space Myers algorithm on `[]int32` symbols            |
| `internal/cli`      | parsing of the stdin protocol and writing of the answer          |
| `cmd/diff`          | the thin `main` package                                          |

## Build and test

```
./build.sh        # builds bin/diff with `go build`
go test ./...     # unit, property and example tests (standard library only)
```

Requires Go 1.27.1 or newer. `run.sh` runs the built binary from any directory.

## Command-line use

The tool reads one request on stdin and writes the answer to stdout. Every line
ends in `\n`; counts are decimal; content lines are read by count, verbatim.

```
diff                 patch
N                    N
<N lines of A>       <N lines of A>
M                    K
<M lines of B>       <K script lines>
```

A script line is a tag character followed by the line's text: `' '` keeps the
next line of A, `'-'` deletes it, `'+'` inserts the text.

`diff` prints the number of script lines and a minimal script; `patch` prints
the number of lines of the result and the lines.

```
$ printf 'diff\n3\na\nb\nc\n3\na\nc\nd\n' | ./run.sh
4
 a
-b
 c
+d
```

Malformed input makes the tool print a message on stderr and exit with
status 1.

## Library use

```go
package main

import (
	"fmt"

	"example.com/diff"
)

func main() {
	a := []string{"a", "b", "c"}
	b := []string{"a", "c", "d"}

	script := diff.Diff(a, b) // a minimal script
	fmt.Print(script)         // " a\n-b\n c\n+d\n"
	fmt.Println(script.Cost()) // 2

	out, err := diff.Apply(a, script)
	fmt.Println(out, err) // [a c d] <nil>
}
```

`diff.ParseScript` turns script lines (tag + text) into a `diff.Script`, and
`Script.String` renders one back.
