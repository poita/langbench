#!/usr/bin/env python3
"""Reference implementation of the `linalg` problem.

Reads a command script and Matrix Market matrices from an input directory and
writes one Matrix Market array file per result into an output directory.
Pure Python floats throughout: no numpy, no third-party code.
"""
import math
import os
import sys

# ---------------------------------------------------------------------------
# Errors
# ---------------------------------------------------------------------------


class LinalgError(Exception):
    """Raised when a command cannot be carried out; `code` is written out."""

    def __init__(self, code):
        super().__init__(code)
        self.code = code


# ---------------------------------------------------------------------------
# Matrix Market input
# ---------------------------------------------------------------------------

def _data_lines(text):
    """Yield the file's non-blank lines after the banner and comment block."""
    for line in text.split("\n"):
        line = line.strip()
        if line == "" or line.startswith("%"):
            continue
        yield line


def read_mm(path):
    """Read a Matrix Market file into a dense row-major list of lists."""
    with open(path, "r", encoding="utf-8") as f:
        text = f.read()
    first = text.split("\n", 1)[0].strip()
    banner = first.split()
    fmt, field, symmetry = banner[2].lower(), banner[3].lower(), banner[4].lower()
    body = _data_lines(text.split("\n", 1)[1] if "\n" in text else "")
    size = next(body).split()
    rows, cols = int(size[0]), int(size[1])
    A = [[0.0] * cols for _ in range(rows)]
    if fmt == "coordinate":
        nnz = int(size[2])
        for _ in range(nnz):
            parts = next(body).split()
            i, j = int(parts[0]) - 1, int(parts[1]) - 1
            v = 1.0 if field == "pattern" else float(parts[2])
            A[i][j] = v
            if i != j:
                if symmetry == "symmetric":
                    A[j][i] = v
                elif symmetry == "skew-symmetric":
                    A[j][i] = -v
    else:
        if symmetry == "symmetric":
            for j in range(cols):
                for i in range(j, rows):
                    v = float(next(body))
                    A[i][j] = v
                    A[j][i] = v
        elif symmetry == "skew-symmetric":
            for j in range(cols):
                for i in range(j + 1, rows):
                    v = float(next(body))
                    A[i][j] = v
                    A[j][i] = -v
        else:
            for j in range(cols):
                for i in range(rows):
                    A[i][j] = float(next(body))
    return A


# ---------------------------------------------------------------------------
# Matrix Market output
# ---------------------------------------------------------------------------

def fmt_value(v):
    """Format one number, mapping negative zero onto positive zero."""
    if v == 0.0:
        v = 0.0
    return "%.10e" % v


def write_mm(path, A):
    rows = len(A)
    cols = len(A[0]) if rows else 0
    out = ["%%MatrixMarket matrix array real general", "%d %d" % (rows, cols)]
    for j in range(cols):
        for i in range(rows):
            out.append(fmt_value(A[i][j]))
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(out))
        f.write("\n")


# ---------------------------------------------------------------------------
# Basic matrix helpers
# ---------------------------------------------------------------------------

def shape(A):
    return len(A), len(A[0])


def zeros(m, n):
    return [[0.0] * n for _ in range(m)]


def identity(n):
    I = zeros(n, n)
    for i in range(n):
        I[i][i] = 1.0
    return I


def copy_matrix(A):
    return [row[:] for row in A]


def is_symmetric(A):
    m, n = shape(A)
    if m != n:
        return False
    for i in range(n):
        Ai = A[i]
        for j in range(i + 1, n):
            if Ai[j] != A[j][i]:
                return False
    return True


def mat_add(A, B):
    if shape(A) != shape(B):
        raise LinalgError("dimension_mismatch")
    return [[a + b for a, b in zip(ra, rb)] for ra, rb in zip(A, B)]


def mat_mul(A, B):
    ma, na = shape(A)
    mb, nb = shape(B)
    if na != mb:
        raise LinalgError("dimension_mismatch")
    cols = [[B[k][j] for k in range(mb)] for j in range(nb)]
    out = []
    for row in A:
        out.append([sum(x * y for x, y in zip(row, col)) for col in cols])
    return out


def transpose(A):
    m, n = shape(A)
    return [[A[i][j] for i in range(m)] for j in range(n)]


def norm_one(A):
    m, n = shape(A)
    best = 0.0
    for j in range(n):
        s = 0.0
        for i in range(m):
            s += abs(A[i][j])
        if s > best:
            best = s
    return best


