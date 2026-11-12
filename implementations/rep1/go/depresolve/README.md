# depresolve

A deterministic package dependency resolver, as a Go library and a small
command-line tool.

Given a registry (every version of every package with its requirements) and a
root manifest, depresolve picks exactly one version for every needed package so
that every requirement is satisfied. The search is fully specified —
depth-first in requirement order, newest version first, chronological
backtracking — so the first solution found is *the* answer, and it is the same
on every run. If no resolution exists it reports `unsatisfiable`.

Supported ranges (npm semantics): `*`, exact `X.Y.Z`, `^X.Y.Z`, `~X.Y.Z` and
space-separated comparators (`>=1.2.0 <2.0.0`; `<`, `<=`, `>`, `>=`).
Versions are plain `MAJOR.MINOR.PATCH` and compared numerically.

The search uses an explicit stack (no recursion limit), a persistent pending
list shared between choice points, and precomputed candidate index ranges, so a
step costs O(1) plus the requirements it adds. Only the standard library is used.

## Build

Requires Go 1.27.1.

```
./build.sh          # writes bin/depresolve   (same as: go build -o bin/depresolve ./cmd/depresolve)
go test ./...       # run the tests
```

## Command-line use

`depresolve` reads the whole problem on stdin and writes the result to stdout
(`run.sh` simply runs `bin/depresolve`).

```
$ cat problem.txt
a 1.0.0: c ^1.0.0
b 1.0.0: c ~1.2.0
c 1.1.0:
c 1.2.5:
c 1.3.0:
root: a *, b *
$ ./run.sh < problem.txt
a 1.0.0
b 1.0.0
c 1.2.5
```

Input is zero or more registry lines `name X.Y.Z: dep range, dep range`
(nothing after the colon when there are no requirements) followed by one root
line `root: dep range, ...`. Output is one `name version` line per chosen
package sorted by name in byte order, or the single line `unsatisfiable`.
The exit status is 0 in both cases; malformed input prints a message on stderr
and exits 1.

## Library use

```go
package main

import (
	"fmt"
	"strings"

	"depresolve/registry"
	"depresolve/resolve"
	"depresolve/semver"
)

func main() {
	in, err := registry.Parse(strings.NewReader(
		"a 1.0.0: c ^1.0.0\nc 1.2.0:\nc 1.3.0:\nroot: a *\n"))
	if err != nil {
		panic(err)
	}
	res, err := resolve.Resolve(in.Registry, in.Root)
	if err == resolve.ErrUnsatisfiable {
		fmt.Println("no solution")
		return
	}
	for _, p := range res {
		fmt.Println(p.Package, p.Version) // a 1.0.0 / c 1.3.0
	}

	// Registries can also be built programmatically.
	reg := registry.New()
	reg.Add("lib", semver.MustParseVersion("2.1.0"), nil)
	res, _ = resolve.Resolve(reg, []registry.Requirement{
		{Package: "lib", Range: semver.MustParseRange("^2.0.0")},
	})
	fmt.Println(res[0].Package, res[0].Version) // lib 2.1.0
}
```

## Layout

| Path | Responsibility |
|---|---|
| `semver/` | `Version`, `Range` (half-open interval form of every supported range) |
| `registry/` | `Registry` model and the text-format parser (`Parse`, `ParseRequirements`) |
| `resolve/` | the search (`Resolve`, `Resolution`, `ErrUnsatisfiable`) |
| `depresolve.go` | convenience `Solve` / `Run` (text in, text out) |
| `cmd/depresolve/` | the command-line tool |

The resolve tests cross-check the engine against a literal transcription of
the specification's recursive pseudocode on thousands of random registries.
