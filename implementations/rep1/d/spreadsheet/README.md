# spreadsheet

An in-memory spreadsheet engine written in D, with incremental recalculation.
Cells hold numbers, strings or formulas; formulas always reflect the current
contents of the sheet, including after cells are changed, cleared or made part
of a reference cycle. It ships as a library (`spreadsheet`) and a thin
command-line tool that reads commands from stdin.

Only the D standard library (Phobos/druntime) is used.

## How it works

* `set` parses a formula once, by recursive descent, into a syntax tree with
  resolved references; evaluation only walks the tree.
* Each cell stores the cells it reads (ranges expanded) and reverse edges to
  the cells that read it.
* After every edit, the affected set (the edited cell plus everything that
  transitively reads it) is found through the reverse edges. Tarjan's SCC
  algorithm (iterative, so 10,000-deep chains are fine) orders it
  dependencies-first. Cyclic components get `#CYCLE!`; other cells are evaluated
  from the *stored* values of what they read. Nothing outside the affected set is touched.
* `get` is a hash lookup; `dump` sorts the non-empty cells row-major.

## Build

Requires LDC 1.41+ and dub 1.40+.

```sh
./build.sh          # dub build -b release --compiler=ldc2; produces ./spreadsheet
dub test --compiler=ldc2
```

The `library` configuration builds only the library: `dub build --config=library`.
To use it from another dub project, add the path as a dependency
(`dependency "spreadsheet" path="../spreadsheet"`) and `import spreadsheet;`.

## Command-line tool

```sh
./run.sh < commands.txt
```

One command per line on stdin:

| Command | Effect |
|---|---|
| `set <CELL> <content>` | content is a number (`-3`, `4.50`), a string (`"text"`, no escapes) or a formula (`=A1+B2*2`) |
| `get <CELL>` | print the displayed value (empty line for an empty cell) |
| `clear <CELL>` | make the cell empty |
| `dump` | print `<CELL> <value>` for every non-empty cell, row-major |

Cells are `A1`..`ZZ9999`. Formulas support `+ - * /`, `&` (concatenation),
`= <> < > <= >=`, unary minus, parentheses, `IF(c,a,b)` and
`SUM`/`MIN`/`MAX`/`AVG`/`COUNT` over expressions and ranges (`A1:B9`).
Errors are `#DIV/0!`, `#REF!`, `#CYCLE!` and `#VALUE!`. Numbers print as
`printf("%.10g")` (integers below 1e15 print in full). Malformed input
is reported on stderr and the exit status is 1; output produced before
the error is still written.

```
$ printf 'set A1 10\nset A2 32\nset A3 =A1+A2\nget A3\nset A1 =A3\nget A1\n' | ./run.sh
42
#CYCLE!
```

## Library example

```d
import spreadsheet;
import std.stdio;

void main()
{
    auto sheet = new Sheet;
    sheet.set(CellRef(1, 1), "10");          // A1
    sheet.set(CellRef(1, 2), "32");          // A2
    sheet.set(CellRef(1, 3), "=A1+A2");      // A3
    writeln(sheet.display(CellRef(1, 3)));   // 42

    sheet.set(CellRef(1, 1), "=A3");         // creates a cycle
    writeln(sheet.display(CellRef(1, 3)));   // #CYCLE!

    sheet.set(CellRef(1, 1), "5");           // breaks it again
    foreach (entry; sheet.dump())            // row-major
        writeln(entry.cell, " ", entry.value);
}
```

To drive a sheet with the text command language use
`runScript(sheet, scriptText, (const(char)[] chunk) { ... })`.

## Layout

| Module | Responsibility |
|---|---|
| `spreadsheet.cellref` | `CellRef`, parsing/formatting of `A1`-style names, key packing |
| `spreadsheet.value` | `Value`, `ErrorCode`, number display (`formatNumber`) |
| `spreadsheet.ast` | formula syntax tree, dependency collection, range iteration |
| `spreadsheet.parser` | cell content and formula parsing |
| `spreadsheet.eval` | formula evaluation against stored values |
| `spreadsheet.sheet` | `Sheet`: storage, dependency graph, incremental recalculation |
| `spreadsheet.script` | the `set`/`get`/`clear`/`dump` command language |
| `app.d` | the CLI |

Tests are `unittest` blocks next to the code (including the worked examples
from the spec); run them with `dub test --compiler=ldc2`.