def norm_inf(A):
    best = 0.0
    for row in A:
        s = 0.0
        for v in row:
            s += abs(v)
        if s > best:
            best = s
    return best


def norm_fro(A):
    s = 0.0
    for row in A:
        for v in row:
            s += v * v
    return math.sqrt(s)


# ---------------------------------------------------------------------------
# LU with partial pivoting
# ---------------------------------------------------------------------------

def lu_factor(A):
    """Right-looking Gaussian elimination with partial pivoting.

    Returns (M, perm, sign, zero_pivot) where M holds the strict lower part of
    L below the diagonal and U on and above it, perm[i] is the original row
    index now sitting in row i, sign is the determinant sign of P, and
    zero_pivot is True when a column had no nonzero candidate pivot.
    """
    n = len(A)
    M = copy_matrix(A)
    perm = list(range(n))
    sign = 1
    zero_pivot = False
    for k in range(n):
        p = k
        best = abs(M[k][k])
        for i in range(k + 1, n):
            v = abs(M[i][k])
            if v > best:
                best = v
                p = i
        if best == 0.0:
            zero_pivot = True
            continue
        if p != k:
            M[k], M[p] = M[p], M[k]
            perm[k], perm[p] = perm[p], perm[k]
            sign = -sign
        Mk = M[k]
        pivot = Mk[k]
        for i in range(k + 1, n):
            Mi = M[i]
            f = Mi[k] / pivot
            Mi[k] = f
            if f != 0.0:
                for j in range(k + 1, n):
                    Mi[j] -= f * Mk[j]
    return M, perm, sign, zero_pivot


def lu_split(M, perm, n):
    """Split the packed factorisation into explicit P, L and U."""
    P = zeros(n, n)
    for i in range(n):
        P[i][perm[i]] = 1.0
    L = zeros(n, n)
    U = zeros(n, n)
    for i in range(n):
        Mi = M[i]
        for j in range(i):
            L[i][j] = Mi[j]
        L[i][i] = 1.0
        for j in range(i, n):
            U[i][j] = Mi[j]
    return P, L, U


def lu_solve(M, perm, B):
    """Solve A X = B given the packed factorisation of A."""
    n = len(M)
    k = len(B[0])
    X = [[B[perm[i]][c] for c in range(k)] for i in range(n)]
    for i in range(1, n):
        Mi = M[i]
        Xi = X[i]
        for j in range(i):
            f = Mi[j]
            if f != 0.0:
                Xj = X[j]
                for c in range(k):
                    Xi[c] -= f * Xj[c]
    for i in range(n - 1, -1, -1):
        Mi = M[i]
        Xi = X[i]
        for j in range(i + 1, n):
            f = Mi[j]
            if f != 0.0:
                Xj = X[j]
                for c in range(k):
                    Xi[c] -= f * Xj[c]
        d = Mi[i]
        for c in range(k):
            Xi[c] /= d
    return X


# ---------------------------------------------------------------------------
# Cholesky
# ---------------------------------------------------------------------------

def cholesky(A):
    n = len(A)
    L = zeros(n, n)
    for j in range(n):
        Lj = L[j]
        s = A[j][j]
        for k in range(j):
            s -= Lj[k] * Lj[k]
        if not s > 0.0:
            raise LinalgError("not_positive_definite")
        d = math.sqrt(s)
        Lj[j] = d
        for i in range(j + 1, n):
            Li = L[i]
            t = A[i][j]
            for k in range(j):
                t -= Li[k] * Lj[k]
            Li[j] = t / d
    return L


# ---------------------------------------------------------------------------
# Householder QR (thin)
# ---------------------------------------------------------------------------

