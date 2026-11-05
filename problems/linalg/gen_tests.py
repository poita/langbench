#!/usr/bin/env python3
"""Generates tests/NNN_name/{input,expected} for the `linalg` problem.

Every case is either hand written, the product of a seeded generator, or a
matrix vendored from the SuiteSparse Matrix Collection under corpus/.
Expected outputs come from reference/main.py and are then cross-checked
against numpy (LAPACK) running in the oracle venv: each command is recomputed
with numpy, normalised the way SPEC.md prescribes, and compared to the
reference result with exactly the tolerance verify.py uses. Any disagreement,
any non-finite number, or any unexpected result file aborts generation.

Usage: python3 gen_tests.py
"""
import math
import os
import random
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.join(HERE, "tests")
CORPUS = os.path.join(HERE, "corpus")
REF = os.path.join(HERE, "reference", "main.py")
ORACLE_PY = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".oracle-venv", "bin", "python")

# ---------------------------------------------------------------------------
# Matrix Market writers
# ---------------------------------------------------------------------------


def _num(v):
    return "%.17g" % v


def mm_array(A, symmetry="general", comments=()):
    """Serialise a dense matrix in Matrix Market array format."""
    m, n = len(A), len(A[0])
    out = ["%%MatrixMarket matrix array real " + symmetry]
    out += ["%% " + c for c in comments]
    out.append("%d %d" % (m, n))
    for j in range(n):
        for i in range(m):
            if symmetry == "symmetric" and i < j:
                continue
            if symmetry == "skew-symmetric" and i <= j:
                continue
            out.append(_num(A[i][j]))
    return "\n".join(out) + "\n"


def mm_coordinate(A, symmetry="general", field="real", comments=()):
    """Serialise a dense matrix in Matrix Market coordinate format."""
    m, n = len(A), len(A[0])
    entries = []
    for j in range(n):
        for i in range(m):
            if symmetry == "symmetric" and i < j:
                continue
            if symmetry == "skew-symmetric" and i <= j:
                continue
            v = A[i][j]
            if v == 0.0:
                continue
            if field == "pattern":
                entries.append("%d %d" % (i + 1, j + 1))
            else:
                entries.append("%d %d %s" % (i + 1, j + 1, _num(v)))
    out = ["%%MatrixMarket matrix coordinate " + field + " " + symmetry]
    out += ["%% " + c for c in comments]
    out.append("%d %d %d" % (m, n, len(entries)))
    out += entries
    return "\n".join(out) + "\n"


# ---------------------------------------------------------------------------
# Matrix Market reader, used to load the vendored corpus
# ---------------------------------------------------------------------------

def read_mm(path):
    with open(path, "r", encoding="utf-8") as f:
        text = f.read()
    lines = text.split("\n")
    banner = lines[0].split()
    fmt, field, symmetry = banner[2].lower(), banner[3].lower(), banner[4].lower()
    body = [l.strip() for l in lines[1:] if l.strip() and not l.strip().startswith("%")]
    size = body[0].split()
    rows, cols = int(size[0]), int(size[1])
    A = [[0.0] * cols for _ in range(rows)]
    rest = body[1:]
    if fmt == "coordinate":
        for k in range(int(size[2])):
            parts = rest[k].split()
            i, j = int(parts[0]) - 1, int(parts[1]) - 1
            v = 1.0 if field == "pattern" else float(parts[2])
            A[i][j] = v
            if i != j:
                if symmetry == "symmetric":
                    A[j][i] = v
                elif symmetry == "skew-symmetric":
                    A[j][i] = -v
    else:
        it = iter(rest)
        for j in range(cols):
            for i in range(rows):
                if symmetry == "symmetric" and i < j:
                    continue
                if symmetry == "skew-symmetric" and i <= j:
                    continue
                v = float(next(it))
                A[i][j] = v
                if i != j:
                    if symmetry == "symmetric":
                        A[j][i] = v
                    elif symmetry == "skew-symmetric":
                        A[j][i] = -v
    return A


# ---------------------------------------------------------------------------
# Matrix constructors
# ---------------------------------------------------------------------------

def rand_matrix(rng, m, n, lo=-1.0, hi=1.0, digits=6):
    return [[round(rng.uniform(lo, hi), digits) for _ in range(n)] for _ in range(m)]


def spd_matrix(rng, n, digits=6):
    """B^T B + n I with B random; symmetric positive definite by construction."""
    B = rand_matrix(rng, n, n, digits=digits)
    A = [[0.0] * n for _ in range(n)]
    for i in range(n):
        for j in range(i, n):
            s = sum(B[k][i] * B[k][j] for k in range(n))
            if i == j:
                s += n
            A[i][j] = s
            A[j][i] = s
    return A


def hilbert(n):
    return [[1.0 / (i + j + 1) for j in range(n)] for i in range(n)]


def vandermonde(nodes, n):
    return [[x ** j for j in range(n)] for x in nodes]


def diag(values):
    n = len(values)
    A = [[0.0] * n for _ in range(n)]
    for i, v in enumerate(values):
        A[i][i] = v
    return A


def symmetric_part(A):
    n = len(A)
    return [[(A[i][j] + A[j][i]) / 2.0 for j in range(n)] for i in range(n)]


def diagonal_ramp(A, factor=1e-3):
    """A with a strictly increasing diagonal ramp added.

    The ramp removes the exact symmetry of a mesh matrix, whose eigenvectors
    otherwise have several components of identical magnitude and therefore no
    unique sign normalisation.
    """
    n = len(A)
    scale = max(abs(v) for row in A for v in row) * factor
    B = [row[:] for row in A]
    for i in range(n):
        B[i][i] += (i + 1) * scale
    return B


def submatrix(A, rows, cols):
    return [row[:cols] for row in A[:rows]]


def transpose(A):
    return [list(col) for col in zip(*A)]


# ---------------------------------------------------------------------------
# Case assembly
# ---------------------------------------------------------------------------

class Case:
    def __init__(self, name):
        self.name = name
        self.files = {}
        self.commands = []
        self.script = None

    def matrix(self, filename, text):
        self.files[filename] = text
        return filename

    def array(self, filename, A, symmetry="general", comments=()):
        return self.matrix(filename, mm_array(A, symmetry, comments))

    def coord(self, filename, A, symmetry="general", field="real", comments=()):
        return self.matrix(filename, mm_coordinate(A, symmetry, field, comments))

    def corpus(self, filename, source):
        with open(os.path.join(CORPUS, source), "r", encoding="utf-8") as f:
            self.files[filename] = f.read()
        return filename

    def cmd(self, *parts):
        self.commands.append(" ".join(parts))


