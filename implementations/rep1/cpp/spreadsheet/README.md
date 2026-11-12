# spreadsheet

A small in-memory spreadsheet engine in C++17 with **incremental
recalculation**. Cells hold numbers, strings or formulas; formulas always
reflect the current sheet, including after cells are changed, cleared, or made
part of a reference cycle.

The project is a reusable library (`libspreadsheet`) plus a thin command-line
tool, `ssheet`, that reads commands on stdin. It depends only on the C++
standard library (GoogleTest is used for the unit tests).

## How it works

* `set` parses a formula once (recursive descent) into a syntax tree and records
  its dependencies (ranges expanded) as edges in both directions.
* After every `set`/`clear`, the cells that transitively read the edited cell
  are found by walking reverse edges; Tarjan's strongly-connected-components
  algorithm (iterative, so 10,000-deep chains are fine) over that subgraph emits
  components dependencies-first. Cyclic components get `#CYCLE!`; every other
  cell is evaluated against the *stored* values of the cells it reads.
* Nothing outside the affected set is touched; `get` is a hash lookup.

## Layout

| Path | Contents |
| --- | --- |
| `include/spreadsheet/cell_ref.h` | `CellRef`, `CellRange`, name parsing/formatting |
| `include/spreadsheet/value.h` | `Value` (empty/number/string/error), number formatting |
| `include/spreadsheet/formula.h` | formula syntax tree, dependency extraction |
| `include/spreadsheet/parser.h` | `parse_formula`, `ParseError` |
| `include/spreadsheet/evaluator.h` | `evaluate`, the `CellLookup` interface |
| `include/spreadsheet/sheet.h` | `Sheet`: storage, dependency graph, recalculation |
| `include/spreadsheet/script.h` | `CommandProcessor`: the `set`/`get`/`clear`/`dump` protocol |
| `cli/main.cpp` | the `ssheet` executable |
| `tests/` | GoogleTest unit tests |

## Build

Requires a C++17 compiler and CMake ≥ 3.20 (GoogleTest optional, for tests).

```sh
./build.sh            # Release build into ./build
./build/spreadsheet_tests   # run the unit tests (or: ctest --test-dir build)
```

## Command-line tool

`ssheet` (or `./run.sh`) reads UTF-8 commands, one per line, from stdin:

```
set <CELL> <content>   content: =formula | "string" | number
get <CELL>             print the displayed value (empty line for an empty cell)
clear <CELL>
dump                   print every non-empty cell as "<CELL> <value>", row-major
```

Cells are `A1`..`ZZ9999`. Formulas support `+ - * /`, `&`, comparisons
(`= <> < > <= >=`), unary minus, `IF(c,a,b)` and `SUM/MIN/MAX/AVG/COUNT` over
expressions and ranges (`A1:B9`). Errors are `#DIV/0!`, `#REF!`, `#CYCLE!`,
`#VALUE!`. See `problems/spreadsheet/SPEC.md` for the full semantics.

```
$ printf 'set A1 10\nset A2 32\nset A3 =A1+A2\nget A3\nset A1 =A3\nget A1\n' | ./run.sh
42
#CYCLE!
```

Malformed command lines are reported on stderr and skipped.

## Library example

```cpp
#include <iostream>
#include "spreadsheet/sheet.h"

using namespace spreadsheet;

int main() {
  Sheet sheet;
  sheet.set_number(*parse_cell_ref("A1"), 10);
  sheet.set_number(*parse_cell_ref("A2"), 32);
  sheet.set_formula(*parse_cell_ref("A3"), "A1+A2");        // text after '='
  std::cout << sheet.display(*parse_cell_ref("A3")) << '\n';  // 42

  sheet.set_content(*parse_cell_ref("A1"), "=A3");           // CLI-style content
  std::cout << sheet.display(*parse_cell_ref("A3")) << '\n';  // #CYCLE!

  for (const auto& [ref, value] : sheet.cells())              // row-major
    std::cout << to_string(ref) << ' ' << value.display() << '\n';
}
```

Link against the `spreadsheet::spreadsheet` CMake target. `set_formula` /
`set_content` throw `ParseError` (leaving the sheet unchanged) on malformed
input.