def qr_factor(A):
    """Thin QR of an m x n matrix with m >= n; R has a non-negative diagonal."""
    m, n = shape(A)
    R = copy_matrix(A)
    reflectors = []
    for k in range(n):
        nrm = 0.0
        for i in range(k, m):
            v = R[i][k]
            nrm += v * v
        nrm = math.sqrt(nrm)
        if nrm == 0.0:
            reflectors.append(None)
            for i in range(k + 1, m):
                R[i][k] = 0.0
            continue
        alpha = -nrm if R[k][k] >= 0.0 else nrm
        v = [R[i][k] for i in range(k, m)]
        v[0] -= alpha
        vnorm = math.sqrt(sum(x * x for x in v))
        if vnorm == 0.0:
            reflectors.append(None)
        else:
            v = [x / vnorm for x in v]
            reflectors.append(v)
            for j in range(k + 1, n):
                s = 0.0
                for i in range(k, m):
                    s += v[i - k] * R[i][j]
                s *= 2.0
                for i in range(k, m):
                    R[i][j] -= s * v[i - k]
        R[k][k] = alpha
        for i in range(k + 1, m):
            R[i][k] = 0.0
    Q = zeros(m, n)
    for j in range(n):
        Q[j][j] = 1.0
    for k in range(n - 1, -1, -1):
        v = reflectors[k]
        if v is None:
            continue
        for j in range(n):
            s = 0.0
            for i in range(k, m):
                s += v[i - k] * Q[i][j]
            s *= 2.0
            for i in range(k, m):
                Q[i][j] -= s * v[i - k]
    for j in range(n):
        if R[j][j] < 0.0:
            for c in range(j, n):
                R[j][c] = -R[j][c]
            for i in range(m):
                Q[i][j] = -Q[i][j]
    Rsq = [[R[i][j] for j in range(n)] for i in range(n)]
    return Q, Rsq


def qr_lstsq(A, B):
    """Least squares solution of A X ~ B through the thin QR factorisation."""
    m, n = shape(A)
    Q, R = qr_factor(A)
    for j in range(n):
        if R[j][j] == 0.0:
            raise LinalgError("singular")
    k = len(B[0])
    Y = zeros(n, k)
    for j in range(n):
        Yj = Y[j]
        for c in range(k):
            s = 0.0
            for i in range(m):
                s += Q[i][j] * B[i][c]
            Yj[c] = s
    for i in range(n - 1, -1, -1):
        Ri = R[i]
        Yi = Y[i]
        for j in range(i + 1, n):
            f = Ri[j]
            if f != 0.0:
                Yj = Y[j]
                for c in range(k):
                    Yi[c] -= f * Yj[c]
        d = Ri[i]
        for c in range(k):
            Yi[c] /= d
    return Y


# ---------------------------------------------------------------------------
# Sign normalisation
# ---------------------------------------------------------------------------

def leading_sign(column):
    """Sign of the first largest-magnitude entry: +1, -1, or +1 for a zero vector."""
    best = -1.0
    idx = 0
    for i, v in enumerate(column):
        a = abs(v)
        if a > best:
            best = a
            idx = i
    return -1.0 if column[idx] < 0.0 else 1.0


# ---------------------------------------------------------------------------
# Symmetric eigendecomposition: cyclic Jacobi
# ---------------------------------------------------------------------------

JACOBI_TOL = 1e-14
JACOBI_MAX_SWEEPS = 60


def off_norm(A, n):
    s = 0.0
    for i in range(n):
        Ai = A[i]
        for j in range(i + 1, n):
            v = Ai[j]
            s += v * v
    return math.sqrt(2.0 * s)


def eig_symmetric(A):
    """Eigenvalues ascending and orthonormal eigenvectors of a symmetric matrix."""
    n = len(A)
    M = copy_matrix(A)
    V = identity(n)
    limit = JACOBI_TOL * norm_fro(A)
    previous = float("inf")
    for _ in range(JACOBI_MAX_SWEEPS):
        off = off_norm(M, n)
        if off <= limit or off >= previous:
            break
        previous = off
        for p in range(n - 1):
            Mp = M[p]
            for q in range(p + 1, n):
                apq = Mp[q]
                if apq == 0.0:
                    continue
                Mq = M[q]
                theta = (Mq[q] - Mp[p]) / (2.0 * apq)
                root = math.sqrt(theta * theta + 1.0)
                if theta >= 0.0:
                    t = 1.0 / (theta + root)
                else:
                    t = -1.0 / (-theta + root)
                c = 1.0 / math.sqrt(t * t + 1.0)
                s = t * c
                for i in range(n):
                    Mi = M[i]
                    aip = Mi[p]
                    aiq = Mi[q]
                    Mi[p] = c * aip - s * aiq
                    Mi[q] = s * aip + c * aiq
                for j in range(n):
                    apj = Mp[j]
                    aqj = Mq[j]
                    Mp[j] = c * apj - s * aqj
                    Mq[j] = s * apj + c * aqj
                Mp[q] = 0.0
                Mq[p] = 0.0
                for i in range(n):
                    Vi = V[i]
                    vip = Vi[p]
                    viq = Vi[q]
                    Vi[p] = c * vip - s * viq
                    Vi[q] = s * vip + c * viq
    values = [M[i][i] for i in range(n)]
    order = sorted(range(n), key=lambda i: (values[i], i))
    w = [[values[i]] for i in order]
    vectors = zeros(n, n)
    for out_j, src in enumerate(order):
        column = [V[i][src] for i in range(n)]
        sgn = leading_sign(column)
        for i in range(n):
            vectors[i][out_j] = sgn * column[i]
    return w, vectors