CASES = []


def case(name):
    c = Case(name)
    CASES.append(c)
    return c


# --- 001: addition and transpose -------------------------------------------
c = case("add_transpose")
A = c.array("a.mtx", [[1.0, 2.0], [3.0, 4.0]])
B = c.array("b.mtx", [[0.5, -2.0], [1.25, 0.0]])
C = c.array("c.mtx", [[1.0, 0.0, -3.5], [2.0, 8.0, 0.25]])
c.cmd("add", A, B)
c.cmd("add", C, C)
c.cmd("transpose", C)
c.cmd("transpose", A)
c.cmd("transpose", c.array("row.mtx", [[7.0, -7.0, 0.0, 1.5]]))

# --- 002: multiplication ----------------------------------------------------
c = case("multiply")
A = c.array("a.mtx", [[1.0, 2.0, 3.0], [4.0, 5.0, 6.0]])
B = c.array("b.mtx", [[1.0, 0.0], [0.0, 1.0], [-1.0, 2.0]])
I3 = c.array("i3.mtx", diag([1.0, 1.0, 1.0]))
Z = c.array("z.mtx", [[0.0, 0.0, 0.0], [0.0, 0.0, 0.0]])
c.cmd("mul", A, B)
c.cmd("mul", B, A)
c.cmd("mul", A, I3)
c.cmd("mul", I3, B)
c.cmd("mul", Z, I3)
c.cmd("mul", c.array("col.mtx", [[2.0], [3.0]]), c.array("rowv.mtx", [[5.0, 7.0]]))

# --- 003: norms -------------------------------------------------------------
c = case("norms")
A = c.array("a.mtx", [[1.0, -2.0, 3.0, -4.0], [5.0, 6.0, -7.0, 8.0], [0.0, 0.0, 0.0, 0.0]])
Z = c.array("z.mtx", [[0.0, 0.0], [0.0, 0.0]])
V = c.array("v.mtx", [[3.0], [-4.0], [12.0]])
for m in (A, Z, V):
    c.cmd("norm1", m)
    c.cmd("norminf", m)
    c.cmd("normfro", m)

# --- 004: determinants ------------------------------------------------------
c = case("determinant")
c.cmd("det", c.array("d1.mtx", [[-3.5]]))
c.cmd("det", c.array("d2.mtx", [[1.0, 2.0], [3.0, 4.0]]))
c.cmd("det", c.array("d3.mtx", [[6.0, 1.0, 1.0], [4.0, -2.0, 5.0], [2.0, 8.0, 7.0]]))
c.cmd("det", c.array("tri.mtx", [[2.0, 9.0, -1.0, 4.0], [0.0, -3.0, 5.0, 1.0],
                                 [0.0, 0.0, 0.5, 8.0], [0.0, 0.0, 0.0, -4.0]]))
c.cmd("det", c.array("sing.mtx", [[1.0, 2.0], [2.0, 4.0]]))
c.cmd("det", c.array("zerocol.mtx", [[1.0, 0.0, 2.0], [3.0, 0.0, 4.0], [5.0, 0.0, 6.0]]))
c.cmd("det", c.array("ident.mtx", diag([1.0] * 5)))

# --- 005: linear solve ------------------------------------------------------
c = case("solve_small")
A = c.array("a.mtx", [[2.0, 1.0, -1.0], [-3.0, -1.0, 2.0], [-2.0, 1.0, 2.0]])
c.cmd("solve", A, c.array("b1.mtx", [[8.0], [-11.0], [-3.0]]))
c.cmd("solve", A, c.array("b3.mtx", [[1.0, 0.0, 2.0], [0.0, 1.0, -1.0], [0.0, 0.0, 3.0]]))
c.cmd("solve", c.array("d.mtx", diag([4.0, -2.0, 0.5])), c.array("b2.mtx", [[1.0], [1.0], [1.0]]))

# --- 006: inverse -----------------------------------------------------------
c = case("inverse")
c.cmd("inv", c.array("a.mtx", [[4.0, 7.0], [2.0, 6.0]]))
c.cmd("inv", c.array("b.mtx", [[1.0, 2.0, 3.0], [0.0, 1.0, 4.0], [5.0, 6.0, 0.0]]))
c.cmd("inv", c.array("d.mtx", diag([2.0, -0.25, 8.0, 1.0])))
c.cmd("inv", c.array("p.mtx", [[0.0, 1.0, 0.0], [0.0, 0.0, 1.0], [1.0, 0.0, 0.0]]))

# --- 007: LU with pivoting --------------------------------------------------
c = case("lu_pivoting")
c.cmd("lu", c.array("swap.mtx", [[0.0, 2.0, 1.0], [1.0, 0.0, 3.0], [4.0, 1.0, 0.0]]))
c.cmd("lu", c.array("dominant.mtx", [[10.0, 1.0, 2.0], [1.0, 8.0, -1.0], [0.0, 2.0, 6.0]]))
c.cmd("lu", c.array("two.mtx", [[1.0, 2.0], [3.0, 4.0]]))
c.cmd("lu", c.array("one.mtx", [[-6.0]]))
c.cmd("lu", c.array("wide.mtx", [[1.0, 2.0, 3.0, 4.0], [4.0, 3.0, 2.0, 1.0],
                                 [1.0, 0.0, 0.0, 2.0], [0.0, 5.0, 1.0, 0.0]]))

# --- 008: Cholesky ----------------------------------------------------------
c = case("cholesky")
S3 = c.array("s3.mtx", [[4.0, 12.0, -16.0], [12.0, 37.0, -43.0], [-16.0, -43.0, 98.0]])
c.cmd("chol", S3)
c.cmd("det", S3)
c.cmd("inv", S3)
c.cmd("chol", c.array("s1.mtx", [[9.0]]))
c.cmd("chol", c.array("d.mtx", diag([1.0, 4.0, 9.0, 16.0])))
rng = random.Random(1001)
c.cmd("chol", c.array("s5.mtx", spd_matrix(rng, 5), symmetry="symmetric"))

