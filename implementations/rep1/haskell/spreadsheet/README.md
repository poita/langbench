# spreadsheet

A small in-memory spreadsheet engine in Haskell with **incremental
recalculation**, plus a command-line tool that drives it from a script.

Cells hold numbers, strings or formulas. Formulas reference other cells and
ranges (`=SUM(A1:B9)`, `=IF(C1>7, "big", "small")`, `=A1&": "&B1`, …) and
always reflect the current contents of the sheet, including after cells are
changed, cleared, or made part of a reference cycle (which yields `#CYCLE!`).

## How it works

* A `set` parses its formula **once**, by recursive descent, into a syntax tree
  with resolved references, and records its dependencies (ranges expanded) as
  edges from the cell and reverse edges on the cells it reads.
* After each `set`/`clear` only the *affected set* is recomputed: the edited
  cell plus everything that transitively reads it, found by following reverse
  edges. Tarjan's strongly-connected-components algorithm over that subgraph
  yields components dependencies-first; cyclic components get `#CYCLE!`, all
  other cells are evaluated as soon as their component is emitted.
* Evaluation reads the *stored* value of referenced cells — it never recurses
  into other cells — and never re-parses a formula. Work per edit is
  independent of the size of the rest of the sheet.
* Numbers are displayed exactly like C's `printf("%.10g")` (with integers below
  1e15 printed in full), using exact rational arithmetic so ties round to even.

## Building

Requires GHC 9.14 and cabal 3.18 (only GHC's bundled packages are used; the
tests additionally need `hspec` and `QuickCheck`).

```sh
./build.sh          # cabal build, then copies the binary to bin/spreadsheet
cabal test          # run the test suite
```

## Command-line usage

`./run.sh` (or `bin/spreadsheet`) reads commands from standard input, one per
line, and prints the results of `get` and `dump` on standard output.

| Command                  | Effect                                                       |
|--------------------------|--------------------------------------------------------------|
| `set <CELL> <content>`   | replace a cell: `=formula`, `"string"` or a number           |
| `get <CELL>`             | print the displayed value (an empty line for an empty cell)  |
| `clear <CELL>`           | make the cell empty                                          |
| `dump`                   | print `<CELL> <value>` for every non-empty cell, row-major   |

Cell names are one or two uppercase letters (`A`..`ZZ`) and a row 1..9999.

```console
$ printf 'set A1 10\nset A2 32\nset A3 =A1+A2\nget A3\nset A1 =A3\nget A1\nset A1 5\ndump\n' | ./run.sh
42
#CYCLE!
A1 5
A2 32
A3 37
```

Formula language: numbers, `"strings"`, cell references, ranges (only as
arguments of aggregates), unary `-`, `* /`, `+ -`, `&` (concatenation),
comparisons `= <> < > <= >=` (lowest precedence), parentheses, `IF(c, a, b)`
(lazy in its branches) and `SUM`/`MIN`/`MAX`/`AVG`/`COUNT`. Errors are
`#DIV/0!`, `#REF!` (invalid reference such as `AAA1` or `A0`), `#CYCLE!` and
`#VALUE!`. Malformed lines are reported on standard error and skipped.

## Library usage

```haskell
{-# LANGUAGE OverloadedStrings #-}
import Data.Maybe (fromJust)
import Spreadsheet

main :: IO ()
main = do
  let cell = fromJust . parseCellRef
      Right sheet =
        setCell (cell "A1") "10" empty
          >>= setCell (cell "A2") "=A1*2"
          >>= setCell (cell "A3") "=SUM(A1:A2)&\" total\""
  print (renderValue <$> lookupValue (cell "A3") sheet)     -- Just "30 total"

  let sheet' = setContent (cell "A1") (CNumber 1) sheet     -- edits are incremental
  print (renderValue <$> lookupValue (cell "A3") sheet')    -- Just "3 total"

  let cyc = either (error . show) id (setCell (cell "A1") "=A3" sheet)
  print (lookupValue (cell "A2") cyc)                       -- Just (VError ErrCycle)
```

### Modules

| Module                | Responsibility                                                  |
|-----------------------|-----------------------------------------------------------------|
| `Spreadsheet`         | umbrella module re-exporting the public API                     |
| `Spreadsheet.Types`   | `CellRef`, `Value`, `ErrorCode`, `Content`, formula syntax tree |
| `Spreadsheet.Parser`  | cell names, number literals, cell contents, formulas            |
| `Spreadsheet.Eval`    | pure evaluation of a formula against a lookup; dependencies     |
| `Spreadsheet.Format`  | number display (`%.10g`) and value rendering                    |
| `Spreadsheet.Graph`   | Tarjan's SCC algorithm                                          |
| `Spreadsheet.Sheet`   | the persistent `Sheet` and incremental recalculation            |
| `Spreadsheet.Command` | the `set`/`get`/`clear`/`dump` command language                 |

`Sheet` is an immutable value: `setCell`/`setContent`/`clearCell` return a new
sheet, so earlier versions stay valid.

## Tests

`cabal test` runs an hspec suite: unit tests per module, the worked examples of
the specification, and QuickCheck properties — including a model-based test
that compares the incremental engine after every random edit against a naive
whole-sheet oracle that finds cycles by transitive closure.
