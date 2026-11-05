# depresolve

A deterministic package dependency resolver, as a Go library and a small
command-line tool. Given a registry (every version of every package with its
requirements) and a root manifest, it picks one version for every needed
package so that all requirements hold. The result is defined as the first
solution of a fixed search: depth-first in requirement order, newest candidate
version first, with chronological backtracking. Semantic versions are
`MAJOR.MINOR.PATCH`; ranges are `*`, exact, `^`, `~`, and one to three
`<`, `<=`, `>`, `>=` comparators (npm semantics).

Standard library only; requires Go 1.27.

## Build and test

```sh
./build.sh          # builds bin/depresolve
go test ./...       # unit tests
./run.sh < input    # runs the built tool
```

## Command line

`depresolve` reads the whole problem on stdin:

```
a 1.0.0: c ^1.0.0
b 1.0.0: c ~1.2.0
c 1.1.0:
c 1.2.5:
c 1.3.0:
root: a *, b *
```

Zero or more `name version: requirements` lines, then one `root: requirements`
line. Requirements are `name range` separated by `, `. It prints one
`name version` line per chosen package, sorted by name (byte order):

```
a 1.0.0
b 1.0.0
c 1.2.5
```

or the single line `unsatisfiable`. Both exit with status 0. Malformed input
prints a diagnostic on stderr and exits with status 2.

## Library

```go
import "github.com/example/depresolve"

problem, err := depresolve.Parse(os.Stdin) // or build a Registry by hand
if err != nil { ... }
res, err := problem.Resolve()
if errors.Is(err, depresolve.ErrUnsatisfiable) {
	fmt.Println("no solution")
}
for _, p := range res {
	fmt.Println(p.Name, p.Version)
}
```

Building the registry programmatically:

```go
reg := depresolve.NewRegistry()
reg.Add("lib", depresolve.MustParseVersion("1.4.0"), []depresolve.Requirement{
	{Name: "util", Range: depresolve.MustParseRange("^2.0.0")},
})
reg.Add("util", depresolve.MustParseVersion("2.1.0"), nil)
res, err := reg.Resolve([]depresolve.Requirement{
	{Name: "lib", Range: depresolve.AnyRange()},
})
```

### Layout

| file | responsibility |
|---|---|
| `version.go` | `Version`, numeric comparison, packed integer `Key` |
| `range.go` | `Range`, compiled to one half-open key interval |
| `registry.go` | `Registry`, `Requirement`; names interned to dense ids |
| `parse.go` | text format: `Parse`, `Problem`, `ParseError` |
| `resolve.go` | the search and `Resolution` |
| `cmd/depresolve` | the command-line tool |

### Implementation notes

Versions pack into one `uint64` (21 bits per component), so a range is two
integer comparisons. Each package's versions are sorted newest first and every
requirement is converted once to a window of candidate indices (two binary
searches). The search is iterative: a stack of choice-point frames, a `chosen`
array indexed by package id, and the pending requirements as a persistent
linked list in an arena that is truncated on backtracking. Nothing is copied
per step and the Go call stack does not grow with dependency depth.
