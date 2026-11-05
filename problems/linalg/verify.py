#!/usr/bin/env python3
"""Verifier for the `linalg` problem.

Usage: verify.py <input dir> <actual output dir> [<expected output dir>]

Results are floating point, so they are compared numerically rather than
textually: entry a matches entry e when

    |a - e| <= 1e-8 * |e| + 1e-12 * max(1, max|E|)

where max|E| is the largest magnitude in the expected file. The absolute term
is scaled by the file's magnitude because "%.10e" carries only eleven
significant digits, so a fixed 1e-12 floor would be below the resolution of
the printed format for any matrix with large entries.

Beyond the entry comparison the verifier insists on the printed form of
section 2.1 (one value per line, each matching printf("%.10e")), checks that
nothing was written into the input directory, and checks the structure and
the residual
of each factorisation (P a permutation, L unit lower triangular with entries at
most 1 in magnitude, R and U upper triangular, Q'Q = I, L L' = A, P A = L U,
A V = V diag(w), A = U diag(s) V'). Residual checks are skipped for matrices
larger than 120 on a side to keep the verifier fast.

Exit 0 on pass; otherwise print a reason and exit 1.
"""
import math
import os
import re
import sys

RTOL = 1e-8
ATOL = 1e-12
# Every printed value must have the printf("%.10e") shape section 2.1 fixes.
VALUE_RE = re.compile(r"-?[0-9]\.[0-9]{10}e[+-][0-9]{2,}\Z")
ORTHO_TOL = 1e-9
RESIDUAL_TOL = 1e-8
RESIDUAL_LIMIT = 120

ARITY = {"add": 2, "mul": 2, "transpose": 1, "lu": 1, "det": 1, "inv": 1,
         "solve": 2, "qr": 1, "chol": 1, "eig": 1, "svd": 1, "lstsq": 2,
         "norm1": 1, "norminf": 1, "normfro": 1, "cond": 1}
SUFFIXES = {"add": ["add"], "mul": ["mul"], "transpose": ["transpose"],
            "lu": ["lu_P", "lu_L", "lu_U"], "det": ["det"], "inv": ["inv"],
            "solve": ["solve"], "qr": ["qr_Q", "qr_R"], "chol": ["chol_L"],
            "eig": ["eig_w", "eig_V"], "svd": ["svd_U", "svd_S", "svd_V"],
            "lstsq": ["lstsq"], "norm1": ["norm1"], "norminf": ["norminf"],
            "normfro": ["normfro"], "cond": ["cond"]}


def fail(message):
    print(message)
    sys.exit(1)


# ---------------------------------------------------------------------------
# Readers
# ---------------------------------------------------------------------------

def read_input_matrix(path):
    """Read any Matrix Market file the spec allows into a dense matrix."""
    with open(path, "r", encoding="utf-8") as f:
        text = f.read()
    lines = text.split("\n")
    banner = lines[0].split()
    fmt, field, symmetry = banner[2].lower(), banner[3].lower(), banner[4].lower()
    body = [l.strip() for l in lines[1:] if l.strip() and not l.strip().startswith("%")]
    size = body[0].split()
    rows, cols = int(size[0]), int(size[1])
    rest = body[1:]
    A = [[0.0] * cols for _ in range(rows)]
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


