# depresolve

A deterministic package dependency resolver, as a Go library and a small
command-line tool. Given a registry (every version of every package with its
requirements) and a root manifest, it picks one version for every needed
package so that all requirements hold. The answer is defined as the **first**
solution of a depth-first, newest-version-first search with chronological
backtracking, so the same input always gives the same resolution. When no
resolution exists it reports `unsatisfiable`.

Standard library only; requires Go 1.27.

## Build

```sh
./build.sh          # writes bin/depresolve
go test ./...       # unit tests
```

## Command-line use

`depresolve` reads the whole input from stdin and writes the result to stdout
(`run.sh` is a thin wrapper that runs `bin/depresolve`).

```sh
$ printf 'a 1.0.0: c ^1.0.0\nb 1.0.0: c ~1.2.0\nc 1.1.0:\nc 1.2.5:\nc 1.3.0:\nroot: a *, b *\n' | ./run.sh
a 1.0.0
b 1.0.0
c 1.2.5
```

Input is one `name MAJOR.MINOR.PATCH: requirement, requirement` line per
package version, then a final `root: requirement, ...` line. A requirement is
`name range` where range is `*`, an exact version, `^X.Y.Z`, `~X.Y.Z` (npm
semantics), or one to three space-separated comparators (`>=1.2.0 <2.0.0`).
Output is one `name version` line per chosen package sorted by name, or the
single line `unsatisfiable`. The exit status is 0 in both cases; malformed
input prints a message on stderr and exits 2.

## Library

```go
package main

import (
	"errors"
	"fmt"

	"github.com/example/depresolve"
)

func main() {
	var b depresolve.Builder
	b.AddVersion("web", depresolve.Version{Major: 1}, depresolve.Requirement{
		Package: "log", Range: depresolve.Caret(depresolve.Version{Major: 1}),
	})
	b.AddVersion("log", depresolve.Version{Major: 1, Minor: 2})
	b.AddVersion("log", depresolve.Version{Major: 2})
	b.SetRoot(depresolve.Requirement{Package: "web", Range: depresolve.AnyVersion})

	p, err := b.Build()
	if err != nil {
		panic(err)
	}
	res, err := p.Resolve()
	if errors.Is(err, depresolve.ErrUnsatisfiable) {
		fmt.Println("no solution")
		return
	}
	fmt.Print(res) // log 1.2.0 / web 1.0.0
}
```

Or parse the text format: `p, err := depresolve.Parse(text)`
(`ParseReader` for an `io.Reader`).

### Layout

| file | responsibility |
|---|---|
| `version.go` | `Version`, numeric ordering, packing into one integer key |
| `constraint.go` | `Range`: `*`, exact, `^`, `~`, comparators reduced to one half-open interval |
| `problem.go` | `Builder`/`Problem`: name interning, sorted versions, per-requirement candidate windows |
| `parse.go` | the text format |
| `resolve.go` | the iterative search, `Resolution` |
| `cmd/depresolve` | the CLI |

### Design notes

- Package names are interned to dense ids; versions are packed into 64-bit
  keys (21 bits per component) that compare like versions.
- Each range becomes one interval; after sorting each package's versions
  newest first, every requirement stores the contiguous window of candidates
  it admits, found with two binary searches. Opening a choice point and
  re-checking an already chosen package are O(1).
- The search has no recursion. Choice points live on a frame stack; the
  pending requirement list is a persistent linked list in an arena that is
  truncated on backtrack; `chosen` is an array undone through the frame
  stack. Nothing is copied per step, and deep chains (thousands of levels)
  are fine.