# --- 009: Householder QR ----------------------------------------------------
c = case("qr_small")
c.cmd("qr", c.array("tall.mtx", [[1.0, 2.0], [3.0, 4.0], [5.0, 6.0], [7.0, 9.0], [2.0, -1.0]]))
c.cmd("qr", c.array("square.mtx", [[12.0, -51.0, 4.0], [6.0, 167.0, -68.0], [-4.0, 24.0, -41.0]]))
c.cmd("qr", c.array("col.mtx", [[3.0], [4.0]]))
c.cmd("qr", c.array("one.mtx", [[-2.0]]))
c.cmd("qr", c.array("neg.mtx", [[-1.0, 2.0], [0.0, -3.0]]))

# --- 010: symmetric eigendecomposition --------------------------------------
c = case("eig_small")
c.cmd("eig", c.array("d.mtx", diag([3.0, -1.0, 7.0])))
c.cmd("eig", c.array("s2.mtx", [[2.0, 1.0], [1.0, 3.0]]))
c.cmd("eig", c.array("s3.mtx", [[6.0, 2.0, 1.0], [2.0, 5.0, -1.0], [1.0, -1.0, 4.5]]))
c.cmd("eig", c.array("one.mtx", [[-4.25]]))
c.cmd("eig", c.array("s4.mtx", [[10.0, 1.0, 0.5, 0.25], [1.0, 7.0, 0.75, -0.5],
                                [0.5, 0.75, 4.0, 1.5], [0.25, -0.5, 1.5, 1.0]]))

# --- 011: SVD ---------------------------------------------------------------
c = case("svd_small")
c.cmd("svd", c.array("tall.mtx", [[1.0, 2.0], [3.0, 4.0], [5.0, 7.0], [2.0, -1.0]]))
c.cmd("svd", c.array("wide.mtx", [[1.0, 3.0, 5.0, 2.0], [2.0, 4.0, 7.0, -1.0]]))
c.cmd("svd", c.array("sq.mtx", [[4.0, 0.0, 1.0], [0.0, 3.0, -2.0], [1.0, -2.0, 6.5]]))
c.cmd("svd", c.array("col.mtx", [[3.0], [-4.0], [12.0]]))
c.cmd("svd", c.array("one.mtx", [[-5.0]]))

# --- 012: least squares -----------------------------------------------------
c = case("least_squares")
nodes = [0.0, 1.0, 2.0, 3.0, 4.0, 5.0]
A = c.array("vand.mtx", vandermonde(nodes, 3))
c.cmd("lstsq", A, c.array("y.mtx", [[1.0], [2.5], [3.9], [7.1], [11.8], [18.2]]))
c.cmd("lstsq", A, c.array("y2.mtx", [[1.0, 0.0], [2.5, 1.0], [3.9, 4.0],
                                     [7.1, 9.0], [11.8, 16.0], [18.2, 25.0]]))
c.cmd("lstsq", c.array("sq.mtx", [[2.0, 1.0], [1.0, 3.0]]), c.array("b.mtx", [[5.0], [10.0]]))
c.cmd("qr", A)

# --- 013: condition numbers -------------------------------------------------
c = case("condition")
c.cmd("cond", c.array("i.mtx", diag([1.0] * 4)))
c.cmd("cond", c.array("d.mtx", diag([1.0, 10.0, 100.0, 1000.0])))
c.cmd("cond", c.array("a.mtx", [[1.0, 2.0], [3.0, 4.0]]))
c.cmd("cond", c.array("tall.mtx", [[1.0, 0.0], [0.0, 2.0], [0.0, 0.0]]))
c.cmd("cond", c.array("wide.mtx", [[2.0, 0.0, 0.0], [0.0, 0.5, 0.0]]))

# --- 014: array storage variants --------------------------------------------
c = case("format_array")
rng = random.Random(2002)
S = spd_matrix(rng, 6)
c.cmd("chol", c.array("sym.mtx", S, symmetry="symmetric", comments=["lower triangle only"]))
c.cmd("eig", "sym.mtx")
c.cmd("add", "sym.mtx", c.array("gen.mtx", S))
G = rand_matrix(rng, 4, 3)
c.cmd("mul", c.array("g.mtx", G), c.array("gt.mtx", transpose(G)))
c.cmd("normfro", "g.mtx")
# an "integer" field file: same storage rules, values written without a point
c.matrix("intsym.mtx",
         "%%MatrixMarket matrix array integer symmetric\n"
         "% lower triangle of a small SPD matrix, integer field\n"
         "3 3\n4\n1\n2\n5\n-1\n6\n")
c.cmd("chol", "intsym.mtx")
c.cmd("eig", "intsym.mtx")

# --- 015: coordinate storage variants ---------------------------------------
c = case("format_coordinate")
rng = random.Random(3003)
S = spd_matrix(rng, 5)
c.cmd("chol", c.coord("sym.mtx", S, symmetry="symmetric"))
c.cmd("norm1", "sym.mtx")
P = [[1.0 if (i * 7 + j * 3) % 5 == 0 else 0.0 for j in range(6)] for i in range(6)]
c.cmd("mul", c.coord("pat.mtx", P, field="pattern"), c.coord("pat2.mtx", P, field="pattern"))
c.cmd("norminf", "pat.mtx")
c.cmd("transpose", "pat.mtx")
Q = [[0.0] * 5 for _ in range(5)]
for i in range(5):
    for j in range(5):
        if i != j and (i + j) % 2 == 0:
            Q[i][j] = 1.0
c.cmd("mul", c.coord("psym.mtx", Q, symmetry="symmetric", field="pattern"), "psym.mtx")
c.cmd("det", "psym.mtx")
c.cmd("normfro", "psym.mtx")
c.matrix("int.mtx",
         "%%MatrixMarket matrix coordinate integer general\n"
         "% integer field, entries in no particular order\n"
         "3 3 5\n3 1 7\n1 3 2\n2 2 -3\n3 3 6\n1 1 4\n")
c.cmd("det", "int.mtx")
c.cmd("mul", "int.mtx", "int.mtx")

# --- 016: skew-symmetric storage --------------------------------------------
c = case("format_skew")
K = [[0.0, 2.0, -3.0, 1.0], [-2.0, 0.0, 4.0, -5.0], [3.0, -4.0, 0.0, 6.0], [-1.0, 5.0, -6.0, 0.0]]
c.cmd("transpose", c.coord("k.mtx", K, symmetry="skew-symmetric"))
c.cmd("add", "k.mtx", c.array("kt.mtx", transpose(K)))
c.cmd("mul", "k.mtx", "k.mtx")
c.cmd("norm1", "k.mtx")
c.cmd("normfro", c.array("ka.mtx", K, symmetry="skew-symmetric"))
c.cmd("det", "k.mtx")