def read_result(path, where):
    """Read a result file, insisting on the output format the spec fixes."""
    try:
        with open(path, "r", encoding="utf-8") as f:
            text = f.read()
    except OSError as err:
        fail("%s: cannot read %s (%s)" % (where, os.path.basename(path), err))
    lines = [l.strip() for l in text.split("\n") if l.strip()]
    if not lines:
        fail("%s: %s is empty" % (where, os.path.basename(path)))
    banner = lines[0].split()
    if [t.lower() for t in banner] != ["%%matrixmarket", "matrix", "array", "real", "general"]:
        fail("%s: %s has banner %r, expected '%%%%MatrixMarket matrix array real general'"
             % (where, os.path.basename(path), lines[0]))
    body = [l for l in lines[1:] if not l.startswith("%")]
    try:
        rows, cols = (int(x) for x in body[0].split())
    except (ValueError, IndexError):
        fail("%s: %s has no valid size line" % (where, os.path.basename(path)))
    values = []
    for token in body[1:]:
        parts = token.split()
        if len(parts) != 1:
            fail("%s: %s has %d values on one line, expected one"
                 % (where, os.path.basename(path), len(parts)))
        if not VALUE_RE.match(parts[0]):
            fail("%s: %s holds %r, which is not printf(\"%%.10e\") form"
                 % (where, os.path.basename(path), parts[0]))
        values.append(float(parts[0]))
    if len(values) != rows * cols:
        fail("%s: %s declares %dx%d but holds %d values"
             % (where, os.path.basename(path), rows, cols, len(values)))
    A = [[0.0] * cols for _ in range(rows)]
    k = 0
    for j in range(cols):
        for i in range(rows):
            A[i][j] = values[k]
            k += 1
    return A


# ---------------------------------------------------------------------------
# Small dense helpers
# ---------------------------------------------------------------------------

def max_abs(A):
    return max((abs(v) for row in A for v in row), default=0.0)


def norm_inf(A):
    return max((sum(abs(v) for v in row) for row in A), default=0.0)


def mul(A, B):
    cols = list(zip(*B))
    return [[sum(x * y for x, y in zip(row, col)) for col in cols] for row in A]


def sub(A, B):
    return [[a - b for a, b in zip(ra, rb)] for ra, rb in zip(A, B)]


def transpose(A):
    return [list(col) for col in zip(*A)]


def identity(n):
    return [[1.0 if i == j else 0.0 for j in range(n)] for i in range(n)]


def permute_rows(A, P):
    """P A, with P given as a dense permutation matrix."""
    n = len(P)
    out = []
    for i in range(n):
        src = next(j for j in range(n) if P[i][j] != 0.0)
        out.append(A[src][:])
    return out


# ---------------------------------------------------------------------------
# Entry comparison
# ---------------------------------------------------------------------------

def compare_matrix(name, expected, actual):
    if len(expected) != len(actual) or len(expected[0]) != len(actual[0]):
        fail("%s: expected %dx%d, got %dx%d" % (name, len(expected), len(expected[0]),
                                                len(actual), len(actual[0])))
    atol = ATOL * max(1.0, max_abs(expected))
    for i, (re_, ra) in enumerate(zip(expected, actual)):
        for j, (e, a) in enumerate(zip(re_, ra)):
            if not math.isfinite(a):
                fail("%s: entry (%d,%d) is %r" % (name, i, j, a))
            if abs(a - e) > RTOL * abs(e) + atol:
                fail("%s: entry (%d,%d) is %.17g, expected %.17g (allowed %.3g)"
                     % (name, i, j, a, e, RTOL * abs(e) + atol))


# ---------------------------------------------------------------------------
# Structural and residual checks
# ---------------------------------------------------------------------------

def check_residual(tag, name, residual, scale):
    limit = RESIDUAL_TOL * max(1.0, scale)
    got = max_abs(residual)
    if got > limit:
        fail("%s: %s residual %.3g exceeds %.3g" % (tag, name, got, limit))


def check_orthonormal(tag, name, Q):
    n = len(Q[0])
    G = mul(transpose(Q), Q)
    worst = max_abs(sub(G, identity(n)))
    if worst > ORTHO_TOL:
        fail("%s: %s'%s departs from the identity by %.3g" % (tag, name, name, worst))


