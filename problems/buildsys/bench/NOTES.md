# buildsys performance benchmark

To regenerate, run `python3 problems/buildsys/bench/gen_bench.py`. It uses fixed seeds, and the expected trees come from `reference/main.py` in about 65 s in total. To run the benchmark: `python3 run_tests.py buildsys --tests-dir problems/buildsys/bench -- <impl>/run.sh`.

All three cases are directory-mode sessions with no error lines in the log. Each one stays within the SPEC limits: at most 400 session steps, at most 2,400 steps per build, 24 included files, globs over at most 3,000 files, a workspace of at most 6 MB and about 3,600 files, and no source or output over 256 KB. There is one exception. A 2,000-step state file cannot fit in 256 KB, so the bound used for `.kiln-state` is 363,440 bytes, the size the official suite's own `gen_huge_2` writes.

- `001_monorepo_incremental` is a 24-module repository with 960 sources. It has two steps per source (a 3-input `concat` and then one of 11 line commands picked through `when`/`elsewhen`), plus a bundle, a cross-module `hash` link and a rule-made wrapper per module. That comes to 1,993 steps, 4,900 declared inputs and a 358 KB state file, driven through 101 builds at `-j` 1-64. Between builds, the session edits, creates, deletes and touches sources, module headers, build files and the shared prelude, with one `clean`. Each build re-evaluates the files and re-checks about 2,000 steps for freshness, but only a few actually run. This tests the graph, change detection, state-file and scheduler throughput of a real incremental workflow.
- `002_config_eval_heavy` has 24 packages over a 2,700-file tree. Configuration is done by nested rules (`package` → `compile_group` → `obj`) using glob/filter/reject with `**` and character classes, `uniq`/`sort`/`zip`/`has`/`indexof`, keyword and computed default arguments, and `write` manifests whose text is computed in KBL. There are 46 builds, during which the session creates and deletes files (glob results change), edits `config.kiln` (feature flags change every `obj` command string) and edits sources. Most of the time goes into evaluating the build files, glob matching most of all. This is the configure phase of a large generated build, so it measures the KBL interpreter rather than the commands.
- `003_doc_pipeline_preprocess` is a 12-chapter book. Each chapter is assembled by `preprocess` from 8 sections and 96 fragments (about 70 KB per chapter, and `@need` nests up to 4 deep through shared snippets and a glossary). Each chapter then goes through `dedup` → `sort_lines`, `grep` → `number`, and `replace`, followed by book-wide `concat`/`sort_lines`/`count_lines`/`hash`. There are 151 builds at `-j` 2-12. Edits to fragments, snippets, sections and the glossary cause rebuilds through depfile `dep` lines, with early cutoff. This tests command execution, depfiles and content hashing on realistic text sizes.

The calibration below is wall time for the `runs-large` builds on an M-series Mac, as the median of 3 runs:

| case | cpp | rust | go | d | python |
|---|---|---|---|---|---|
| 001 | 1.83 | 1.57 | 1.29 | 2.63 | 9.8 |
| 002 | 3.81 | 2.22 | 1.72 | 3.53 | 15.6 |
| 003 | 1.40 | 1.37 | 1.42 | 1.22 | 8.8 |

All five implementations reproduce the reference output on all three cases.

## Long tier

`python3 bench/gen_bench.py --long` writes `bench-long/`. The three sessions continue from the same seeds for many more edit/build rounds; the initial workspaces and build files are unchanged. 001 has 2,001 session steps (about 1,000 builds, 10x), 002 has 781 (about 390 builds, 8.7x) and 003 has 4,401 (about 2,200 builds, 14.7x). Expected trees come from `reference/main.py` (268 s, 428 s and 229 s; 390 MB peak RSS). The longer 001 session leaves a `.kiln-state` of 363,602 bytes, 162 bytes over the short tier's 363,440-byte bound, so the generator allows 400,000 bytes for it in the long tier.

Measured on a heavily loaded 8-core M-series Mac (CPU time is the reliable figure; wall time was 1.2-2.5x higher). Fastest per input (user + sys): 001 C++ 8.9 s (13.9 s wall; Go 9.4 s, Rust 9.1 s, D 16.7 s); 002 Rust 7.8 s (16.3 s wall; C++ 8.9 s, Go 11.1 s, D 10.7 s); 003 Rust 7.4 s (11.6 s wall; C++ 7.5 s, Go 7.7 s, D 9.4 s). Peak RSS is at most 215 MB (Go on 001). The Python build passes all three (860 s wall in total on the loaded machine, at most 440 MB RSS). `bench-long/` is 116 MB (the log files grow with the session). SPEC.md's session-length sentence now allows up to 5,000 steps in the long tier.
