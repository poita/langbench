# spreadsheet

An in-memory spreadsheet engine with incremental recalculation, written in
Clojure, plus a small command-line tool on top of it.

Cells hold numbers, strings or formulas (`=A1+B2*2`, `=SUM(A1:A9)`,
`=IF(B1>0, "pos", "neg")`, ...). Formulas always reflect the current contents of
the sheet, including after cells are changed, cleared, or made part of a
reference cycle (`#CYCLE!`). Only the edited cell and the cells that
transitively read it are recomputed on each edit.

## How it works

* **Parsing** (`spreadsheet.parser`): a recursive-descent parser turns a formula
  into a syntax tree with resolved references, once, when the cell is set. It
  also computes the cell's dependencies (ranges expanded).
* **Dependency graph** (`spreadsheet.core`): each cell stores its dependencies
  and the sheet keeps reverse edges (who reads whom).
* **Recalculation** (`spreadsheet.graph`): after an edit, a traversal of the
  reverse edges finds the affected set; an iterative Tarjan SCC pass over that
  subgraph yields components dependencies-first. Cyclic components get
  `#CYCLE!`; the others are evaluated as soon as they are emitted.
* **Evaluation** (`spreadsheet.eval`): walks the syntax tree reading *stored*
  values of referenced cells, so a formula is evaluated in time linear in its
  size.
* **Display** (`spreadsheet.format`): numbers print like C's `%.10g` (exactly
  rounded, ties to even) except that integers below 1e15 print in full.

## Requirements

Java and the [Clojure CLI](https://clojure.org/guides/install_clojure)
(Clojure 1.12.6, Java 27).

## Build

```sh
./build.sh
```

This resolves dependencies, caches the classpath in `.classpath` and
AOT-compiles the program into `classes/`.

## Command-line usage

`run.sh` reads commands from stdin (UTF-8, one per line) and writes results to
stdout:

```
set <CELL> <content>   content: =formula | "string" | number
get <CELL>             prints the displayed value (empty line if empty)
clear <CELL>
dump                   prints "<CELL> <value>" for every non-empty cell,
                       in row-major order
```

```sh
$ printf 'set A1 10\nset A2 32\nset A3 =A1+A2\nget A3\nset A1 =A3\nget A3\n' | ./run.sh
42
#CYCLE!
```

Cell names are one or two capital letters (`A`..`ZZ`) followed by a row
`1..9999`. Errors display as `#DIV/0!`, `#REF!`, `#CYCLE!` and `#VALUE!`.

## Library usage

Sheets are immutable values; `set-cell` and `clear-cell` return updated sheets.

```clojure
(require '[spreadsheet.core :as ss])

(def sheet
  (-> (ss/empty-sheet)
      (ss/set-cell "A1" "10")
      (ss/set-cell "A2" "32")
      (ss/set-cell "A3" "=A1+A2")
      (ss/set-cell "B1" "\"Total: \"")
      (ss/set-cell "B2" "=B1&A3")))

(ss/display sheet "A3")   ;=> "42"
(ss/value sheet "A3")     ;=> 42.0
(ss/display sheet "B2")   ;=> "Total: 42"

(def cyclic (ss/set-cell sheet "A1" "=A3"))
(ss/value cyclic "A3")    ;=> :error/cycle
(ss/dump sheet)           ;=> [["A1" "10"] ["B1" "Total: "] ["A2" "32"] ["B2" "Total: 42"] ["A3" "42"]]
```

Public API (`spreadsheet.core`): `empty-sheet`, `set-cell`, `clear-cell`,
`value`, `display`, `source`, `dump`, `error?`. Values are a double, a string,
one of `:error/div0 :error/ref :error/cycle :error/value`, or `nil` for an empty
cell. `spreadsheet.cli` exposes the command interpreter (`execute`, `run`) used
by the CLI.

## Project layout

```
src/spreadsheet/
  cell.clj     cell names and ids
  format.clj   number and value display
  parser.clj   formula parser, dependency extraction
  eval.clj     syntax tree evaluator
  graph.clj    affected-set traversal, Tarjan SCC
  core.clj     public API: the sheet and incremental recalculation
  cli.clj      command interpreter
  main.clj     stdin/stdout entry point
test/spreadsheet/  clojure.test tests, plus a test.check property test that
                   compares incremental results with a from-scratch evaluation
```

## Tests

```sh
clojure -M:test
```
