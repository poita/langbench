# spreadsheet

A small in-memory spreadsheet engine in Go with incremental recalculation,
plus a command-line tool that drives it. Cells hold numbers, strings or
formulas (`+ - * /`, `&`, comparisons, `IF`, and `SUM`/`MIN`/`MAX`/`AVG`/`COUNT`
over cells and ranges). Editing a cell recalculates only the cells that
transitively depend on it, and reference cycles evaluate to `#CYCLE!`. It uses
only the Go standard library.

## Layout

| Path                | Responsibility                                              |
|---------------------|-------------------------------------------------------------|
| `cellref/`          | Cell names (`A1`..`ZZ9999`) and row-major keys              |
| `numfmt/`           | Number display (`%.10g`-style, ties to even)                |
| `formula/`          | Formula parser producing a flat, resolvable AST             |
| `.` (package `spreadsheet`) | `Sheet`, `Value`, evaluator, dependency graph, recalculation |
| `cmd/spreadsheet/`  | The command-line tool                                       |

## Build

```
./build.sh          # writes bin/spreadsheet (uses `go build`)
go test ./...       # unit tests
```

## Command-line use

`./run.sh` reads commands from stdin, one per line, and prints the result of
`get` and `dump`:

```
set <CELL> <content>   content: number, "string", or =formula
get <CELL>             prints the displayed value (empty line if empty)
clear <CELL>
dump                   prints "<CELL> <value>" for non-empty cells, row-major
```

```
$ printf 'set A1 10\nset A2 =A1*2\nget A2\nset A1 =A2\nget A2\n' | ./run.sh
20
#CYCLE!
```

Errors are displayed as `#DIV/0!`, `#REF!`, `#CYCLE!` and `#VALUE!`. The full
language is described in `problems/spreadsheet/SPEC.md`.

## Library use

```go
package main

import (
	"fmt"

	"example.com/spreadsheet"
)

func main() {
	s := spreadsheet.New()
	s.Set("B1", "3")
	s.Set("B2", "4.5")
	s.Set("C1", "=SUM(B1:B2)")
	s.Set("C2", `=IF(C1>7, "big", "small")`)

	v, _ := s.Get("C2")
	fmt.Println(v) // big

	s.Set("B1", "1") // only C1 and C2 are recomputed
	v, _ = s.Get("C2")
	fmt.Println(v) // small

	for _, e := range s.Dump() { // row-major order
		fmt.Println(e.Name, e.Value)
	}
}
```

`Set` and `Clear` return an error for an invalid cell name or malformed
content and leave the sheet unchanged. `Value` exposes `Kind()`, `Number()`,
`Str()`, `Err()` and `String()` (the displayed form).

## How it works

Every named cell gets a dense integer handle; formulas are parsed once into a
resolved AST. After an edit, an iterative DFS over reverse edges finds the
affected set, and an iterative Tarjan SCC pass over just that set evaluates
cells dependencies-first and marks cyclic components `#CYCLE!`. There is no
cell-to-cell recursion, so 10,000-cell dependency chains are fine.
