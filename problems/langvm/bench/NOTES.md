# langvm performance benchmark

Regenerate with `python3 problems/langvm/bench/gen_bench.py`. The inputs are deterministic, and every expected output comes from the Python reference (`reference/main.py`), which takes about 2 minutes, 1 minute and 7 seconds for the three inputs. All inputs stay within the SPEC.md section 18 limits.

- `001_mixed_application`: a seven-module application. It runs a discrete-event shop simulation over a generic heap with closure comparators (100k events, Str/Int maps, trait method, enum matching), then tokenises and counts word frequencies over about 600k generated characters (`charAt`, maps, `sortBy`, `strSplit`, `strReplace`). It also builds a persistent BST of 50k keys from a sum type with guarded matches, and does dense 80x80 Float matrix products. This tests the whole VM and standard library in realistic proportions, with no single degenerate hot path.
- `002_interpreter_in_vellum`: the four-module tokeniser/parser/evaluator program from the test suite, written in Vellum. It runs 300 generated mini-programs (sums of squares, gcd, Collatz, Fibonacci, prime counting, digit reversal), plus a minority that end in parse, unbound-name, division or step-guard errors. This is the heaviest kind of workload in SPEC 18.3 (string indexing, enum-heavy matching, map environments, deep call chains), scaled up about 5x from the largest existing test.
- `003_large_program_compile`: a generated program of 1.98 MB (just under the 2 MB stdin limit) with 2750 functions spread over 64 mutually importing modules, and loops, matches, closures, tuples and library calls. Most of its time goes to the front end (lexing, parsing, name resolution, type checking, exhaustiveness checking, bytecode generation), so it measures compiler throughput on the largest input the spec allows. Its 2185 lines of output are produced by short runs of each function.

## Long tier

`python3 problems/langvm/bench/gen_bench.py --long` writes `../bench-long/` (about 25 minutes; expected outputs from the reference, peak reference RSS 730 MB). SPEC.md's stdin limit was raised from 2 MB to 8 MB for it.

- `001_mixed_application`: the same seven modules with every phase scaled up: 700k simulated shop events (was 100k), 600k generated words (was 100k), a 350k-key tree (was 50k) and 21 rounds of 80x80 matrix products (was 3).
- `002_interpreter_in_vellum`: the same interpreter over 3,500 generated mini-programs (was 300).
- `003_large_program_compile`: a 7.8 MB generated program with 10,800 functions over 64 modules (was 1.98 MB / 2,750). **Below the 5 s target**: the compilers process about 10-15 MB/s and hold the whole program (about 100 bytes of RSS per source byte), so 5-7 s would need roughly a 60-90 MB program and several GB of RSS. This is the largest size that keeps every implementation under about 1 GB.

Measured on a loaded machine (best of two, wall): 001 8.3 s (D; C++ 9.4 s), 002 8.4 s (D; C++/Go 11.1 s), 003 0.59 s (C++). Peak RSS: 001 456 MB (Go), 002 59 MB, 003 895 MB (D). bench-long is about 8 MB.

The Python implementation passes all three: 565 s, 418 s and 17 s, peak RSS at most 704 MB.
