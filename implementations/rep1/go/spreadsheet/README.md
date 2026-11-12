# spreadsheet

A small in-memory spreadsheet engine for Go with incremental recalculation,
plus a command-line tool that drives it from a simple line-oriented script.

Cells hold numbers, strings or formulas. Formulas can reference other cells and
ranges (`=SUM(A1:A10)`), use arithmetic, `&` concatenation, comparisons and
`IF`, and always reflect the current state of the sheet, including after cells
are changed, cleared, or become part of a reference cycle (`#CYCLE!`).

Only the Go standard library is used.

## How it works

Each `Set` parses the formula once into a syntax tree and records dependency
edges (ranges expanded) in both directions. After an edit, the *affected set*
(the edited cell plus everything that transitively reads it) is found by
following reverse edges, and Tarjan's strongly-connected-components algorithm
over that subgraph evaluates cells dependencies-first. Cyclic components get
`#CYCLE!`. Evaluation reads stored values; it never recurses from cell to
cell, so 10,000-deep dependency chains are fine.

## Build

Requires Go 1.27 or newer.

```sh
./build.sh          # builds bin/sheet
go test ./...       # runs the tests
```

## Command-line use

`bin/sheet` (or `./run.sh`) reads commands from standard input, one per line:

```
set <CELL> <content>     content: =formula | "string" | number
get <CELL>               prints the displayed value (empty line if empty)
clear <CELL>
dump                     prints "<CELL> <value>" for every non-empty cell,
                         in row-major order
```

Cells are named by one or two uppercase letters (columns `A`..`ZZ`) and a row
`1..9999`.

```sh
$ printf 'set A1 10\nset A2 =A1*2\nget A2\nset A1 =A2\nget A2\n' | ./run.sh
20
#CYCLE!
```

Malformed commands are reported on standard error and skipped; the exit status
is then 1.

### Formulas

Operators, lowest to highest precedence: `= <> < > <= >=`, `&`, `+ -`, `* /`,
unary `-`. Functions: `SUM MIN MAX AVG COUNT` (arguments may be expressions or
`REF:REF` ranges) and `IF(cond, a, b)`, which evaluates only the selected
branch. Errors are `#DIV/0!`, `#REF!`, `#CYCLE!` and `#VALUE!`. Numbers display
like C's `%.10g`, except that integers below 1e15 print in full.

## Library use

```go
package main

import (
	"fmt"

	"example.com/spreadsheet"
)

func main() {
	s := spreadsheet.New()
	s.Set("A1", "10")
	s.Set("A2", "32")
	s.Set("A3", "=A1+A2")

	v, _ := s.Get("A3")
	fmt.Println(v) // 42

	s.Set("A1", "=A3") // cycle
	v, _ = s.Get("A3")
	fmt.Println(v) // #CYCLE!

	for _, e := range s.Dump() { // row-major
		fmt.Println(e.Name, e.Value)
	}
}
```

Main API: `New`, `(*Sheet).Set / SetNumber / SetString / SetFormula / Clear /
Get / Dump`, the `Value` type (`Kind`, `Num`, `Text`, `Err`, `String`) and
`FormatNumber`. A `Sheet` is not safe for concurrent use.

## Layout

| File | Responsibility |
| --- | --- |
| `value.go` | `Value`, kinds, error codes |
| `format.go` | number display |
| `cellname.go` | cell names and row-major keys |
| `lexer.go`, `parser.go` | formula text to syntax tree and dependencies |
| `eval.go` | evaluation of syntax trees |
| `sheet.go` | `Sheet`, dependency graph, Tarjan-based recalculation |
| `cmd/sheet` | the command-line tool |
