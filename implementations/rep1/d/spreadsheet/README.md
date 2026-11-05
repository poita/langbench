# spreadsheet

An in-memory spreadsheet engine written in D, with a small command-line tool on top.
Cells hold numbers, strings or formulas. Formulas reference other cells and ranges,
and always reflect the current sheet: after every edit only the cells that
transitively depend on the edited cell are recalculated, and cells on a
reference cycle evaluate to `#CYCLE!`.

Only the D standard library (Phobos/druntime) is used.

## Layout

```
source/spreadsheet/   the library
  package.d           public imports (`import spreadsheet;`)
  sheet.d             Sheet: storage, dependency graph, incremental recalculation
  value.d             Value / Kind (empty, number, text, error)
  cellref.d           cell names (A1..ZZ9999) and row-major keys
  parser.d, ast.d     recursive-descent parser producing a resolved AST
  eval.d              formula evaluation
  numfmt.d            number parsing and the %.10g-style display rule
  script.d            the set/get/clear/dump command language
  stack.d             growable stack used for scratch state
cli/main.d            the command-line tool
tests/                unit tests (separate from the library source)
```

## Build

Requires LDC and dub.

```
dub build -b release --compiler=ldc2      # builds bin/spreadsheet (the "cli" configuration)
dub test --compiler=ldc2                  # runs the unit tests
./build.sh                                # same as the first command, from any directory
```

## Command-line use

`bin/spreadsheet` (or `./run.sh`) reads commands from stdin, one per line, and prints
the results of `get` and `dump` on stdout. It takes no arguments.

```
set <CELL> <content>   content: a number (-?digits[.digits]), a "string", or =formula
get <CELL>             prints the displayed value (an empty line for an empty cell)
clear <CELL>
dump                   prints "<CELL> <value>" for every non-empty cell, row-major
```

Cells are `A1` .. `ZZ9999`. Formulas support `+ - * /`, `&` (concatenation),
comparisons (`= <> < > <= >=`), `IF(c, a, b)`, and `SUM`/`MIN`/`MAX`/`AVG`/`COUNT`
over expressions and ranges such as `B1:B9`. Errors are `#DIV/0!`, `#REF!`,
`#CYCLE!` and `#VALUE!`. Numbers display as integers when integral and below 1e15,
otherwise like C's `%.10g`.

```
$ printf 'set A1 10\nset A2 32\nset A3 =A1+A2\nget A3\nset A1 =A3\nget A3\n' | ./run.sh
42
#CYCLE!
```

On malformed input the tool prints a message to stderr, writes the output
produced so far and exits with status 1.

## Library use

Add the package as a dependency and select the `library` configuration
(`subConfiguration "spreadsheet" "library"` in your `dub.sdl`), then:

```d
import std.stdio : write, writeln;
import spreadsheet;

void main()
{
    auto sheet = new Sheet;
    sheet.set("A1", "10");
    sheet.set("A2", "32");
    sheet.set("A3", "=A1+A2");
    writeln(sheet.display("A3"));          // 42

    sheet.set("A1", "=A3");                // A1 -> A3 -> A1
    writeln(sheet.get("A3").kind);         // cycle
    writeln(sheet.display("A3"));          // #CYCLE!

    sheet.set("A1", "5");
    writeln(sheet.get("A3").num);          // 37

    sheet.set("B1", `="total: "&A3`);
    write(sheet.dump());                 // A1 5 / B1 total: 37 / A2 32 / A3 37 (row-major)
}
```

Main entry points: `Sheet.set`, `Sheet.clear`, `Sheet.get` (returns a `Value`),
`Sheet.display`, `Sheet.dump`. Bad cell names throw `InvalidCellName`; malformed
content throws `SyntaxError` and leaves the sheet unchanged. `executeScript`
runs the stdin command language against a `Sheet`.

## Design notes

* Every cell gets a dense integer handle on first mention; per-cell state lives in arrays.
* Formulas are parsed once at `set` time into an AST whose references are handles.
* Dependency edges are stored in both directions (deduplicated; ranges expanded).
* After an edit, the affected set (the cell and all transitive dependents) is found by an
  iterative traversal, then an iterative Tarjan SCC pass over it evaluates components
  dependencies-first. Components with more than one cell, or a self-reading cell, are cyclic.
  There is no cell-to-cell recursion, so 10,000-deep chains need no deep stack.
