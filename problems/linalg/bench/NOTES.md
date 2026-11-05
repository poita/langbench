# linalg performance benchmark

Regenerate with `python3 problems/linalg/bench/gen_bench.py` (about 4 minutes,
fixed seeds). Expected outputs come from `reference/main.py`, and every case
is cross-checked against numpy/LAPACK by the oracle that `gen_tests.py` uses,
including the spectral-gap, sign-margin and pivot-tie guarantees of SPEC.md
section 4. Run with
`python3 run_tests.py linalg --tests-dir problems/linalg/bench -- <impl>/run.sh`.

- `001_dense_kernels_500` — the dense O(n³) kernels at the spec's size
  limit: a 500x500 product, det/inverse/solve through partial-pivot LU, a
  350x350 Cholesky and solve, and least squares on a 500x250 matrix via
  Householder QR. It measures raw loop speed and memory layout (row versus
  column access in the inner loops) on ordinary well-conditioned data, with no
  input that triggers an unusual code path.
- `002_jacobi_spectral` — the algorithmically hardest part of the library:
  cyclic Jacobi on a dense 320x320 symmetric matrix with Haar-random
  eigenvectors and an evenly spread spectrum, one-sided Jacobi SVD of a
  400x260 matrix with prescribed singular values, and `cond` of a 200x360
  random matrix (the wide-matrix transpose path). Random orthogonal
  eigenvectors make every rotation matter, so the full number of sweeps runs;
  gaps and sign margins sit far inside the guarantees.
- `003_mixed_workload` — a 138-command script of the kind a user would run:
  every SuiteSparse corpus matrix (norms, solves, LU, Cholesky, QR, SVD, eig on
  the symmetrised or ramped variants), generated systems from 60 to 180 on a
  side (det, solve, inverse, Cholesky, least squares, `cond` of tall
  matrices), small and medium eig/SVD problems, every storage format, and
  eight commands that take the error paths. It measures per-command overhead
  (parsing, file writing, dispatch) together with mid-sized numerics.

The bench directory is about 31MB, mostly expected outputs: a 500x500 result
file is 4.4MB, because the `%.10e` format uses 17 bytes per value.

## Long tier

`python3 bench/gen_bench.py --long` writes `bench-long/` (fixed seeds 191001-193003; expected outputs from `reference/main.py`, about 96 minutes in total on a heavily loaded machine, 120 MB peak RSS). Matrix sizes stay within the 500 limit; the scripts are longer, and most added commands have small results (solves against narrow right-hand sides, determinants, condition numbers), so the expected trees stay modest:

- `001_dense_kernels_500` (569 commands): the short script on the first matrices, three more 500x500 products and two more inverses, then 85 rounds of solves of four 500x500 systems against fresh 500x2 right-hand sides, with least squares on two 500x250 matrices and Cholesky solves of two 350x350 SPD matrices every other round.
- `002_jacobi_spectral` (30 commands): cyclic Jacobi on Haar-random symmetric matrices of 320, 400, 500 and 500, one-sided Jacobi SVD of 400x260 and 500x320 matrices with prescribed singular values, and `cond` of 24 random 200x360 matrices.
- `003_mixed_workload` (662 commands): the whole short script (corpus matrices, generated systems, spectral problems, error paths), with a long middle section of 75 rounds that re-solve and re-fit three large systems (300, 400, 500; dense, coordinate SPD and n x n/2 fits) against fresh data, with `det`, `cond` and norms every tenth round and a new 150x150 eig and 180x150 SVD every twelfth.

The numpy oracle (`.oracle-venv` of the main checkout; the worktree has none, so `gen_bench.py` skipped it) was run on all three long cases afterwards and agrees with the reference within the verifier's tolerance (worst ratio 0.22 of the tolerance).

Measured on a heavily loaded 8-core M-series Mac (load average 70-190; CPU time is the reliable figure, wall time was 1.5-2x higher). Fastest per input: 001 Rust 7.7 s user (16.9 s wall; D 8.8 s, C++ 10.0 s, Go 15.0 s); 002 D 9.0 s user (C++ 9.6 s, Rust 10.9 s, Go 11.1 s); 003 D 8.9 s user (Rust 9.1 s, C++ 9.5 s, Go 14.5 s). Peak RSS is under 70 MB for every compiled build. `bench-long/` is 139 MB (inputs 45 MB; most of the rest is the 4.4 MB results of the eight 500x500 products and inverses). SPEC.md's command limit (200) is raised to 1000 for the long tier only.