# --- 017: comments, blank lines and odd spacing ------------------------------
c = case("script_formatting")
A = c.array("a.mtx", [[2.0, 0.5], [1.0, 3.0]], comments=["a small matrix", "two comment lines"])
B = c.coord("b.mtx", [[1.0, 0.0], [0.0, 4.0]], comments=["sparse", "with", "comments"])
c.script = (
    "# leading comment\n"
    "\n"
    "   add a.mtx b.mtx   \n"
    "\n"
    "#mul a.mtx b.mtx\n"
    "mul\ta.mtx\tb.mtx\n"
    "   \n"
    "  # indented comment\n"
    "norm1    a.mtx\n"
    "det a.mtx\n"
)
c.commands = ["add a.mtx b.mtx", "mul a.mtx b.mtx", "norm1 a.mtx", "det a.mtx"]

# --- 018: error reporting ----------------------------------------------------
c = case("errors")
r23 = c.array("r23.mtx", [[1.0, 2.0, 3.0], [4.0, 5.0, 6.0]])
r32 = c.array("r32.mtx", [[1.0, 2.0], [3.0, 4.0], [5.0, 6.0]])
sq3 = c.array("sq3.mtx", [[1.0, 2.0, 0.0], [0.0, 1.0, 3.0], [4.0, 0.0, 1.0]])
sing = c.array("sing.mtx", [[1.0, 2.0], [2.0, 4.0]])
zerocol = c.array("zerocol.mtx", [[1.0, 0.0], [3.0, 0.0]])
indef = c.array("indef.mtx", [[1.0, 2.0], [2.0, 1.0]])
zero2 = c.array("zero2.mtx", [[0.0, 0.0], [0.0, 0.0]])
b2 = c.array("b2.mtx", [[1.0], [2.0]])
c.cmd("add", r23, r32)
c.cmd("mul", r23, r23)
c.cmd("det", r23)
c.cmd("inv", r23)
c.cmd("lu", r32)
c.cmd("chol", r23)
c.cmd("eig", r23)
c.cmd("chol", sq3)
c.cmd("eig", sq3)
c.cmd("chol", indef)
c.cmd("chol", zero2)
c.cmd("inv", sing)
c.cmd("solve", sing, b2)
c.cmd("lu", zerocol)
c.cmd("inv", zerocol)
c.cmd("solve", sq3, b2)
c.cmd("qr", r23)
c.cmd("lstsq", r23, b2)
c.cmd("lstsq", r32, b2)
c.cmd("cond", zero2)
c.cmd("det", sing)
c.cmd("det", zerocol)
# A is non-square AND B has the wrong number of rows: section 5 fixes the
# precedence, so this must be not_square rather than dimension_mismatch.
c.cmd("solve", r23, c.array("b3r.mtx", [[1.0], [2.0], [3.0]]))
# QR of a rank-deficient matrix: the second Householder step sees a zero
# column (section 3.6 step 1), so R's diagonal holds an exact 0.0 and lstsq
# reports singular while qr itself succeeds.
lowrank = c.array("lowrank.mtx", [[1.0, 1.0], [0.0, 0.0]])
c.cmd("lstsq", lowrank, b2)
c.cmd("qr", lowrank)

# --- 019: one-element and vector shapes --------------------------------------
c = case("edge_shapes")
one = c.array("one.mtx", [[2.5]])
col = c.array("col.mtx", [[1.0], [-2.0], [3.0]])
row = c.array("row.mtx", [[0.5, -1.5, 2.5]])
c.cmd("inv", one)
c.cmd("det", one)
c.cmd("lu", one)
c.cmd("chol", c.array("pos.mtx", [[16.0]]))
c.cmd("eig", one)
c.cmd("svd", one)
c.cmd("qr", one)
c.cmd("cond", one)
c.cmd("solve", one, c.array("rhs.mtx", [[5.0]]))
c.cmd("svd", col)
c.cmd("svd", row)
c.cmd("qr", col)
c.cmd("lstsq", col, c.array("b3.mtx", [[1.0], [2.0], [3.0]]))
c.cmd("norm1", row)
c.cmd("norminf", col)
c.cmd("transpose", row)
c.cmd("mul", row, col)
c.cmd("mul", col, row)

# --- 020: Hilbert matrices ---------------------------------------------------
c = case("hilbert")
H4 = c.array("h4.mtx", hilbert(4), symmetry="symmetric")
H5 = c.array("h5.mtx", hilbert(5), symmetry="symmetric")
H6 = c.array("h6.mtx", hilbert(6), symmetry="symmetric")
c.cmd("inv", H4)
c.cmd("det", H4)
c.cmd("cond", H4)
c.cmd("chol", H4)
c.cmd("eig", H4)
c.cmd("inv", H5)
c.cmd("det", H5)
c.cmd("cond", H5)
c.cmd("solve", H5, c.array("ones5.mtx", [[1.0]] * 5))
c.cmd("det", H6)
c.cmd("cond", H6)
c.cmd("normfro", H6)
c.cmd("chol", H5)
c.cmd("norm1", H6)

# --- 021: Vandermonde matrices -----------------------------------------------
c = case("vandermonde")
nodes6 = [-1.0, -0.6, -0.2, 0.2, 0.6, 1.0]
V6 = c.array("v6.mtx", vandermonde(nodes6, 6))
c.cmd("det", V6)
c.cmd("inv", V6)
c.cmd("cond", V6)
c.cmd("lu", V6)
c.cmd("solve", V6, c.array("rhs6.mtx", [[1.0], [0.0], [2.0], [0.0], [-1.0], [3.0]]))
V93 = c.array("v93.mtx", vandermonde([i * 0.25 for i in range(9)], 3))
c.cmd("lstsq", V93, c.array("y9.mtx", [[float(i * i) + 0.5] for i in range(9)]))
c.cmd("qr", V93)
c.cmd("svd", V93)

# --- 022: near-singular but usable -------------------------------------------
c = case("near_singular")


def reflector(values):
    nrm = math.sqrt(sum(x * x for x in values))
    return [x / nrm for x in values]


