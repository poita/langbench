# svgraster performance benchmark

Regenerate with `python3 gen_bench.py` (deterministic; expected PPMs come from
`reference/main.py`, about 2.5 minutes in parallel). Run with
`python3 run_tests.py svgraster --tests-dir problems/svgraster/bench -- <impl>/run.sh`.

- `001_icon_corpus_64` — all 696 vendored icons (feather, simple-icons, tabler
  filled + outline) rendered at 64x64 in one run, like an icon-sheet build.
  It measures per-document throughput: XML/path parsing, transforms, and round
  join/cap stroking of many short outlines on small canvases. The inputs are real-world files.
- `002_topo_map_1200` — one generated 600x600-unit topographic map rendered at
  1200x1200: about 200 long closed cubic contours (each filled and stroked with round joins),
  cased 140-vertex road polylines (round/miter/bevel joins), rivers drawn with
  smooth `s` curves, `use` markers and a group-opacity graticule. This is the
  algorithmically heaviest path: curve flattening, stroke outlining and the
  nonzero union of many overlapping pieces at a high resolution.
- `003_mixed_illustrations` — the four test-suite illustrations at 4x size, a
  1000x1000 poster that composes them under nested transforms (incl. skew) and
  several group-opacity layers, and four hand-written feature documents at
  large sizes. It is a mixed realistic workload covering fills, strokes, arcs,
  `use`, and full-canvas group compositing.

Expected outputs were produced by the reference. All 20 compiled implementations
(cpp/rust/go/d across impls, projects, runs/rep1-3) and the Python ones pass them.

## Long tier

`python3 gen_bench.py --long` writes `../bench-long/` (same names; expected PPMs from the
reference, rendered one at a time, about 62 minutes). No SPEC.md limit had to change.

- `001_icon_corpus_64`: the same 696 vendored icons rendered as a multi-size icon-set
  build, each at 16, 20, 24, 32, 48 and 64 px (4,224 renders, files named
  `<icon>-<size>.svg`). Icon rendering costs about as much per output pixel as writing
  it, so this input is bound by its own size: 5 s would need roughly 30,000 renders and
  over 100 MB of expected PPMs. It is kept at 18 MB and does **not** reach the 5 s
  target (about 0.9 s for the fastest build).
- `002_topo_map_1200`: the same 1200x1200 topographic map with 230 hills instead of 9
  (about 5,800 filled and stroked contours overlapping at the same resolution), plus
  the same rivers, cased roads, trail and markers. More work per output pixel, so the
  PPM stays 4.3 MB.
- `003_mixed_illustrations`: the same nine documents plus a series of 11 further
  1000x1000 posters, each composing the four illustrations again as 60 extra rotated,
  scaled, translucent group-opacity panels (offscreen compositing per panel).

Measured on a heavily shared machine; times are CPU seconds normalised by a calibration
run to a lightly loaded machine: 001 C++ 0.9 s (all builds 0.9-1.1 s), 002 C++ 7.6 s
(Go 9.6, Rust 9.7, D 9.8), 003 C++ 7.3 s (Rust 9.9, Go 10.0). Peak RSS at most 215 MB
(Go). Size: 102 MB of file data (123 MB on disk with block overhead; 001 has
8,449 small files).
