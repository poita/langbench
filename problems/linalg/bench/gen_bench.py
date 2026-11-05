#!/usr/bin/env python3
"""Generates the performance benchmark inputs bench/NNN_name/{input,expected}.

The layout matches tests/, so the suite runs with
`python3 run_tests.py linalg --tests-dir problems/linalg/bench -- <cmd>`.

Every matrix comes from a fixed-seed generator or from the SuiteSparse corpus
vendored in corpus/. Expected outputs are produced by reference/main.py and,
when the numpy oracle venv used by gen_tests.py exists, every case is
recomputed with numpy (LAPACK) and checked against the reference result with
the verifier's tolerance; the oracle also checks the spectral-gap, sign-margin
and pivot-tie guarantees of SPEC.md section 4.

Usage: python3 bench/gen_bench.py [--long] [--only N] [--no-oracle] [--no-ref]
"""
import argparse
import math
import operator
import os
import random
import shutil
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
PROBLEM = os.path.dirname(HERE)
sys.path.insert(0, PROBLEM)
sys.dont_write_bytecode = True  # keep problems/linalg/ free of __pycache__

import gen_tests as gt  # noqa: E402  (reuses the writers, corpus reader and oracle)

REF = gt.REF
ORACLE_PY = gt.ORACLE_PY
CORPUS = gt.CORPUS
REFERENCE_TIMEOUT = 900
LONG_REFERENCE_TIMEOUT = 3600

# Write values in their shortest round-tripping form; parsing it gives back
# the exact double, and the files stay much smaller than with "%.17g".
gt._num = repr


# ---------------------------------------------------------------------------
# Matrix constructors
# ---------------------------------------------------------------------------

def orthonormal_columns(rng, m, k):
    """k orthonormal columns of length m: modified Gram-Schmidt on a Gaussian
    matrix, i.e. the leading columns of a Haar-random orthogonal matrix."""
    cols = []
    for _ in range(k):
        v = [rng.gauss(0.0, 1.0) for _ in range(m)]
        for _pass in range(2):
            for q in cols:
                d = sum(map(operator.mul, q, v))
                v = [a - d * b for a, b in zip(v, q)]
        nrm = math.sqrt(sum(a * a for a in v))
        cols.append([a / nrm for a in v])
    return cols


def from_factors(left_cols, values, right_cols):
    """sum_l values[l] * left_cols[l] right_cols[l]^T as a dense row list."""
    m, n = len(left_cols[0]), len(right_cols[0])
    lrows = [[col[i] * w for col, w in zip(left_cols, values)] for i in range(m)]
    rrows = [[col[j] for col in right_cols] for j in range(n)]
    return [[sum(map(operator.mul, lrows[i], rrows[j])) for j in range(n)] for i in range(m)]


def symmetric_with_spectrum(rng, values):
    """Q diag(values) Q^T with Q Haar-random; exactly symmetrised."""
    n = len(values)
    Q = orthonormal_columns(rng, n, n)
    A = from_factors(Q, values, Q)
    for i in range(n):
        for j in range(i):
            s = (A[i][j] + A[j][i]) / 2.0
            A[i][j] = s
            A[j][i] = s
    return A


def with_singular_values(rng, m, n, sigmas):
    """U diag(sigmas) V^T with U (m x k) and V (n x k) Haar-random columns."""
    k = len(sigmas)
    U = orthonormal_columns(rng, m, k)
    V = orthonormal_columns(rng, n, k)
    return from_factors(U, sigmas, V)


def rounded(A, digits=10):
    """A with every entry rounded to `digits` significant digits, which keeps
    the input files compact; the rounded matrix is the benchmark input."""
    return [[float("%.*g" % (digits, v)) for v in row] for row in A]


def diag_dominant_spd(rng, n, digits=6):
    """Random symmetric matrix with a dominant positive diagonal (SPD by
    Gershgorin), like an assembled stiffness or covariance matrix."""
    A = [[0.0] * n for _ in range(n)]
    for i in range(n):
        for j in range(i):
            v = round(rng.uniform(-1.0, 1.0), digits)
            A[i][j] = v
            A[j][i] = v
    for i in range(n):
        A[i][i] = round(sum(abs(x) for x in A[i]) + rng.uniform(1.0, 5.0), digits)
    return A


