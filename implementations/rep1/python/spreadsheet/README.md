# spreadsheet

An in-memory spreadsheet engine with eager, incremental recalculation. Cells
hold numbers, strings or formulas (arithmetic, `&`, comparisons, `IF`, and
`SUM`/`MIN`/`MAX`/`AVG`/`COUNT` over expressions and ranges). Formulas always
reflect the current sheet, including reference cycles (`#CYCLE!`). It uses only
the Python standard library.

## Layout

| Module | Responsibility |
| --- | --- |
| `spreadsheet.sheet` | `Sheet`: cells, dependency graph, incremental recalculation (Tarjan SCC) |
| `spreadsheet.parser` / `spreadsheet.syntax` | Tokenizer, recursive-descent parser, syntax tree |
| `spreadsheet.evaluator` | Tree-walking evaluator over stored cell values |
| `spreadsheet.values` / `spreadsheet.formatting` | Value types, error codes, `%.10g`-style number display |
| `spreadsheet.refs` | Cell names and packed row-major keys |
| `spreadsheet.cli` | Command interpreter (`run_commands`) and `main` |

## Build

```
./build.sh        # byte-compiles the package; there is no install step
```

## Command-line use

`run.sh` reads commands from stdin (one per line) and prints the results of
`get` and `dump` to stdout:

```
set <CELL> <content>   # number, "string" or =formula
get <CELL>             # prints the displayed value (empty line if empty)
clear <CELL>
dump                   # every non-empty cell, row-major: "<CELL> <value>"
```

```
$ printf 'set A1 10\nset A2 =A1*2\nget A2\n' | ./run.sh
20
```

## Library use

```python
from spreadsheet import Sheet

sheet = Sheet()
sheet.set("A1", "10")
sheet.set("A2", '="total: "&SUM(A1,A1)')
sheet.set("B1", "=B1+1")

sheet.get("A2")      # 'total: 20'
sheet.get("B1")      # '#CYCLE!'
sheet.value("A1")    # 10.0  (float, str, CellError or None for empty)
sheet.dump()         # [('A1', '10'), ('B1', '#CYCLE!'), ('A2', 'total: 20')]
sheet.clear("A1")
```

## Tests

```
python3 -m pytest        # from this directory
```
