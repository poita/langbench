# spreadsheet

A small in-memory spreadsheet engine with eager, incremental recalculation,
written in Rust using only the standard library.

Cells hold numbers, strings or formulas. Formulas can reference other cells
and ranges, use arithmetic, comparison and `&` (concatenation) operators, `IF`,
and the aggregates `SUM`, `MIN`, `MAX`, `AVG` and `COUNT`. After every edit the
sheet is consistent: only the cells that transitively depend on the edited cell
are recomputed, and cells that are part of a reference cycle show `#CYCLE!`
until the cycle is broken.

## How it works

* A formula is parsed once (recursive descent) into a syntax tree with
  resolved references; the tree is never re-parsed.
* Each cell records the cells it reads and the cells that read it. A range
  contributes one edge per covered cell.
* After a `set` or `clear`, the affected set (the edited cell plus everything
  that transitively reads it) is found by walking reverse edges. Tarjan's
  strongly-connected-components algorithm (iterative, so 10,000-deep chains are
  fine) runs over that subgraph and emits components dependencies-first.
  Cyclic components get `#CYCLE!`; every other cell is evaluated from the
  *stored* values of the cells it reads.
* Nothing outside the affected set is touched.

## Build

```sh
cargo build --release     # or ./build.sh
```

The binary is `target/release/spreadsheet`; `./run.sh` runs it from any
directory. Run the tests with `cargo test`.

## Command-line use

The tool reads commands from stdin, one per line, and prints the results of
`get` and `dump` to stdout:

```
set <CELL> <content>   # content: =formula | "string" | number
get <CELL>             # print the displayed value (empty line if empty)
clear <CELL>
dump                   # every non-empty cell, row-major: "<CELL> <value>"
```

Cells are named by one or two uppercase letters and a row 1..9999 (`A1`,
`ZZ9999`). Example:

```sh
$ printf 'set A1 10\nset A2 32\nset A3 =A1+A2\nget A3\nset A1 =A3\nget A3\n' | ./run.sh
42
#CYCLE!
```

Numbers are displayed as integers when integral and below 1e15, otherwise like
C's `printf("%.10g")`. The exit status is 0 on success, 1 if some input lines
could not be parsed (they are reported on stderr and skipped), and 2 on I/O
failure.

## Library use

```rust
use spreadsheet::{CellRef, Sheet, Value};

let mut sheet = Sheet::new();
sheet.set_content("A1", "10").unwrap();
sheet.set_content("A2", "32").unwrap();
sheet.set_content("A3", "=A1+A2").unwrap();
assert_eq!(sheet.display("A3").unwrap(), "42");

// Edits recalculate dependents.
sheet.set_content("A1", "5").unwrap();
assert_eq!(sheet.get(CellRef::parse("A3").unwrap()), Value::Number(37.0));

// Cycles evaluate to #CYCLE! rather than failing.
sheet.set_content("A1", "=A3").unwrap();
assert_eq!(sheet.display("A3").unwrap(), "#CYCLE!");

// Non-empty cells in row-major order.
for (cell, value) in sheet.dump() {
    println!("{cell} {value}");
}
```

### Modules

| Module    | Responsibility                                               |
|-----------|--------------------------------------------------------------|
| `cell`    | `CellRef` addresses and `Range`s                             |
| `value`   | `Value`, `ErrorCode`, number formatting (`format_number`)    |
| `ast`     | syntax tree types                                            |
| `parser`  | formula text to syntax tree                                  |
| `eval`    | evaluation of a tree against stored values                   |
| `graph`   | iterative Tarjan SCC                                         |
| `sheet`   | `Sheet`: storage, dependency graph, incremental recalculation|
| `command` | the `set`/`get`/`clear`/`dump` command language              |
| `error`   | the library `Error` type                                     |

## Layout

```
src/lib.rs            library root
src/bin/spreadsheet.rs  the CLI
tests/sheet.rs        integration tests (API level)
build.sh, run.sh      build and run helpers
```