# ---------------------------------------------------------------------------
# SVD: one-sided Jacobi
# ---------------------------------------------------------------------------

def one_sided_jacobi(A, want_vectors):
    """Singular values (descending) of a tall matrix, with optional factors.

    Works on the columns of a copy of A; on return column j of the working
    matrix is sigma_j times left singular vector j and V holds the
    accumulated rotations.
    """
    m, n = shape(A)
    cols = [[A[i][j] for i in range(m)] for j in range(n)]
    V = identity(n) if want_vectors else None
    for _ in range(JACOBI_MAX_SWEEPS):
        rotations = 0
        for p in range(n - 1):
            cp = cols[p]
            for q in range(p + 1, n):
                cq = cols[q]
                alpha = 0.0
                beta = 0.0
                gamma = 0.0
                for i in range(m):
                    x = cp[i]
                    y = cq[i]
                    alpha += x * x
                    beta += y * y
                    gamma += x * y
                if gamma == 0.0 or alpha == 0.0 or beta == 0.0:
                    continue
                if abs(gamma) <= JACOBI_TOL * math.sqrt(alpha * beta):
                    continue
                rotations += 1
                zeta = (beta - alpha) / (2.0 * gamma)
                root = math.sqrt(zeta * zeta + 1.0)
                if zeta >= 0.0:
                    t = 1.0 / (zeta + root)
                else:
                    t = -1.0 / (-zeta + root)
                c = 1.0 / math.sqrt(t * t + 1.0)
                s = t * c
                for i in range(m):
                    x = cp[i]
                    y = cq[i]
                    cp[i] = c * x - s * y
                    cq[i] = s * x + c * y
                if V is not None:
                    for i in range(n):
                        Vi = V[i]
                        x = Vi[p]
                        y = Vi[q]
                        Vi[p] = c * x - s * y
                        Vi[q] = s * x + c * y
        if rotations == 0:
            break
    sigmas = [math.sqrt(sum(v * v for v in col)) for col in cols]
    order = sorted(range(n), key=lambda j: (-sigmas[j], j))
    return cols, V, sigmas, order


def svd(A):
    """Thin SVD with singular values descending; returns (U, S, V)."""
    m, n = shape(A)
    flipped = m < n
    work = transpose(A) if flipped else A
    wm, wn = shape(work)
    cols, V, sigmas, order = one_sided_jacobi(work, True)
    k = wn
    left_vectors = []
    right_vectors = []
    S = []
    for src in order:
        sigma = sigmas[src]
        column = cols[src]
        if sigma > 0.0:
            left_vectors.append([v / sigma for v in column])
        else:
            left_vectors.append([0.0] * wm)
        right_vectors.append([V[i][src] for i in range(wn)])
        S.append([sigma])
    if flipped:
        left_vectors, right_vectors = right_vectors, left_vectors
    rows_u = len(left_vectors[0])
    rows_v = len(right_vectors[0])
    U = zeros(rows_u, k)
    W = zeros(rows_v, k)
    for j in range(k):
        sgn = leading_sign(left_vectors[j])
        for i in range(rows_u):
            U[i][j] = sgn * left_vectors[j][i]
        for i in range(rows_v):
            W[i][j] = sgn * right_vectors[j][i]
    return U, S, W


def singular_values(A):
    m, n = shape(A)
    work = transpose(A) if m < n else A
    cols, _, sigmas, order = one_sided_jacobi(work, False)
    return [sigmas[j] for j in order]


def condition_number(A):
    s = singular_values(A)
    if not s or s[-1] == 0.0:
        raise LinalgError("singular")
    return s[0] / s[-1]


# ---------------------------------------------------------------------------
# Command dispatch
# ---------------------------------------------------------------------------

def require_square(A):
    m, n = shape(A)
    if m != n:
        raise LinalgError("not_square")
    return n