# ---------------------------------------------------------------------------
# Cases
# ---------------------------------------------------------------------------

CASES = []


def case(name):
    c = gt.Case(name)
    CASES.append(c)
    return c


def build_dense_kernels():
    """001: O(n^3) kernels on 500x500 matrices, the largest size the spec allows."""
    c = case("dense_kernels_500")
    rng = random.Random(91001)
    n = 500
    # Entries in [-0.25, 0.25] keep det(A) (about 1e147) inside double range.
    A = c.array("a.mtx", gt.rand_matrix(rng, n, n, -0.25, 0.25, digits=4),
                comments=["500x500, entries uniform in [-0.25, 0.25]"])
    S = c.array("s.mtx", diag_dominant_spd(rng, 350, digits=4), symmetry="symmetric",
                comments=["350x350 symmetric, dominant positive diagonal"])
    R = c.array("rhs.mtx", gt.rand_matrix(rng, n, 16, digits=4))
    T = c.array("tall.mtx", gt.rand_matrix(rng, n, 250, digits=4))
    Y = c.array("obs.mtx", gt.rand_matrix(rng, n, 8, digits=4))
    c.cmd("mul", A, A)
    c.cmd("det", A)
    c.cmd("inv", A)
    c.cmd("solve", A, R)
    c.cmd("chol", S)
    c.cmd("solve", S, "s_rhs.mtx")
    c.array("s_rhs.mtx", gt.rand_matrix(rng, 350, 16, digits=4))
    c.cmd("lstsq", T, Y)
    c.cmd("norm1", A)
    c.cmd("norminf", S)
    c.cmd("normfro", T)


def build_spectral():
    """002: the Jacobi eigen- and singular-value solvers on large dense input."""
    c = case("jacobi_spectral")
    rng = random.Random(92002)
    n = 320
    # Indefinite spectrum, evenly spread with jitter: every gap is at least
    # 0.2 against a spread of about n, far above the 1e-4 guarantee.
    w = [i - n / 2.0 + rng.uniform(-0.4, 0.4) for i in range(n)]
    c.cmd("eig", c.array("sym.mtx", rounded(symmetric_with_spectrum(rng, w)),
                         symmetry="symmetric",
                         comments=["Q diag(w) Q^T, Q Haar-random, %d spread eigenvalues" % n]))
    m, k = 400, 260
    sig = [100.0 * (1.0 - 0.003 * i) for i in range(k)]
    c.cmd("svd", c.array("tall.mtx", rounded(with_singular_values(rng, m, k, sig)),
                         comments=["U diag(s) V^T, %dx%d, singular values 100 down to %.3g"
                                   % (m, k, sig[-1])]))
    c.cmd("cond", c.array("wide.mtx", gt.rand_matrix(rng, 200, 360, digits=4),
                          comments=["200x360, entries uniform in [-1, 1]"]))


