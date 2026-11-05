# linediff

An exact, line-oriented diff and patch library for Go, with a small
command-line tool on top. The diff is a *shortest* edit script (minimum number
of deleted plus inserted lines), computed with Myers' O((N+M)·D) algorithm in
its linear-space "middle snake" form, after line interning and common
prefix/suffix trimming. Only the Go standard library is used, and the diff
algorithm is implemented from scratch.

## Layout

| Path | Responsibility |
|------|----------------|
| `lines.go`   | `SplitLines`: text to line views |
| `intern.go`  | `Intern`: lines to dense integer ids |
| `myers.go`   | linear-space Myers search over integer sequences |
| `diff.go`    | `Diff`, `DiffStrings`, `DiffIDs`, `Op`, `Tag`, `Cost` |
| `script.go`  | `AppendScript`, `ParseScript`, `EditsOf` (textual script format) |
| `patch.go`   | `Apply` |
| `cmd/diff/`  | the command-line tool (`Run` implements the stdin/stdout contract) |

## Build and test

```
./build.sh          # builds bin/diff  (go build ./cmd/diff)
go test ./...       # unit tests
```

Requires Go 1.27 or later.

## Command line

`bin/diff` (or `./run.sh`) reads a request on standard input and writes the
result on standard output. The first line is the mode, `diff` or `patch`.

```
diff            patch
N               N
<N lines of A>  <N lines of A>
M               K
<M lines of B>  <K script lines>
```

Counts are plain decimal integers and content is read strictly by count, so
lines that look like counts or tags are fine. Lines are compared byte for byte
(whitespace is significant).

A script line is a one-character tag followed by the line text: `' '` keeps
the next line of A, `'-'` deletes it, `'+'` inserts the text.

* `diff` prints the number of script lines and then a minimal script.
* `patch` prints the number of lines of the result and then the lines.

Example:

```
$ printf 'diff\n3\na\nb\nc\n3\na\nc\nd\n' | ./run.sh
4
 a
-b
 c
+d
$ printf 'patch\n3\na\nb\nc\n4\n a\n-b\n c\n+d\n' | ./run.sh
3
a
c
d
```

Leniencies: `\r\n` line endings, a missing final newline, trailing spaces or
tabs on count lines and extra empty lines at the end are accepted. Malformed
input gives a message on stderr and exit status 1.

## Library example

```go
package main

import (
	"fmt"
	"os"

	"linediff"
)

func main() {
	a := linediff.SplitLines([]byte("a\nb\nc\n"))
	b := linediff.SplitLines([]byte("a\nc\nd\n"))

	ops := linediff.Diff(a, b) // minimal edit script
	fmt.Println("cost:", linediff.Cost(ops))
	os.Stdout.Write(linediff.AppendScript(nil, a, b, ops))

	// Apply a script back to a.
	got, err := linediff.Apply(a, linediff.EditsOf(a, b, ops))
	if err != nil {
		panic(err)
	}
	for _, l := range got {
		fmt.Printf("%s\n", l)
	}
}
```

`Diff` works on `[][]byte`; `DiffStrings` on `[]string`; `DiffIDs` on
sequences of `int32` ids you have already interned. Scripts in text form are
read with `ParseScript` and applied with `Apply`, which reports
`ErrMismatch` if the script does not fit the file.

## Design notes

* Lines are interned once (one hash map shared by both files), so the search
  compares `int32` ids only.
* The recursion trims the common prefix/suffix, then finds the middle snake by
  running forward and backward searches in lockstep, and recurses on the two
  halves. Memory is O(N+M): the two frontier arrays are allocated once and
  reused, with overlap tests guarded by the diagonal ranges each frontier has
  actually reached.
* Points that fall outside the edit grid are marked unreachable rather than
  clamped, so the result is exact for every input.