def check_command(tag, op, inputs, results):
    """Structural invariants, plus residuals for matrices that stay small."""
    big = any(max(len(M), len(M[0])) > RESIDUAL_LIMIT for M in inputs)
    if op == "lu":
        P, L, U = results["lu_P"], results["lu_L"], results["lu_U"]
        n = len(P)
        for i in range(n):
            ones = [j for j in range(n) if P[i][j] == 1.0]
            if len(ones) != 1 or any(P[i][j] not in (0.0, 1.0) for j in range(n)):
                fail("%s: row %d of P is not a unit row" % (tag, i))
        if sorted(next(j for j in range(n) if P[i][j] == 1.0) for i in range(n)) != list(range(n)):
            fail("%s: P is not a permutation matrix" % tag)
        for i in range(n):
            if L[i][i] != 1.0:
                fail("%s: L has %.17g on the diagonal at %d" % (tag, L[i][i], i))
            for j in range(i + 1, n):
                if L[i][j] != 0.0:
                    fail("%s: L is not lower triangular at (%d,%d)" % (tag, i, j))
                if U[j][i] != 0.0:
                    fail("%s: U is not upper triangular at (%d,%d)" % (tag, j, i))
            for j in range(i):
                if abs(L[i][j]) > 1.0:
                    fail("%s: |L[%d][%d]| = %.17g exceeds 1" % (tag, i, j, abs(L[i][j])))
        if not big:
            A = inputs[0]
            check_residual(tag, "P A - L U", sub(permute_rows(A, P), mul(L, U)), max_abs(A))
    elif op == "qr":
        Q, R = results["qr_Q"], results["qr_R"]
        n = len(R)
        for j in range(n):
            if R[j][j] < 0.0:
                fail("%s: R has a negative diagonal entry at %d" % (tag, j))
            for i in range(j + 1, n):
                if R[i][j] != 0.0:
                    fail("%s: R is not upper triangular at (%d,%d)" % (tag, i, j))
        if not big:
            A = inputs[0]
            check_orthonormal(tag, "Q", Q)
            check_residual(tag, "Q R - A", sub(mul(Q, R), A), max_abs(A))
    elif op == "chol":
        L = results["chol_L"]
        n = len(L)
        for i in range(n):
            if not L[i][i] > 0.0:
                fail("%s: L has a non-positive diagonal entry at %d" % (tag, i))
            for j in range(i + 1, n):
                if L[i][j] != 0.0:
                    fail("%s: L is not lower triangular at (%d,%d)" % (tag, i, j))
        if not big:
            A = inputs[0]
            check_residual(tag, "L L' - A", sub(mul(L, transpose(L)), A), max_abs(A))
    elif op == "eig":
        w, V = results["eig_w"], results["eig_V"]
        values = [row[0] for row in w]
        for i in range(1, len(values)):
            if values[i] < values[i - 1]:
                fail("%s: eigenvalues are not ascending at %d" % (tag, i))
        check_sign_normalised(tag, "V", V)
        if not big:
            A = inputs[0]
            AV = mul(A, V)
            VW = [[V[i][j] * values[j] for j in range(len(values))] for i in range(len(V))]
            check_orthonormal(tag, "V", V)
            check_residual(tag, "A V - V diag(w)", sub(AV, VW), max_abs(A))
    elif op == "svd":
        U, S, V = results["svd_U"], results["svd_S"], results["svd_V"]
        sigmas = [row[0] for row in S]
        for i, s in enumerate(sigmas):
            if s < 0.0:
                fail("%s: singular value %d is negative" % (tag, i))
            if i and s > sigmas[i - 1]:
                fail("%s: singular values are not descending at %d" % (tag, i))
        check_sign_normalised(tag, "U", U)
        if not big:
            A = inputs[0]
            check_orthonormal(tag, "U", U)
            check_orthonormal(tag, "V", V)
            US = [[U[i][j] * sigmas[j] for j in range(len(sigmas))] for i in range(len(U))]
            check_residual(tag, "U diag(s) V' - A", sub(mul(US, transpose(V)), A), max_abs(A))
    elif op == "inv" and not big:
        A, X = inputs[0], results["inv"]
        check_residual(tag, "A X - I", sub(mul(A, X), identity(len(A))),
                       norm_inf(A) * norm_inf(X))
    elif op == "solve" and not big:
        A, B, X = inputs[0], inputs[1], results["solve"]
        check_residual(tag, "A X - B", sub(mul(A, X), B),
                       max(norm_inf(A) * norm_inf(X), max_abs(B)))
    elif op == "lstsq" and not big:
        A, B, X = inputs[0], inputs[1], results["lstsq"]
        At = transpose(A)
        check_residual(tag, "A'(A X - B)", mul(At, sub(mul(A, X), B)),
                       norm_inf(At) * max(norm_inf(A) * norm_inf(X), max_abs(B)))