def build_mixed(c=None, rng=None, extra=None):
    """003: a long script mixing every operation over corpus and generated
    matrices of moderate size, including the error paths."""
    if c is None:
        c = case("mixed_workload")
        rng = random.Random(93003)

    # SuiteSparse matrices, each used the way the public tests use it.
    bus = c.corpus("494_bus.mtx", "494_bus.mtx")
    bus_rhs = c.array("bus_rhs.mtx", [[1.0 / (1.0 + (i % 13)), float((i % 5) - 2)]
                                      for i in range(494)])
    steam = c.corpus("steam1.mtx", "steam1.mtx")
    steam_rhs = c.array("steam_rhs.mtx", [[float((i % 11) - 5)] for i in range(240)])
    lund = c.corpus("lund_a.mtx", "lund_a.mtx")
    lund_rhs = c.array("lund_rhs.mtx", [[math.cos(i * 0.5)] for i in range(147)])
    west = c.corpus("west0132.mtx", "west0132.mtx")
    fs = c.corpus("fs_183_1.mtx", "fs_183_1.mtx")
    fs_vec = c.array("fs_vec.mtx", [[1.0 / (i + 1.0)] for i in range(183)])
    gre = c.corpus("gre_115.mtx", "gre_115.mtx")
    nos = c.corpus("nos4.mtx", "nos4.mtx")
    nos_rhs = c.array("nos_rhs.mtx", [[1.0] for _ in range(100)])
    bk2 = c.corpus("bcsstk02.mtx", "bcsstk02.mtx")
    bk2_rhs = c.array("bk2_rhs.mtx", [[math.sin(i)] for i in range(66)])
    imp = c.corpus("impcol_b.mtx", "impcol_b.mtx")
    ibm = c.corpus("ibm32.mtx", "ibm32.mtx")
    can = c.corpus("can_24.mtx", "can_24.mtx")
    nos_full = gt.read_mm(os.path.join(CORPUS, "nos4.mtx"))
    gre_full = gt.read_mm(os.path.join(CORPUS, "gre_115.mtx"))
    nos_ramp = c.array("nos4_ramp.mtx", gt.diagonal_ramp(nos_full), symmetry="symmetric",
                       comments=["HB/nos4 with an increasing diagonal ramp added"])
    gre_sym = c.array("gre115_sym.mtx", gt.symmetric_part(gre_full), symmetry="symmetric",
                      comments=["symmetric part (A+A^T)/2 of HB/gre_115"])

    for M in (bus, steam, lund, west, fs, gre, nos, bk2, imp, ibm, can):
        c.cmd("norm1", M)
        c.cmd("norminf", M)
        c.cmd("normfro", M)
    c.cmd("solve", bus, bus_rhs)
    c.cmd("mul", bus, bus_rhs)
    c.cmd("solve", steam, steam_rhs)
    c.cmd("chol", lund)
    c.cmd("solve", lund, lund_rhs)
    c.cmd("lu", west)
    c.cmd("mul", west, west)
    c.cmd("mul", fs, fs_vec)
    c.cmd("det", gre)
    c.cmd("inv", gre)
    c.cmd("qr", gre)
    c.cmd("svd", gre)
    c.cmd("cond", gre)
    c.cmd("chol", nos)
    c.cmd("inv", nos)
    c.cmd("cond", nos)
    c.cmd("solve", nos, nos_rhs)
    c.cmd("eig", nos_ramp)
    c.cmd("eig", gre_sym)
    c.cmd("chol", bk2)
    c.cmd("det", bk2)
    c.cmd("inv", bk2)
    c.cmd("solve", bk2, bk2_rhs)
    c.cmd("qr", imp)
    c.cmd("inv", imp)
    c.cmd("svd", ibm)
    c.cmd("chol", can)

    # Generated linear systems of assorted sizes: the bread-and-butter calls
    # (factor, solve, invert, fit) a numerical script makes over and over.
    mixed_systems_and_spectra(c, rng)
    if extra is not None:
        extra(c, rng)
    mixed_errors(c, rng)


