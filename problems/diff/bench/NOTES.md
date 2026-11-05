# diff performance benchmark

All inputs are `diff` mode at the SPEC's size limits: N = 5000 lines of
C-like source (short lines, lots of recurring `}`, blank and `return` lines,
as in real code) and a total input of about 250 KB, just under the 300 KB cap.
The format allows only one diff per input, so compiled implementations finish
in about 0.02-0.15 s here. That is as heavy as the limits allow without falling
back to the degenerate "two disjoint files" worst case. Expected outputs come
from the reference (`reference/main.py`, 1-6 s per input). Their edit counts
are cross-checked against the verifier's bit-parallel LCS. Regenerate the
inputs with `python3 gen_bench.py`.

- `001_diff_5000_code_revision`: two revisions of a large source file, with 700
  localized hunks (delete up to 6 lines and insert up to 6 new ones), D = 3198.
  This is the ordinary "diff across many commits" workload. It measures
  interning/hashing throughput plus moderate Myers search over long equal runs.
- `002_diff_5000_heavy_rewrite`: a heavy rewrite. 30% of the lines are deleted,
  50% replaced and 30% get an inserted line after them, scattered evenly, so
  D = 6927 on 5000 vs 4515 lines. This is the algorithmically hardest realistic
  case, because the O((N+M)·D) search is near its limit. The many duplicate
  structural lines also make it hard to reduce the work by dropping lines unique
  to one file.
- `003_diff_5000_refactor_moves`: a refactor. 80 blocks of 20-80 lines (whole
  functions) are moved, followed by 350 small local edits, D = 5584. Moved
  blocks show up as large delete/insert pairs separated by long common runs.
  This tests the divide-and-conquer/backtracking path on a mix of long snakes
  and big gaps.

## Long tier

`python3 bench/gen_bench.py --long` writes `../bench-long/` with the same three
cases and seeds, on longer files: 001 N = 27,000 (D = 17,880), 002 N = 13,000
(D = 17,909), 003 N = 16,000 (D = 18,026). Hunk and block-move counts scale with
N, so edit density, and thus the character of each case, is unchanged.

Expected outputs come from the reference, as in the short tier. The reference
saves one V array per D step (O(D^2) memory), which is what limits the size: at
D of about 18,000 it peaks at 3.4-3.9 GB of memory (peak footprint; 2.5-2.8 GB
resident) and takes 35-37 s of CPU per input. The generator also checks that
each expected script turns A into B and has exactly the minimum edit count
from verify.py's independent bit-parallel LCS, and run_tests.py still checks
every answer with verify.py.

At this size the inputs are well under the 5 s target. Fastest canonical build
(user CPU, best of two, loaded machine): 001 0.46 s (C++), 002 0.43 s (C++),
003 0.44 s (C++); Rust, Go and D take 0.48-0.56 s. Peak RSS is under 15 MB for
all four (linear-space Myers). bench-long is about 5 MB on disk.
The Python build passes all three in 39-48 s of CPU (whole run_tests.py run, including verify.py).

SPEC.md's diff-mode limits (`N, M <= 150000`, total input under 10 MB) are
looser than the long tier needs (`N, M <= 27000`, 1.4 MB) and are left as they are.