def check_sign_normalised(tag, name, V):
    """Every column's first largest-magnitude entry must be positive."""
    for j in range(len(V[0])):
        column = [V[i][j] for i in range(len(V))]
        best = -1.0
        idx = 0
        for i, v in enumerate(column):
            if abs(v) > best:
                best = abs(v)
                idx = i
        if column[idx] < 0.0:
            fail("%s: column %d of %s is not sign normalised" % (tag, j, name))


# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------

def read_commands(in_dir):
    with open(os.path.join(in_dir, "commands.txt"), "r", encoding="utf-8") as f:
        script = f.read()
    out = []
    for raw in script.split("\n"):
        line = raw.strip()
        if line and not line.startswith("#"):
            out.append(line.split())
    return out


def main(argv):
    if len(argv) < 3:
        fail("usage: verify.py <input dir> <actual dir> [<expected dir>]")
    in_dir, actual_dir = argv[1], argv[2]
    expected_dir = argv[3] if len(argv) > 3 else None

    commands = read_commands(in_dir)
    allowed_inputs = {"commands.txt"}
    for parts in commands:
        allowed_inputs.update(parts[1:1 + ARITY[parts[0]]])
    stray = sorted(set(os.listdir(in_dir)) - allowed_inputs)
    if stray:
        fail("the input directory gained %s; nothing may be written outside "
             "the output directory" % ", ".join(stray[:5]))

    produced = set()
    for entry in sorted(os.listdir(actual_dir)):
        path = os.path.join(actual_dir, entry)
        if not os.path.isfile(path):
            fail("output contains %s, which is not a regular file" % entry)
        produced.add(entry)

    matrices = {}

    def load(name):
        if name not in matrices:
            matrices[name] = read_input_matrix(os.path.join(in_dir, name))
        return matrices[name]

    wanted = set()
    for index, parts in enumerate(commands, 1):
        op = parts[0]
        tag = "command %d (%s)" % (index, " ".join(parts))
        error_name = "%03d_error.txt" % index
        result_names = ["%03d_%s.mtx" % (index, s) for s in SUFFIXES[op]]
        if expected_dir is not None:
            expected_error = os.path.join(expected_dir, error_name)
            if os.path.exists(expected_error):
                wanted.add(error_name)
                if error_name not in produced:
                    fail("%s: missing %s" % (tag, error_name))
                with open(expected_error, encoding="utf-8") as f:
                    want = f.read().strip()
                with open(os.path.join(actual_dir, error_name), encoding="utf-8") as f:
                    got = f.read().strip()
                if got != want:
                    fail("%s: reported %r, expected %r" % (tag, got, want))
                continue
        elif error_name in produced:
            wanted.add(error_name)
            continue
        wanted.update(result_names)
        results = {}
        for suffix, name in zip(SUFFIXES[op], result_names):
            if name not in produced:
                fail("%s: missing %s" % (tag, name))
            results[suffix] = read_result(os.path.join(actual_dir, name), tag)
            if expected_dir is not None:
                expected = read_result(os.path.join(expected_dir, name), tag + " expected")
                compare_matrix("%s %s" % (tag, name), expected, results[suffix])
        inputs = [load(n) for n in parts[1:1 + ARITY[op]]]
        check_command(tag, op, inputs, results)

    extra = sorted(produced - wanted)
    if extra:
        fail("unexpected output files: %s" % ", ".join(extra[:5]))
    missing = sorted(wanted - produced)
    if missing:
        fail("missing output files: %s" % ", ".join(missing[:5]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
