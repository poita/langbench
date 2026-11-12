# depresolve

A deterministic package dependency resolver written in Go, with no
dependencies outside the standard library.

Given a registry (every version of every package, each with its
requirements) and a root manifest, `depresolve` picks one version of every
package that is needed so that all requirements hold. The answer is defined
as the **first** solution of a depth-first search that tries versions newest
first and backtracks chronologically, so any two runs agree. If there is no
solution it reports `unsatisfiable`.

The search is iterative (no deep recursion), does not copy state at choice
points (choices are undone through a stack; pending requirements are shared),
and finds each requirement's candidate versions by binary search once, before
the search starts.

## Layout

| Path | Contents |
|---|---|
| `version.go` | `Version`, numeric comparison, parsing |
| `rangespec.go` | `Range`: `*`, exact, `^`, `~` and comparator ranges |
| `registry.go` | `Registry`, `Requirement` |
| `parse.go` | reader for the text format |
| `resolve.go` | `Registry.Resolve`, the search |
| `cmd/depresolve` | the command-line tool |

## Build

Requires Go 1.27 or newer.

```sh
./build.sh          # produces ./bin/depresolve
go test ./...       # runs the tests
```

## Command-line use

`depresolve` reads the whole input on stdin and writes the result to stdout
(`./run.sh` runs the built binary from anywhere).

```
$ printf 'a 1.0.0: c ^1.0.0\nb 1.0.0: c ~1.2.0\nc 1.1.0:\nc 1.2.5:\nc 1.3.0:\nroot: a *, b *\n' | ./run.sh
a 1.0.0
b 1.0.0
c 1.2.5
```

Input is zero or more registry lines `name X.Y.Z: req, req` followed by one
root line `root: req, req`. A requirement is `name range`, where range is
`*`, `X.Y.Z`, `^X.Y.Z`, `~X.Y.Z` or up to three comparators such as
`>=1.0.0 <2.0.0` (npm caret/tilde semantics, no prereleases). Output is one
`name version` line per chosen package sorted by name, or the single line
`unsatisfiable`. Exit status is 0 in both cases; malformed input prints a
message to stderr and exits 1.

## Library use

```go
package main

import (
	"errors"
	"fmt"

	"github.com/peteralexander/depresolve"
)

func main() {
	reg := depresolve.NewRegistry()
	reg.Add("app-lib", depresolve.MustParseVersion("1.0.0"),
		depresolve.MustParseRequirements("json ^1.0.0"))
	reg.Add("json", depresolve.MustParseVersion("1.2.0"), nil)
	reg.Add("json", depresolve.MustParseVersion("1.10.0"), nil)
	reg.Add("json", depresolve.MustParseVersion("2.0.0"), nil)

	root, err := depresolve.ParseRequirements("app-lib *")
	if err != nil {
		panic(err)
	}
	sol, err := reg.Resolve(root)
	if errors.Is(err, depresolve.ErrUnsatisfiable) {
		fmt.Println("no solution")
		return
	}
	for _, p := range sol {
		fmt.Println(p.Name, p.Version) // app-lib 1.0.0, then json 1.10.0
	}
}
```

Registries can also be read from the text format with `depresolve.Parse`.