def prescribed_spectrum(u, v, sigmas):
    """(I - 2 u u^T) diag(sigmas) (I - 2 v v^T): a matrix with known singular values."""
    n = len(sigmas)
    P = [[(1.0 if i == j else 0.0) - 2.0 * u[i] * u[j] for j in range(n)] for i in range(n)]
    Q = [[(1.0 if i == j else 0.0) - 2.0 * v[i] * v[j] for j in range(n)] for i in range(n)]
    return [[sum(P[i][k] * sigmas[k] * Q[k][j] for k in range(n)) for j in range(n)]
            for i in range(n)]


rng = random.Random(4004)
n = 6
u = reflector([rng.uniform(-1.0, 1.0) for _ in range(n)])
v = reflector([rng.uniform(-1.0, 1.0) for _ in range(n)])
A = c.array("a.mtx", prescribed_spectrum(u, v, [1.0, 0.3, 0.05, 8e-3, 1e-3, 1e-6]),
            comments=["singular values 1, 0.3, 0.05, 8e-3, 1e-3, 1e-6 (condition 1e6)"])
c.cmd("cond", A)
c.cmd("det", A)
c.cmd("lu", A)
c.cmd("inv", A)
c.cmd("solve", A, c.array("b.mtx", [[float(i + 1)] for i in range(n)]))
c.cmd("svd", A)
D = c.array("d.mtx", diag([1.0, 1e-2, 1e-4, 1e-6]))
c.cmd("cond", D)
c.cmd("inv", D)
c.cmd("normfro", D)

# --- 023: random 12x12 mixed workload ----------------------------------------
c = case("random_small")
rng = random.Random(5005)
A = c.array("a.mtx", rand_matrix(rng, 12, 12))
B = c.array("b.mtx", rand_matrix(rng, 12, 12))
S = c.array("s.mtx", spd_matrix(rng, 12), symmetry="symmetric")
R = c.array("r.mtx", rand_matrix(rng, 12, 4))
c.cmd("add", A, B)
c.cmd("mul", A, B)
c.cmd("transpose", A)
c.cmd("lu", A)
c.cmd("det", A)
c.cmd("inv", A)
c.cmd("solve", A, R)
c.cmd("qr", A)
c.cmd("chol", S)
c.cmd("eig", S)
c.cmd("svd", A)
c.cmd("lstsq", A, R)
c.cmd("norm1", A)
c.cmd("norminf", A)
c.cmd("normfro", A)
c.cmd("cond", A)

# --- 024: random rectangular shapes ------------------------------------------
c = case("random_rectangular")
rng = random.Random(6006)
T = c.array("tall.mtx", rand_matrix(rng, 30, 8))
W = c.array("wide.mtx", rand_matrix(rng, 8, 30))
Y = c.array("y.mtx", rand_matrix(rng, 30, 3))
c.cmd("qr", T)
c.cmd("svd", T)
c.cmd("svd", W)
c.cmd("lstsq", T, Y)
c.cmd("mul", W, T)
c.cmd("mul", T, W)
c.cmd("transpose", W)
c.cmd("normfro", T)
c.cmd("cond", T)
c.cmd("cond", W)

# --- 025: random 40x40 --------------------------------------------------------
c = case("random_medium")
rng = random.Random(7007)
A = c.array("a.mtx", rand_matrix(rng, 40, 40))
S = c.array("s.mtx", spd_matrix(rng, 40), symmetry="symmetric")
B = c.array("b.mtx", rand_matrix(rng, 40, 6))
c.cmd("lu", A)
c.cmd("det", A)
c.cmd("inv", A)
c.cmd("solve", A, B)
c.cmd("qr", A)
c.cmd("svd", A)
c.cmd("cond", A)
c.cmd("chol", S)
c.cmd("eig", S)
c.cmd("norm1", A)
c.cmd("norminf", S)

# --- 026: random SPD with a wide spectrum -------------------------------------
c = case("spd_spectrum")
rng = random.Random(8008)
n = 25
# A = H diag(w) H with H the Householder reflection of a random unit vector,
# which gives a symmetric matrix with an exactly known, evenly spread spectrum.
v = [rng.uniform(-1.0, 1.0) for _ in range(n)]
nrm = math.sqrt(sum(x * x for x in v))
v = [x / nrm for x in v]
w = [1.0 + i * 0.37 for i in range(n)]
A = [[(1.0 if i == j else 0.0) - 2.0 * v[i] * v[j] for j in range(n)] for i in range(n)]
M = [[sum(A[i][k] * w[k] * A[j][k] for k in range(n)) for j in range(n)] for i in range(n)]
M = [[round((M[i][j] + M[j][i]) / 2.0, 12) for j in range(n)] for i in range(n)]
S = c.array("s.mtx", M, symmetry="symmetric")
c.cmd("eig", S)
c.cmd("chol", S)
c.cmd("cond", S)
c.cmd("det", S)
c.cmd("inv", S)
c.cmd("svd", S)

# --- 027..: SuiteSparse corpus ------------------------------------------------
c = case("ss_can24")
M = c.corpus("can_24.mtx", "can_24.mtx")
c.cmd("norm1", M)
c.cmd("norminf", M)
c.cmd("normfro", M)
c.cmd("transpose", M)
c.cmd("lu", M)
c.cmd("det", M)
c.cmd("inv", M)
c.cmd("chol", M)
c.cmd("solve", M, c.array("rhs.mtx", [[float((i % 7) - 3)] for i in range(24)]))
c.cmd("qr", M)
c.cmd("cond", M)

c = case("ss_ibm32")
M = c.corpus("ibm32.mtx", "ibm32.mtx")
c.cmd("norm1", M)
c.cmd("normfro", M)
c.cmd("det", M)
c.cmd("inv", M)
c.cmd("qr", M)
c.cmd("svd", M)
c.cmd("cond", M)
c.cmd("solve", M, c.array("rhs.mtx", [[1.0 / (i + 1)] for i in range(32)]))
c.cmd("mul", M, "rhs.mtx")

c = case("ss_bcsstk01")
M = c.corpus("bcsstk01.mtx", "bcsstk01.mtx")
c.cmd("norm1", M)
c.cmd("norminf", M)
c.cmd("normfro", M)
c.cmd("chol", M)
c.cmd("inv", M)
c.cmd("cond", M)
c.cmd("qr", M)
c.cmd("solve", M, c.array("rhs.mtx", [[float(i % 5) - 2.0] for i in range(48)]))