def mixed_systems_and_spectra(c, rng):
    """The generated-system and spectral parts of build_mixed."""
    for t, n in enumerate((60, 90, 120, 150, 180)):
        A = c.array("sys%d.mtx" % t, gt.rand_matrix(rng, n, n, digits=4))
        Bm = c.array("sys%d_rhs.mtx" % t, gt.rand_matrix(rng, n, 6, digits=4))
        S = c.coord("spd%d.mtx" % t, diag_dominant_spd(rng, n, digits=4), symmetry="symmetric")
        T = c.array("fit%d.mtx" % t, gt.rand_matrix(rng, 2 * n, n // 3, digits=4))
        Y = c.array("fit%d_y.mtx" % t, gt.rand_matrix(rng, 2 * n, 3, digits=4))
        c.cmd("det", A)
        c.cmd("solve", A, Bm)
        c.cmd("mul", A, Bm)
        c.cmd("solve", S, Bm)
        if n <= 90:
            c.cmd("inv", A)
            c.cmd("chol", S)
        c.cmd("lstsq", T, Y)
        c.cmd("cond", T)
        c.cmd("normfro", A)
        c.cmd("norm1", S)
        if n <= 90:
            c.cmd("lu", A)
            c.cmd("qr", T)
            c.cmd("add", A, S)
            c.cmd("transpose", T)

    # Small and medium spectral problems with well-separated spectra.
    for t, n in enumerate((40, 70, 100)):
        w = [1.0 + 2.0 * i + rng.uniform(-0.5, 0.5) for i in range(n)]
        E = c.array("eig%d.mtx" % t, rounded(symmetric_with_spectrum(rng, w)),
                    symmetry="symmetric")
        c.cmd("eig", E)
        c.cmd("chol", E)
        c.cmd("cond", E)
        m = n + 30
        sig = [5.0 * (1.0 - 0.8 * i / n) for i in range(n)]
        G = c.array("svd%d.mtx" % t, rounded(with_singular_values(rng, m, n, sig)))
        c.cmd("svd", G)
        c.cmd("svd", c.array("svd%d_wide.mtx" % t, rounded(with_singular_values(rng, n, m, sig))))
        c.cmd("lstsq", G, c.array("svd%d_y.mtx" % t, gt.rand_matrix(rng, m, 2, digits=4)))


def mixed_errors(c, rng):
    # The error paths a real script also hits.
    K = c.array("rect.mtx", gt.rand_matrix(rng, 60, 90, digits=4))
    D = gt.rand_matrix(rng, 90, 90, digits=4)
    D[50] = list(D[10])
    D = c.array("dup_row.mtx", D, comments=["row 51 repeats row 11, so exactly singular"])
    D_rhs = c.array("dup_rhs.mtx", gt.rand_matrix(rng, 90, 1, digits=4))
    c.cmd("chol", K)
    c.cmd("eig", "sys1.mtx")
    c.cmd("mul", K, K)
    c.cmd("solve", D, D_rhs)
    c.cmd("inv", D)
    c.cmd("lstsq", K, D_rhs)
    c.cmd("chol", "sys0.mtx")
    c.cmd("solve", K, D_rhs)


# ---------------------------------------------------------------------------
# Long tier (bench-long/): the same three workloads with many more commands.
# Matrix sizes stay within the 500 limit; only the script length grows past
# 200 commands. Most of the added commands have small results (solves against
# narrow right-hand sides, determinants, condition numbers), so the expected
# output stays modest while the compute grows.
# ---------------------------------------------------------------------------

LONG_DIR = os.path.join(PROBLEM, "bench-long")


def build_dense_kernels_long():
    """001: the short script, then repeated LU, QR and Cholesky work on several
    500x500, 500x250 and 350x350 matrices against many right-hand sides."""
    c = case("dense_kernels_500")
    rng = random.Random(191001)
    n = 500
    As = [c.array("a%d.mtx" % i, gt.rand_matrix(rng, n, n, -0.25, 0.25, digits=4),
                  comments=["500x500, entries uniform in [-0.25, 0.25]"]) for i in range(4)]
    Ss = [c.array("s%d.mtx" % i, diag_dominant_spd(rng, 350, digits=4), symmetry="symmetric",
                  comments=["350x350 symmetric, dominant positive diagonal"]) for i in range(2)]
    Ts = [c.array("tall%d.mtx" % i, gt.rand_matrix(rng, n, 250, digits=4)) for i in range(2)]
    R = c.array("rhs.mtx", gt.rand_matrix(rng, n, 16, digits=4))
    Y = c.array("obs.mtx", gt.rand_matrix(rng, n, 8, digits=4))
    c.array("s_rhs.mtx", gt.rand_matrix(rng, 350, 16, digits=4))
    # The short script on the first matrices.
    c.cmd("mul", As[0], As[0])
    c.cmd("det", As[0])
    c.cmd("inv", As[0])
    c.cmd("solve", As[0], R)
    c.cmd("chol", Ss[0])
    c.cmd("solve", Ss[0], "s_rhs.mtx")
    c.cmd("lstsq", Ts[0], Y)
    c.cmd("norm1", As[0])
    c.cmd("norminf", Ss[0])
    c.cmd("normfro", Ts[0])
    # Then many solves and fits, as a script sweeping over load cases would.
    for i in range(1, 4):
        c.cmd("mul", As[i - 1], As[i])
    for i in range(1, 3):
        c.cmd("inv", As[i])
    for k in range(LONG_DENSE_ROUNDS):
        for i, A in enumerate(As):
            if k == 0:
                c.cmd("det", A)
            c.cmd("solve", A, c.array("b%d_%d.mtx" % (i, k), gt.rand_matrix(rng, n, 2, digits=4)))
        if k % 2 == 0:
            for j, T in enumerate(Ts):
                c.cmd("lstsq", T, c.array("y%d_%d.mtx" % (j, k), gt.rand_matrix(rng, n, 2, digits=4)))
            for j, S in enumerate(Ss):
                if k == 0:
                    c.cmd("chol", S)
                c.cmd("solve", S, c.array("sb%d_%d.mtx" % (j, k), gt.rand_matrix(rng, 350, 2, digits=4)))
        if k % 10 == 0:
            for A in As:
                c.cmd("norm1", A)


LONG_DENSE_ROUNDS = 85


def build_spectral_long():
    """002: Jacobi eigen- and singular-value solves on several large dense
    matrices, plus condition numbers of wide matrices."""
    c = case("jacobi_spectral")
    rng = random.Random(192002)
    for t, n in enumerate(LONG_EIG_SIZES):
        w = [i - n / 2.0 + rng.uniform(-0.4, 0.4) for i in range(n)]
        c.cmd("eig", c.array("sym%d.mtx" % t, rounded(symmetric_with_spectrum(rng, w)),
                             symmetry="symmetric",
                             comments=["Q diag(w) Q^T, Q Haar-random, %d spread eigenvalues" % n]))
    for t, (m, k) in enumerate(LONG_SVD_SHAPES):
        sig = [100.0 * (1.0 - 0.003 * i) for i in range(k)]
        c.cmd("svd", c.array("tall%d.mtx" % t, rounded(with_singular_values(rng, m, k, sig)),
                             comments=["U diag(s) V^T, %dx%d, singular values 100 down to %.3g"
                                       % (m, k, sig[-1])]))
    for t in range(LONG_COND_COUNT):
        c.cmd("cond", c.array("wide%d.mtx" % t, gt.rand_matrix(rng, 200, 360, digits=4),
                              comments=["200x360, entries uniform in [-1, 1]"]))


LONG_EIG_SIZES = (320, 400, 500, 500)
LONG_SVD_SHAPES = ((400, 260), (500, 320))
LONG_COND_COUNT = 24


def build_mixed_long():
    """003: the short mixed script with a long middle section: three large
    systems that are solved and fitted again and again against new data, with
    determinants, condition numbers and norms along the way, and a fresh
    medium eig/SVD problem every few rounds."""
    c = case("mixed_workload")
    rng = random.Random(193003)
    build_mixed(c, rng, extra=mixed_long_rounds)


def mixed_long_rounds(c, rng):
    big = []
    for t, n in enumerate((300, 400, 500)):
        # Entries in [-0.25, 0.25] keep det(A) inside double range.
        A = c.array("big%d.mtx" % t, gt.rand_matrix(rng, n, n, -0.25, 0.25, digits=4))
        S = c.coord("bigspd%d.mtx" % t, diag_dominant_spd(rng, n, digits=4), symmetry="symmetric")
        T = c.array("bigfit%d.mtx" % t, gt.rand_matrix(rng, n, n // 2, digits=4))
        big.append((n, A, S, T))
    for r in range(LONG_MIXED_ROUNDS):
        for t, (n, A, S, T) in enumerate(big):
            c.cmd("solve", A, c.array("big%d_b%d.mtx" % (t, r), gt.rand_matrix(rng, n, 2, digits=4)))
            if r % 3 == t:
                c.cmd("solve", S, c.array("big%d_sb%d.mtx" % (t, r), gt.rand_matrix(rng, n, 2, digits=4)))
            if r % 2 == 0:
                c.cmd("lstsq", T, c.array("big%d_y%d.mtx" % (t, r), gt.rand_matrix(rng, n, 2, digits=4)))
            if r % 10 == t:
                c.cmd("det", A)
                c.cmd("cond", T)
                c.cmd("norm1", S)
                c.cmd("normfro", A)
        if r % 12 == 0:
            n = 150
            w = [1.0 + 2.0 * i + rng.uniform(-0.5, 0.5) for i in range(n)]
            c.cmd("eig", c.array("r%d_eig.mtx" % r, rounded(symmetric_with_spectrum(rng, w)),
                                 symmetry="symmetric"))
            sig = [5.0 * (1.0 - 0.8 * i / n) for i in range(n)]
            c.cmd("svd", c.array("r%d_svd.mtx" % r, rounded(with_singular_values(rng, n + 30, n, sig))))


LONG_MIXED_ROUNDS = 75


# ---------------------------------------------------------------------------
# Generation
# ---------------------------------------------------------------------------

def write_case(number, c, base=HERE):
    case_dir = os.path.join(base, "%03d_%s" % (number, c.name))
    if os.path.isdir(case_dir):
        shutil.rmtree(case_dir)
    in_dir = os.path.join(case_dir, "input")
    out_dir = os.path.join(case_dir, "expected")
    os.makedirs(in_dir)
    os.makedirs(out_dir)
    for name, text in c.files.items():
        with open(os.path.join(in_dir, name), "w", encoding="utf-8") as f:
            f.write(text)
    script = "".join(l + "\n" for l in c.commands)
    with open(os.path.join(in_dir, "commands.txt"), "w", encoding="utf-8") as f:
        f.write(script)
    return case_dir, in_dir, out_dir


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", type=int, action="append", help="case number(s) to regenerate")
    ap.add_argument("--no-oracle", action="store_true", help="skip the numpy cross-check")
    ap.add_argument("--long", action="store_true", help="write the long tier to ../bench-long")
    ap.add_argument("--no-ref", action="store_true", help="write the inputs only")
    args = ap.parse_args()

    if args.long:
        builders = [build_dense_kernels_long, build_spectral_long, build_mixed_long]
        base = LONG_DIR
    else:
        builders = [build_dense_kernels, build_spectral, build_mixed]
        base = HERE
    os.makedirs(base, exist_ok=True)
    shutil.copyfile(os.path.join(CORPUS, "LICENSE"), os.path.join(base, "CORPUS_LICENSE"))
    shutil.copyfile(os.path.join(CORPUS, "LICENSE-CC-BY-4.0.txt"),
                    os.path.join(base, "LICENSE-CC-BY-4.0.txt"))
    scratch = tempfile.TemporaryDirectory(prefix="linalg_bench_oracle_")
    oracle = os.path.join(scratch.name, "oracle.py")
    with open(oracle, "w", encoding="utf-8") as f:
        f.write(gt.ORACLE_SOURCE)
    use_oracle = not args.no_oracle and os.path.exists(ORACLE_PY)

    failures = 0
    for number, build in enumerate(builders, 1):
        if args.only and number not in args.only:
            continue
        t0 = time.time()
        build()
        c = CASES[-1]
        case_dir, in_dir, out_dir = write_case(number, c, base)
        t1 = time.time()
        if args.no_ref:
            print("%03d_%s: %d cmds, inputs only (gen %.0fs)" % (number, c.name, len(c.commands), t1 - t0))
            continue
        proc = subprocess.run([sys.executable, REF, in_dir, out_dir],
                              capture_output=True, text=True,
                              timeout=LONG_REFERENCE_TIMEOUT if args.long else REFERENCE_TIMEOUT)
        t2 = time.time()
        if proc.returncode != 0:
            print("%s: reference failed: %s" % (c.name, proc.stderr.strip()[:400]))
            failures += 1
            continue
        status, detail = "ok ", "oracle skipped"
        if use_oracle:
            check = subprocess.run([ORACLE_PY, oracle, in_dir, out_dir],
                                   capture_output=True, text=True)
            detail = check.stdout.strip().replace("\n", " | ")[:300]
            if check.returncode != 0:
                status = "BAD"
                failures += 1
        size = sum(os.path.getsize(os.path.join(dp, fn))
                   for dp, _, fns in os.walk(case_dir) for fn in fns)
        print("%s %03d_%-20s %3d cmds %8.1f kB  gen %.0fs  ref %.0fs  %s"
              % (status, number, c.name, len(c.commands), size / 1024.0,
                 t1 - t0, t2 - t1, detail))
    if failures:
        print("\n%d case(s) failed; the benchmark is NOT valid" % failures)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
