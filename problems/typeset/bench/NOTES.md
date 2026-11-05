# typeset performance benchmark

Built by `python3 gen_bench.py` (fixed seeds; expected outputs from `reference/main.py`, about 5-8 s per case).
Run with `python3 run_tests.py typeset --tests-dir problems/typeset/bench -- <impl>/run.sh`.

- `001_book_throughput` — a 416-page book (60 chapters, ~1 MB of Codexa) in the style of the suite's `big_book`: TOC, four heading levels, nested lists, quotes, listings, 80 tables, 90 floating figures, 600 footnotes and running headers on a 6x9in page.
  It is the ordinary end-to-end workload (parse, hyphenate, break, paginate, write 8 MB of layout) scaled up roughly 11x, so it measures overall throughput rather than any single phase.
- `002_long_paragraphs_linebreak` — 40 unbroken paragraphs of 1500-3500 words on a narrow (3.75in) measure at the default tolerance, 260 pages.
  Total-fit line breaking with Liang hyphenation dominates; 10 of the 40 paragraphs find no pass-1 breaking and fall back to the second pass, so both passes and the node table are exercised on long lists. Pruning overfull predecessors (permitted by the spec) matters a lot here.
- `003_mixed_floats_footnotes` — a random document of 2400 top-level blocks of every kind (DocGen from `gen_tests.py`) on A5 pages with running heads and a TOC: 728 footnotes, 152 figures, 176 tables, 378 pages.
  Exercises the page builder (footnote areas, the figure FIFO, widows/orphans, keep-with-next) and table layout alongside many short lists, a realistic mixed load.

All inputs are valid under SPEC.md (no error.txt; at most 999 footnotes, under 3000 pages, figure heights within the guarantees).

## Long tier

`python3 gen_bench.py --long` writes `../bench-long/` (002 takes several minutes); expected outputs come from the reference. `--expected-from <run.sh> ...` instead takes them from implementations that must agree. No SPEC.md limit changed.

- `002_long_paragraphs_linebreak`: 320 paragraphs of the same lengths (was 40), 2,109 pages; expected output from the reference.
- `001_book_throughput`: the same book generator at twice the size (120 chapters, 160 tables, 180 figures, 999 footnotes because of the 999-footnote guarantee), 819 pages. **Below the 5 s target.**
- `003_mixed_floats_footnotes`: the same random document at 4,800 blocks (was 2,400) with footnotes allowed in 2 of every 10 blocks, 738 pages. **Below the 5 s target.**

001 and 003 cannot reach the target: the work is linear in output (about 20 KB of `layout.txt` per page), so 5-7 s would need about 15-25x the pages (well over 100 MB of expected output each). Their TOC settings also reserve room only for three-digit page labels, so a document with a TOC must stay under 1000 pages (the generator checks this; at three times the size the page labels reach four digits and the reference and the implementations lay the TOC out differently).

Decision (floating figure after a page-end table): the long 003 showed the reference placing Figure 38, which follows a table that ends body page 88, on page 89, while C++, Go, D and Python put it on page 90. The vertical items there are `ROW, GLUE(table-space), FLOATMARK, ...`, and `ROW` fits but `ROW + table-space` does not. SPEC.md ("Vertical placement on a page", "Page breaking" step 2) drops only *trailing* `GLUE` from the used body height, so the `GLUE` before a `FLOATMARK` counts once the mark is in the prefix: the cut after the mark overflows and the page ends before the `FLOATMARK`, so the figure is queued on page 89 and placed on page 90. The reference treated that glue as trailing (its used height was not updated past a `FLOATMARK`), which is a reference bug, not a spec ambiguity. `reference/layout.py` now counts it (`Placer.advance_mark`), both when choosing the cut and for `B` in step 5. No public, hidden or short-bench expected output changed; the long 003 from the fixed reference is byte-identical to the four implementations' output. Rust still fails long 003: it chooses the cut as the old reference did (the figure lands on page 89) but counts the glue in `B`, so its footnote placement on page 88 differs from both.

Measured with the canonical builds on a loaded machine (best of two, wall): 001 0.29 s (Rust), 002 7.1 s (C++; 5.2 s user), 003 0.20 s (Rust). Peak RSS at most 474 MB (Go, 002). Python passes all three: 13 s, 558 s and 8 s. bench-long is about 75 MB.