c = case("ss_bcsstk02")
M = c.corpus("bcsstk02.mtx", "bcsstk02.mtx")
c.cmd("norm1", M)
c.cmd("normfro", M)
c.cmd("chol", M)
c.cmd("det", M)
c.cmd("inv", M)
c.cmd("cond", M)
c.cmd("solve", M, c.array("rhs.mtx", [[math.sin(i)] for i in range(66)]))

c = case("ss_nos4")
M = c.corpus("nos4.mtx", "nos4.mtx")
c.cmd("norm1", M)
c.cmd("normfro", M)
c.cmd("chol", M)
c.cmd("det", M)
c.cmd("inv", M)
c.cmd("cond", M)
c.cmd("lu", M)
c.cmd("solve", M, c.array("rhs.mtx", [[1.0] for _ in range(100)]))

c = case("ss_gre115")
M = c.corpus("gre_115.mtx", "gre_115.mtx")
c.cmd("norm1", M)
c.cmd("norminf", M)
c.cmd("lu", M)
c.cmd("det", M)
c.cmd("inv", M)
c.cmd("qr", M)
c.cmd("svd", M)
c.cmd("cond", M)

c = case("ss_impcol_b")
M = c.corpus("impcol_b.mtx", "impcol_b.mtx")
c.cmd("normfro", M)
c.cmd("norm1", M)
c.cmd("det", M)
c.cmd("inv", M)
c.cmd("qr", M)
c.cmd("cond", M)
c.cmd("solve", M, c.array("rhs.mtx", [[float(i + 1)] for i in range(59)]))

c = case("ss_lund_a")
M = c.corpus("lund_a.mtx", "lund_a.mtx")
c.cmd("norm1", M)
c.cmd("norminf", M)
c.cmd("normfro", M)
c.cmd("chol", M)
c.cmd("lu", M)
c.cmd("solve", M, c.array("rhs.mtx", [[math.cos(i * 0.5)] for i in range(147)]))

c = case("ss_west0132")
M = c.corpus("west0132.mtx", "west0132.mtx")
c.cmd("norm1", M)
c.cmd("norminf", M)
c.cmd("normfro", M)
c.cmd("transpose", M)
c.cmd("mul", M, M)
c.cmd("lu", M)

c = case("ss_fs_183_1")
M = c.corpus("fs_183_1.mtx", "fs_183_1.mtx")
c.cmd("norm1", M)
c.cmd("norminf", M)
c.cmd("normfro", M)
c.cmd("lu", M)
c.cmd("mul", M, c.array("rhs.mtx", [[1.0 / (i + 1.0)] for i in range(183)]))

c = case("ss_steam1")
M = c.corpus("steam1.mtx", "steam1.mtx")
c.cmd("norm1", M)
c.cmd("norminf", M)
c.cmd("normfro", M)
c.cmd("transpose", M)
c.cmd("lu", M)
c.cmd("solve", M, c.array("rhs.mtx", [[float((i % 11) - 5)] for i in range(240)]))

c = case("ss_494_bus")
M = c.corpus("494_bus.mtx", "494_bus.mtx")
c.cmd("norm1", M)
c.cmd("norminf", M)
c.cmd("normfro", M)
c.cmd("solve", M, c.array("rhs.mtx", [[1.0 / (1.0 + (i % 13))] for i in range(494)]))
c.cmd("mul", M, "rhs.mtx")

c = case("ss_494_bus_block")
full = read_mm(os.path.join(CORPUS, "494_bus.mtx"))
block = submatrix(full, 150, 150)
M = c.coord("bus150.mtx", block, symmetry="symmetric",
            comments=["leading 150x150 principal submatrix of HB/494_bus"])
c.cmd("chol", M)
c.cmd("det", M)
c.cmd("inv", M)
c.cmd("solve", M, c.array("rhs.mtx", [[float(i % 3)] for i in range(150)]))
c.cmd("norm1", M)

# --- eigen problems derived from corpus matrices ------------------------------
c = case("ss_eig_symmetrised")
ibm = read_mm(os.path.join(CORPUS, "ibm32.mtx"))
imp = read_mm(os.path.join(CORPUS, "impcol_b.mtx"))
can = read_mm(os.path.join(CORPUS, "can_24.mtx"))
c.cmd("eig", c.array("ibm32_sym.mtx", symmetric_part(ibm), symmetry="symmetric",
                     comments=["symmetric part (A+A^T)/2 of HB/ibm32"]))
c.cmd("eig", c.array("impcol_b_sym.mtx", symmetric_part(imp), symmetry="symmetric",
                     comments=["symmetric part (A+A^T)/2 of HB/impcol_b"]))
c.cmd("eig", c.array("can_24_ramp.mtx", diagonal_ramp(can), symmetry="symmetric",
                     comments=["HB/can_24 with an increasing diagonal ramp added"]))
c.cmd("svd", "ibm32_sym.mtx")
c.cmd("cond", "impcol_b_sym.mtx")

c = case("ss_eig_large")
gre = read_mm(os.path.join(CORPUS, "gre_115.mtx"))
nos = read_mm(os.path.join(CORPUS, "nos4.mtx"))
c.cmd("eig", c.array("gre115_sym.mtx", symmetric_part(gre), symmetry="symmetric",
                     comments=["symmetric part (A+A^T)/2 of HB/gre_115"]))
c.cmd("eig", c.array("nos4_ramp.mtx", diagonal_ramp(nos), symmetry="symmetric",
                     comments=["HB/nos4 with an increasing diagonal ramp added"]))
c.cmd("chol", "nos4_ramp.mtx")


# ---------------------------------------------------------------------------
# The numpy oracle, run in the venv as a subprocess
# ---------------------------------------------------------------------------

