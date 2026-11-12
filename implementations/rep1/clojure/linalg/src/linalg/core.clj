(ns linalg.core
  "The public API of the linalg library: dense real linear algebra written
  from scratch in plain Clojure/Java double arithmetic.

  Matrices are `linalg.matrix/Matrix` records (see `linalg.matrix/from-rows`
  to build one and `linalg.matrix/to-rows` to inspect one). Operations return
  new matrices and never mutate their arguments. A call that cannot be carried
  out throws an `ex-info` whose data holds `:linalg/error`, one of
  `:dimension-mismatch`, `:not-square`, `:not-symmetric`,
  `:not-positive-definite`, `:singular` (see `linalg.error`).

  Each function here is a thin alias for the implementation in the module named
  in its docstring; the modules can also be used directly."
  (:require [linalg.chol :as chol]
            [linalg.eig :as eig]
            [linalg.lu :as lu]
            [linalg.matrix :as m]
            [linalg.mmio :as mmio]
            [linalg.qr :as qr]
            [linalg.svd :as svd]))

(defn add
  "`A + B`; see `linalg.matrix/add`."
  [a b] (m/add a b))

(defn mul
  "`A B`; see `linalg.matrix/mul`."
  [a b] (m/mul a b))

(defn transpose
  "`Aᵀ`; see `linalg.matrix/transpose`."
  [a] (m/transpose a))

(defn norm1
  "Maximum absolute column sum; see `linalg.matrix/norm1`."
  [a] (m/norm1 a))

(defn norminf
  "Maximum absolute row sum; see `linalg.matrix/norminf`."
  [a] (m/norminf a))

(defn normfro
  "Frobenius norm; see `linalg.matrix/normfro`."
  [a] (m/normfro a))

(defn lu
  "`P A = L U` with partial pivoting, returned as `{:P :L :U :perm :swaps}`;
  see `linalg.lu/lu`."
  [a] (lu/lu a))

(defn det
  "Determinant; see `linalg.lu/det`."
  [a] (lu/det a))

(defn solve
  "Solves `A X = B`; see `linalg.lu/solve`."
  [a b] (lu/solve a b))

(defn inverse
  "`A⁻¹`; see `linalg.lu/inverse`."
  [a] (lu/inverse a))

(defn qr
  "Thin Householder QR, returned as `{:Q :R}`; see `linalg.qr/qr`."
  [a] (qr/qr a))

(defn lstsq
  "Least-squares solution of `A X ≈ B`; see `linalg.qr/lstsq`."
  [a b] (qr/lstsq a b))

(defn chol
  "Cholesky factor `L` with `A = L Lᵀ`; see `linalg.chol/chol`."
  [a] (chol/chol a))

(defn eig
  "Symmetric eigendecomposition `{:w :V}`; see `linalg.eig/eig`."
  [a] (eig/eig a))

(defn svd
  "Thin singular value decomposition `{:U :S :V}`; see `linalg.svd/svd`."
  [a] (svd/svd a))

(defn cond-number
  "`σ_max / σ_min`; see `linalg.svd/cond-number`."
  [a] (svd/cond-number a))

(defn read-matrix
  "Reads a Matrix Market file into a dense matrix; see `linalg.mmio/read-matrix`."
  [path] (mmio/read-matrix path))

(defn write-matrix
  "Writes a matrix as `array real general` Matrix Market; see
  `linalg.mmio/write-matrix`."
  [path a] (mmio/write-matrix path a))