def run_command(op, mats):
    """Return a list of (suffix, matrix) results for one command."""
    if op == "add":
        return [("add", mat_add(mats[0], mats[1]))]
    if op == "mul":
        return [("mul", mat_mul(mats[0], mats[1]))]
    if op == "transpose":
        return [("transpose", transpose(mats[0]))]
    if op == "norm1":
        return [("norm1", [[norm_one(mats[0])]])]
    if op == "norminf":
        return [("norminf", [[norm_inf(mats[0])]])]
    if op == "normfro":
        return [("normfro", [[norm_fro(mats[0])]])]
    if op == "lu":
        n = require_square(mats[0])
        M, perm, _, zero = lu_factor(mats[0])
        if zero:
            raise LinalgError("singular")
        P, L, U = lu_split(M, perm, n)
        return [("lu_P", P), ("lu_L", L), ("lu_U", U)]
    if op == "det":
        n = require_square(mats[0])
        M, _, sign, zero = lu_factor(mats[0])
        if zero:
            return [("det", [[0.0]])]
        d = float(sign)
        for i in range(n):
            d *= M[i][i]
        return [("det", [[d]])]
    if op == "inv":
        n = require_square(mats[0])
        M, perm, _, zero = lu_factor(mats[0])
        if zero:
            raise LinalgError("singular")
        return [("inv", lu_solve(M, perm, identity(n)))]
    if op == "solve":
        A, B = mats
        n = require_square(A)
        if len(B) != n:
            raise LinalgError("dimension_mismatch")
        M, perm, _, zero = lu_factor(A)
        if zero:
            raise LinalgError("singular")
        return [("solve", lu_solve(M, perm, B))]
    if op == "qr":
        m, n = shape(mats[0])
        if m < n:
            raise LinalgError("dimension_mismatch")
        Q, R = qr_factor(mats[0])
        return [("qr_Q", Q), ("qr_R", R)]
    if op == "lstsq":
        A, B = mats
        m, n = shape(A)
        if m < n:
            raise LinalgError("dimension_mismatch")
        if len(B) != m:
            raise LinalgError("dimension_mismatch")
        return [("lstsq", qr_lstsq(A, B))]
    if op == "chol":
        require_square(mats[0])
        if not is_symmetric(mats[0]):
            raise LinalgError("not_symmetric")
        return [("chol_L", cholesky(mats[0]))]
    if op == "eig":
        require_square(mats[0])
        if not is_symmetric(mats[0]):
            raise LinalgError("not_symmetric")
        w, V = eig_symmetric(mats[0])
        return [("eig_w", w), ("eig_V", V)]
    if op == "svd":
        U, S, V = svd(mats[0])
        return [("svd_U", U), ("svd_S", S), ("svd_V", V)]
    if op == "cond":
        return [("cond", [[condition_number(mats[0])]])]
    raise LinalgError("unknown_operation")


ARITY = {
    "add": 2, "mul": 2, "transpose": 1, "lu": 1, "det": 1, "inv": 1,
    "solve": 2, "qr": 1, "chol": 1, "eig": 1, "svd": 1, "lstsq": 2,
    "norm1": 1, "norminf": 1, "normfro": 1, "cond": 1,
}


def main(argv):
    if len(argv) != 3:
        sys.stderr.write("usage: main.py <input dir> <output dir>\n")
        return 2
    in_dir, out_dir = argv[1], argv[2]
    os.makedirs(out_dir, exist_ok=True)
    with open(os.path.join(in_dir, "commands.txt"), "r", encoding="utf-8") as f:
        script = f.read()
    index = 0
    cache = {}
    for raw in script.split("\n"):
        line = raw.strip()
        if line == "" or line.startswith("#"):
            continue
        index += 1
        parts = line.split()
        op = parts[0]
        names = parts[1:1 + ARITY.get(op, 0)]
        try:
            mats = []
            for name in names:
                if name not in cache:
                    cache[name] = read_mm(os.path.join(in_dir, name))
                mats.append(cache[name])
            results = run_command(op, mats)
        except LinalgError as err:
            path = os.path.join(out_dir, "%03d_error.txt" % index)
            with open(path, "w", encoding="utf-8") as f:
                f.write(err.code + "\n")
            continue
        for suffix, matrix in results:
            write_mm(os.path.join(out_dir, "%03d_%s.mtx" % (index, suffix)), matrix)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