ORACLE_SOURCE = r'''
"""Recompute every command with numpy and compare with the reference output."""
import os
import sys
import numpy as np

ARITY = {"add": 2, "mul": 2, "transpose": 1, "lu": 1, "det": 1, "inv": 1,
         "solve": 2, "qr": 1, "chol": 1, "eig": 1, "svd": 1, "lstsq": 2,
         "norm1": 1, "norminf": 1, "normfro": 1, "cond": 1}
SUFFIXES = {"add": ["add"], "mul": ["mul"], "transpose": ["transpose"],
            "lu": ["lu_P", "lu_L", "lu_U"], "det": ["det"], "inv": ["inv"],
            "solve": ["solve"], "qr": ["qr_Q", "qr_R"], "chol": ["chol_L"],
            "eig": ["eig_w", "eig_V"], "svd": ["svd_U", "svd_S", "svd_V"],
            "lstsq": ["lstsq"], "norm1": ["norm1"], "norminf": ["norminf"],
            "normfro": ["normfro"], "cond": ["cond"]}
RTOL = 1e-8
ATOL = 1e-12
GAP_MIN = 1e-4
TIE_MAX = 1.0 - 1e-5

problems = []
worst = [0.0, ""]


def read_mm(path):
    with open(path) as f:
        text = f.read()
    lines = text.split("\n")
    banner = lines[0].split()
    fmt, field, sym = banner[2].lower(), banner[3].lower(), banner[4].lower()
    body = [l.strip() for l in lines[1:] if l.strip() and not l.strip().startswith("%")]
    size = body[0].split()
    rows, cols = int(size[0]), int(size[1])
    rest = body[1:]
    A = np.zeros((rows, cols))
    if fmt == "coordinate":
        for k in range(int(size[2])):
            p = rest[k].split()
            i, j = int(p[0]) - 1, int(p[1]) - 1
            v = 1.0 if field == "pattern" else float(p[2])
            A[i, j] = v
            if i != j:
                if sym == "symmetric":
                    A[j, i] = v
                elif sym == "skew-symmetric":
                    A[j, i] = -v
    else:
        it = iter(rest)
        for j in range(cols):
            for i in range(rows):
                if sym == "symmetric" and i < j:
                    continue
                if sym == "skew-symmetric" and i <= j:
                    continue
                v = float(next(it))
                A[i, j] = v
                if i != j:
                    if sym == "symmetric":
                        A[j, i] = v
                    elif sym == "skew-symmetric":
                        A[j, i] = -v
    return A


def read_result(path):
    with open(path) as f:
        lines = [l.strip() for l in f.read().split("\n") if l.strip()]
    if lines[0] != "%%MatrixMarket matrix array real general":
        raise ValueError("bad banner in " + path)
    rows, cols = (int(x) for x in lines[1].split())
    values = [float(x) for x in lines[2:]]
    if len(values) != rows * cols:
        raise ValueError("bad value count in " + path)
    return np.array(values).reshape((cols, rows)).T


def compare(tag, expected, actual):
    expected = np.asarray(expected, dtype=float)
    if expected.shape != actual.shape:
        problems.append("%s: shape %s, reference produced %s"
                        % (tag, expected.shape, actual.shape))
        return
    if not np.all(np.isfinite(actual)):
        problems.append("%s: reference produced a non-finite value" % tag)
        return
    scale = max(1.0, float(np.max(np.abs(expected)))) if expected.size else 1.0
    allowed = RTOL * np.abs(expected) + ATOL * scale
    ratio = np.abs(expected - actual) / allowed
    k = int(np.argmax(ratio))
    if ratio.flat[k] > worst[0]:
        worst[0] = float(ratio.flat[k])
        worst[1] = tag
    if ratio.flat[k] > 1.0:
        problems.append("%s: entry %s numpy=%.17g reference=%.17g ratio=%.3g"
                        % (tag, np.unravel_index(k, expected.shape),
                           expected.flat[k], actual.flat[k], ratio.flat[k]))


def sign_fix_columns(V):
    """Apply the spec's sign rule and report the weakest argmax margin."""
    V = np.array(V, dtype=float)
    margin = 0.0
    for j in range(V.shape[1]):
        col = np.abs(V[:, j])
        order = np.sort(col)[::-1]
        if order[0] > 0 and len(order) > 1:
            margin = max(margin, order[1] / order[0])
        i = int(np.argmax(col))
        if V[i, j] < 0:
            V[:, j] = -V[:, j]
    return V, margin


def check(indir, outdir):
    with open(os.path.join(indir, "commands.txt")) as f:
        script = f.read()
    seen = set()
    index = 0
    for raw in script.split("\n"):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        index += 1
        parts = line.split()
        op = parts[0]
        names = parts[1:1 + ARITY[op]]
        tag = "cmd %d [%s]" % (index, line)
        err = os.path.join(outdir, "%03d_error.txt" % index)
        if os.path.exists(err):
            seen.add(os.path.basename(err))
            continue
        for suffix in SUFFIXES[op]:
            seen.add("%03d_%s.mtx" % (index, suffix))
        M = [read_mm(os.path.join(indir, n)) for n in names]

        def got(suffix):
            return read_result(os.path.join(outdir, "%03d_%s.mtx" % (index, suffix)))

        if op == "add":
            compare(tag, M[0] + M[1], got("add"))
        elif op == "mul":
            compare(tag, M[0] @ M[1], got("mul"))
        elif op == "transpose":
            compare(tag, M[0].T, got("transpose"))
        elif op == "norm1":
            compare(tag, [[np.linalg.norm(M[0], 1)]], got("norm1"))
        elif op == "norminf":
            compare(tag, [[np.linalg.norm(M[0], np.inf)]], got("norminf"))
        elif op == "normfro":
            compare(tag, [[np.linalg.norm(M[0], "fro")]], got("normfro"))
        elif op == "det":
            compare(tag, [[np.linalg.det(M[0])]], got("det"))
        elif op == "inv":
            compare(tag, np.linalg.inv(M[0]), got("inv"))
        elif op == "solve":
            compare(tag, np.linalg.solve(M[0], M[1]), got("solve"))
        elif op == "lstsq":
            compare(tag, np.linalg.lstsq(M[0], M[1], rcond=None)[0], got("lstsq"))
        elif op == "chol":
            compare(tag, np.linalg.cholesky(M[0]), got("chol_L"))
        elif op == "cond":
            s = np.linalg.svd(M[0], compute_uv=False)
            compare(tag, [[s[0] / s[-1]]], got("cond"))
        elif op == "qr":
            Q, R = np.linalg.qr(M[0])
            d = np.sign(np.diag(R))
            d[d == 0] = 1.0
            compare(tag + " Q", Q * d, got("qr_Q"))
            compare(tag + " R", R * d[:, None], got("qr_R"))
        elif op == "eig":
            w, V = np.linalg.eigh(M[0])
            spread = w[-1] - w[0]
            if len(w) > 1:
                gap = np.min(np.diff(w)) / (spread if spread > 0 else 1.0)
                if gap < GAP_MIN:
                    problems.append("%s: relative eigenvalue gap %.2e is too small"
                                    % (tag, gap))
            V, margin = sign_fix_columns(V)
            if margin > TIE_MAX:
                problems.append("%s: eigenvector sign is ambiguous (margin %.6f)"
                                % (tag, margin))
            compare(tag + " w", w.reshape(-1, 1), got("eig_w"))
            compare(tag + " V", V, got("eig_V"))
        elif op == "svd":
            U, s, Vt = np.linalg.svd(M[0], full_matrices=False)
            V = Vt.T
            if len(s) > 1:
                gap = np.min(np.abs(np.diff(s))) / s[0] if s[0] > 0 else 1.0
                if gap < GAP_MIN:
                    problems.append("%s: relative singular value gap %.2e is too small"
                                    % (tag, gap))
            margin = 0.0
            for j in range(U.shape[1]):
                col = np.abs(U[:, j])
                order = np.sort(col)[::-1]
                if order[0] > 0 and len(order) > 1:
                    margin = max(margin, order[1] / order[0])
                i = int(np.argmax(col))
                if U[i, j] < 0:
                    U[:, j] = -U[:, j]
                    V[:, j] = -V[:, j]
            if margin > TIE_MAX:
                problems.append("%s: singular vector sign is ambiguous (margin %.6f)"
                                % (tag, margin))
            compare(tag + " S", s.reshape(-1, 1), got("svd_S"))
            compare(tag + " U", U, got("svd_U"))
            compare(tag + " V", V, got("svd_V"))
        elif op == "lu":
            A = M[0].astype(float)
            n = A.shape[0]
            LU = A.copy()
            perm = list(range(n))
            singular = False
            for k in range(n):
                col = np.abs(LU[k:, k])
                best = float(col.max()) if col.size else 0.0
                if best == 0.0:
                    singular = True
                    break
                pk = k + int(np.argmax(col))
                runner = np.sort(col)[::-1]
                if len(runner) > 1 and runner[1] > 0:
                    ratio = runner[1] / runner[0]
                    if TIE_MAX < ratio < 1.0:
                        problems.append("%s: pivot choice at step %d is a near tie (%.15f)"
                                        % (tag, k, ratio))
                if pk != k:
                    LU[[k, pk]] = LU[[pk, k]]
                    perm[k], perm[pk] = perm[pk], perm[k]
                LU[k + 1:, k] /= LU[k, k]
                LU[k + 1:, k + 1:] -= np.outer(LU[k + 1:, k], LU[k, k + 1:])
            if singular:
                problems.append("%s: numpy found a zero pivot but the reference did not" % tag)
                continue
            P = np.zeros((n, n))
            for i in range(n):
                P[i, perm[i]] = 1.0
            compare(tag + " P", P, got("lu_P"))
            compare(tag + " L", np.tril(LU, -1) + np.eye(n), got("lu_L"))
            compare(tag + " U", np.triu(LU), got("lu_U"))
        else:
            problems.append("%s: unhandled operation" % tag)
    produced = set(os.listdir(outdir))
    if produced != seen:
        problems.append("result files %s do not match the commands %s"
                        % (sorted(produced - seen), sorted(seen - produced)))


check(sys.argv[1], sys.argv[2])
for p in problems:
    print(p)
print("worst ratio %.3g at %s" % (worst[0], worst[1]))
sys.exit(1 if problems else 0)
'''


