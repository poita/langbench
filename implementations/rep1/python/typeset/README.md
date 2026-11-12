# typeset

A typesetting engine for *Codexa*, a small invented markup language. It reads
a document (and optional settings), lays it out on numbered pages and writes a
complete, exact description of every placed item.

Features: total-fit (Knuth–Plass) line breaking, Liang hyphenation, four
alignments, nested lists, tables with automatic column widths, footnotes that
can split across pages, floating figures, widow/orphan/keep-with-next control,
a generated table of contents with leaders, and running headers and footers.
All arithmetic is exact integer arithmetic (lengths are millipoints), so the
output is byte-for-byte reproducible.

The specification is in `problems/typeset/SPEC.md`; this project is pure
Python (3.12+) and uses only the standard library.

## Build

```sh
./build.sh          # byte-compiles the package; there is no install step
```

## Command line

```sh
./run.sh <input directory> <output directory>
```

`<input directory>` holds `document.cdx` and, optionally, `settings.cfg`. The
output directory receives `layout.txt` and `report.txt`, or a single
`error.txt` (`file:line:col: code`) if the input is invalid; the exit status
is 0 in both cases. Font metrics and hyphenation patterns are read from
`data/faces/*.cfm` and `data/hyphen/*.chp` **relative to the current working
directory**.

`run.sh` is equivalent to
`PYTHONPATH=src python3 -m typeset <input> <output>`; after `pip install .`
the `typeset` console script does the same.

## Library

```python
from typeset import typeset, CodexaError

document = """\
@h1 Introduction
The quick brown fox jumps over the lazy dog.{n|A pangram.}
"""
settings = "page-width = 200pt\npage-height = 160pt\n"

try:
    result = typeset(document, settings, data_dir="data")
except CodexaError as err:
    print(err.format())          # e.g. document.cdx:2:1: unknown-inline
else:
    print(result.layout)         # contents of layout.txt
    print(result.report)         # contents of report.txt
    print(len(result.pages))     # Page objects (label, items, ...)
```

Public API (`typeset/__init__.py`):

| name | purpose |
|---|---|
| `typeset(document, settings=None, data_dir="data")` | run the whole pipeline on text, returns a `Result` |
| `typeset_directory(input_dir, output_dir, data_dir="data")` | what the CLI does |
| `parse_document(text)`, `parse_settings(text)` | the parsers on their own |
| `CodexaError` | the first error found (`file`, `line`, `col`, `code`, `format()`) |

## Layout of the code

| module | responsibility |
|---|---|
| `units` | floor division, `scale`, length/integer literals, roman/alpha numerals |
| `fonts`, `patterns` | `.cfm` metric files, `.chp` Liang pattern files, hyphenation |
| `settings` | `settings.cfg` parsing, the setting table, derived geometry |
| `inline`, `parser`, `nodes` | inline markup scanner; block parser and tree |
| `hlist` | fragments, boxes, glue, penalties, discretionary hyphens |
| `linebreak` | badness, demerits, two-pass total fit with O(1) line measurement |
| `lines` | glue distribution, alignment, run merging, line metrics |
| `blocks`, `tables`, `floats` | block walk, vertical spacing, tables, figures |
| `pages` | break legality, cut selection, footnote areas, float zones |
| `toc`, `headers` | table of contents with leaders, running headers/footers |
| `output`, `engine`, `cli` | item formatting and sorting, pipeline, command line |

## Tests

```sh
python3 -m pytest              # project tests (needs pytest)
cd .. && python3 run_tests.py typeset -- typeset/run.sh   # conformance suite
```

`tests/data/` holds a copy of the shipped font and pattern data so the project
tests do not depend on the working directory.
