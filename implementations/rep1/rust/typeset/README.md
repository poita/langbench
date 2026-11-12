# typeset

A typesetting engine for **Codexa**, a small invented markup language. It reads
a document (and an optional settings file), lays it out on numbered pages and
writes a complete, byte-reproducible description of every placed item.

Features: Knuth–Plass total-fit line breaking, Liang hyphenation, justified and
ragged alignment, headings with numbering, nested lists, block quotes, tables
with automatic column widths, preformatted text, footnotes that can split
across pages, floating figures with captions, a generated table of contents
with leaders, running headers and footers, and widow/orphan/keep-with-next
control. All arithmetic is exact integer arithmetic (lengths are millipoints),
so two runs always produce identical output. Only the Rust standard library is
used.

## Building

```sh
./build.sh            # or: cargo build --release
cargo test            # unit, API and golden-file tests
```

Requires Rust 1.96 or newer. The binary is `target/release/typeset`.

## Command line

```sh
typeset <input directory> <output directory>
# or, from anywhere:
./run.sh <input directory> <output directory>
```

The input directory contains `document.cdx` (required) and `settings.cfg`
(optional). The output directory is created if missing.

* On success `layout.txt` (one record per page, one line per placed text run,
  rule or box) and `report.txt` (counters such as `pages`, `lines`,
  `total-demerits`) are written.
* If the input is invalid, only `error.txt` is written, containing one line
  `<file>:<line>:<col>: <code>`. The exit status is still 0.

Font metrics (`faces/*.cfm`) and hyphenation patterns (`hyphen/*.chp`) are read
from a `data` directory **relative to the current working directory**; the
shipped copy is `data/` in this repository. Set `TYPESET_DATA` to use another
location. Nothing is read from stdin and nothing outside the output directory is
written.

### A small example

`document.cdx`:

```
@h1 Introduction
The quick brown fox jumps over the lazy dog.{n|A short footnote.}
```

```sh
mkdir -p out && ./run.sh input out && head out/layout.txt
```

## Library

The crate is also a library (`typeset`) split by responsibility:

| module | role |
|---|---|
| `settings`, `values` | `settings.cfg` parsing, defaults, derived geometry |
| `parser`, `inline`, `ast` | Codexa block and inline parsing, error detection |
| `metrics`, `patterns` | font metric files, Liang patterns and hyphenation |
| `hlist` | styled characters → boxes, glue and penalties |
| `linebreak` | total-fit line breaking (two passes) |
| `setline` | glue distribution, alignment, run merging |
| `layout`, `vlist` | block walk → vertical items (tables, figures, footnotes, TOC) |
| `page` | break legality, page cuts, footnote splitting, float queue |
| `header` | running headers and footers |
| `output` | `layout.txt` / `report.txt` formatting |

```rust
use std::path::Path;

let document = "@h1 Hello\nThe quick brown fox.\n";
match typeset::typeset(Some(document), None, Path::new("data"))? {
    Ok(out) => {
        print!("{}", out.layout); // the contents of layout.txt
        print!("{}", out.report); // the contents of report.txt
    }
    Err(e) => eprintln!("invalid input: {e}"), // e.g. "document.cdx:2:1: unknown-inline"
}
# Ok::<(), std::io::Error>(())
```

`typeset::typeset` takes the document text, optional settings text and the data
directory; the outer `Result` is for I/O problems with the data files, the inner
one is the spec's *invalid document* outcome. `typeset::run_dir` implements the
whole command-line contract on directories.

## Tests

* unit tests in each module (arithmetic, parsing, hyphenation, badness,
  glue distribution, output sorting, …);
* `tests/api.rs`: the public API on in-memory documents;
* `tests/fixtures.rs`: golden-file tests over `tests/fixtures/*` (inputs with
  expected `layout.txt`/`report.txt`/`error.txt`).
