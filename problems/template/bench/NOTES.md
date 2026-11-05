# template performance benchmark

Regenerate with `python3 problems/template/bench/gen_bench.py` (fixed seeds; about 20 s). Expected outputs come from `reference/main.py`, and each one is also checked against Jinja2 3.1 (the gen_tests.py oracle, via `.oracle-venv`). Run with `python3 run_tests.py template --tests-dir problems/template/bench -- <impl>/run.sh`. Inputs stay at the scales the SPEC's "Sizes and performance" section names: contexts of about 1 MB, template bodies under 1 MB, trees of a few thousand nodes, and macro recursion depth under 100. They also respect every guarantee (for example, included templates never use `loop`).

- `001_catalog_page`: a storefront page for 2,907 products in 20 categories (1.1 MB JSON context). A child template extends a layout and includes a `card` partial per product. The card uses money/stars macros, `escape`/`trim`/`replace`/`sort`/`join` filters, attribute dicts and variant loops. The page also has brand-index, featured-lookup and tag pages, which scan the catalogue (about 220k loop iterations), and the output is 1.9 MB. This measures ordinary rendering throughput: scope lookup, include, macro calls and output building on realistic data.
- `002_macro_tree_report`: a directory-tree report over 7 trees with 968 to 5,957 nodes each (21k nodes, 1.2 MB context). Each node is rendered recursively, along with its subtree total, file count and height. These are computed by index-recursive macros whose string results are parsed back with `|int`, the SPEC's own idiom. This is O(nodes x depth) macro calls, and it is the algorithmically hardest path: macro call overhead, scope creation, and returning and re-parsing macro output.
- `003_dashboard_mixed`: a three-level inheritance sales dashboard (`dashboard` extends `mid` extends `base`, with `super()` chains). The leaf template is 784 KB and holds about 22k tags in 2,400 generated sections, so lexing and parsing cost real time. The render does nested region x product x month loops (about 85k iterations), float arithmetic and shortest-repr float printing, list/dict `in`, `sort`/`reverse`, `range` loops and list repr printing. This is a mixed real-world workload in which parsing, numeric formatting and loops all matter.

## Long tier

`python3 gen_bench.py --long [name-filter]` writes `../bench-long/` (same names; expected
outputs from `reference/main.py`, each also checked against Jinja2; about 25 minutes).
The SPEC's "Sizes and performance" paragraph now mentions the long tier's sizes (it
describes sizes, it sets no hard limit); template bodies stay under 1 MB.

- `001_catalog_page`: the same storefront over a 4x catalogue (17,000 products, 6.5 MB
  context, 11.7 MB page) with 5,000 featured ids instead of 40, so the related-products
  block scans the catalogue 5,000 times (about 85M loop iterations) and every card's
  `p.id in featured` test runs over the longer list.
- `002_macro_tree_report`: 190 trees instead of 7 (each still 500-7,000 nodes; 510k
  nodes in all, 27 MB context, 57 MB report), same recursive macros.
- `003_dashboard_mixed`: 10,000 products and 24 regions instead of 320 and 8 (16 MB
  context). The leaf template's generated sections still cover the first 200 products
  in the original 8 regions (784 KB template); the summary, per-region, monthly and
  region-versus-region loops (the last one quadratic in regions) run over everything.

Measured on a heavily shared machine; times are CPU seconds normalised by a calibration
run to a lightly loaded machine: 001 C++ 6.8 s (D 7.5, Rust 10.8, Go 11.6), 002 C++
6.9 s (Rust 12.9, D 14.2, Go 18.3), 003 Rust 6.4-7.9 s, C++ 7.8 s (D 7.6, Go 14.7).
Peak RSS 950 MB (D, 002). Size on disk 137 MB.