# ---------------------------------------------------------------------------
# Generation
# ---------------------------------------------------------------------------

def main():
    if os.path.isdir(TESTS):
        shutil.rmtree(TESTS)
    os.makedirs(TESTS)
    # The SuiteSparse matrices are copied into tests/, so their licence goes
    # with them.
    scratch = tempfile.TemporaryDirectory(prefix="linalg_oracle_")
    oracle = os.path.join(scratch.name, "oracle.py")
    with open(oracle, "w", encoding="utf-8") as f:
        f.write(ORACLE_SOURCE)
    total = 0
    failures = 0
    for number, c in enumerate(CASES, 1):
        case_dir = os.path.join(TESTS, "%03d_%s" % (number, c.name))
        in_dir = os.path.join(case_dir, "input")
        out_dir = os.path.join(case_dir, "expected")
        os.makedirs(in_dir)
        os.makedirs(out_dir)
        for name, text in c.files.items():
            with open(os.path.join(in_dir, name), "w", encoding="utf-8") as f:
                f.write(text)
        script = c.script if c.script is not None else "".join(l + "\n" for l in c.commands)
        with open(os.path.join(in_dir, "commands.txt"), "w", encoding="utf-8") as f:
            f.write(script)
        proc = subprocess.run([sys.executable, REF, in_dir, out_dir],
                              capture_output=True, text=True)
        if proc.returncode != 0:
            print("%s: reference failed: %s" % (c.name, proc.stderr.strip()[:400]))
            failures += 1
            continue
        check = subprocess.run([ORACLE_PY, oracle, in_dir, out_dir],
                               capture_output=True, text=True)
        size = sum(os.path.getsize(os.path.join(dp, fn))
                   for dp, _, fns in os.walk(case_dir) for fn in fns)
        status = "ok " if check.returncode == 0 else "BAD"
        print("%s %03d_%-24s %2d cmds %7.1f kB  %s"
              % (status, number, c.name, len(c.commands), size / 1024.0,
                 check.stdout.strip().replace("\n", " | ")[:220]))
        if check.returncode != 0:
            failures += 1
        total += 1
    if failures:
        print("\n%d case(s) disagreed with numpy; tests are NOT valid" % failures)
        return 1
    print("\n%d cases generated" % total)
    return 0


# tests/ is handed out without corpus/, so it carries the licences of its
# third-party data.
TEST_NOTICE = 'corpus/tests-notice.md'
TEST_LICENCES = [
    ('corpus/LICENSE',
     'CORPUS_LICENSE'),
    ('corpus/LICENSE-CC-BY-4.0.txt',
     'LICENSE-CC-BY-4.0.txt'),
]


def copy_licences():
    shutil.copyfile(os.path.join(HERE, TEST_NOTICE),
                    os.path.join(TESTS, 'THIRD_PARTY.md'))
    for src, name in TEST_LICENCES:
        shutil.copyfile(os.path.join(HERE, src), os.path.join(TESTS, name))


if __name__ == "__main__":
    rc = main()
    copy_licences()
    sys.exit(rc)
