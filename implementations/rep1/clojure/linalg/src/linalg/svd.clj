(ns linalg.svd
  "Singular value decomposition by one-sided Jacobi rotations, and the
  condition number built on it."
  (:require [linalg.error :as err]
            [linalg.jacobi :as j]
            [linalg.matrix :as m]
            [linalg.sign :as sign])
  (:import (linalg.matrix Matrix)))

(set! *warn-on-reflection* true)

(def ^:const max-sweeps "Upper bound on the number of Jacobi sweeps." 60)
(def ^:const tolerance "Orthogonality threshold relative to the column norms." 1e-14)

(defn- dot
  ^double [^doubles x ^doubles y]
  (loop [i 0 s 0.0]
    (if (< i (alength x)) (recur (inc i) (+ s (* (aget x i) (aget y i)))) s)))

(defn- rotate-columns! [^doubles x ^doubles y ^double c ^double s]
  (dotimes [i (alength x)]
    (let [a (aget x i) b (aget y i)]
      (aset x i (- (* c a) (* s b)))
      (aset y i (+ (* s a) (* c b))))))

(defn- one-sided-jacobi
  "SVD of a tall (`m' >= n'`) matrix given as its transpose `at` (rows of
  `at` are the columns of the matrix). Returns `[left-columns s right-columns]`
  as vectors of `double[]`, sorted by descending singular value; a left column
  is all zero when its singular value is."
  [^Matrix at]
  (let [np (.rows at) mp (.cols at)
        ^doubles atd (.data at)
        w (vec (for [c (range np)] (java.util.Arrays/copyOfRange atd (int (* c mp)) (int (* (inc c) mp)))))
        v (vec (for [c (range np)] (let [col (double-array np)] (aset col c 1.0) col)))]
    (loop [sweep 0]
      (when (< sweep max-sweeps)
        (let [rotated?
              (loop [p 0 rotated? false]
                (if (< p np)
                  (recur (inc p)
                         (loop [q (inc p) rotated? rotated?]
                           (if (< q np)
                             (let [^doubles wp (w p) ^doubles wq (w q)
                                   alpha (dot wp wp) beta (dot wq wq) gamma (dot wp wq)]
                               (if (or (== gamma 0.0) (== alpha 0.0) (== beta 0.0)
                                       (<= (Math/abs gamma) (* tolerance (Math/sqrt (* alpha beta)))))
                                 (recur (inc q) rotated?)
                                 (let [zeta (/ (- beta alpha) (* 2.0 gamma))
                                       t (j/tangent zeta)
                                       c (j/cosine t)
                                       s (* t c)]
                                   (rotate-columns! wp wq c s)
                                   (rotate-columns! (v p) (v q) c s)
                                   (recur (inc q) true))))
                             rotated?)))
                  rotated?))]
          (when rotated? (recur (inc sweep))))))
    (let [^doubles sigma (double-array (for [c w] (Math/sqrt (dot c c))))
          order (j/order-by-value sigma :desc)]
      [(vec (for [i order]
              (let [^doubles col (w i) sg (aget sigma (long i))
                    u (double-array (alength col))]
                (when-not (== sg 0.0)
                  (dotimes [r (alength col)] (aset u r (/ (aget col r) sg))))
                u)))
       (double-array (for [i order] (aget sigma (long i))))
       (mapv v order)])))

(defn- columns->matrix
  "The `rows` x `(count cols)` matrix whose columns are the `double[]`s."
  [rows cols]
  (let [n (count cols) d (double-array (* rows n))]
    (dotimes [j n]
      (let [^doubles c (nth cols j)]
        (dotimes [i rows] (aset d (+ (* i n) j) (aget c i)))))
    (m/matrix rows n d)))

(defn svd
  "Thin SVD of the `m` x `n` matrix `a`, with `k = min(m, n)`. Returns
  `{:U U :S s :V V}`: `U` is `m` x `k` and `V` is `n` x `k` with orthonormal
  columns, `s` is the `k` x 1 matrix of singular values (descending,
  non-negative), and `A = U diag(s) Vᵀ`. Columns of `U` are sign-normalised
  (see `linalg.sign`) and the matching columns of `V` negated with them."
  [^Matrix a]
  (let [mm (.rows a) n (.cols a)
        tall? (>= mm n)
        ;; `one-sided-jacobi` wants the transpose of the tall matrix.
        [ucols s vcols] (one-sided-jacobi (if tall? (m/transpose a) a))
        k (min mm n)
        [u v] (if tall?
                [(columns->matrix mm ucols) (columns->matrix n vcols)]
                [(columns->matrix mm vcols) (columns->matrix n ucols)])
        mask (sign/flip-mask u)]
    {:U (sign/negate-columns u mask)
     :S (m/matrix k 1 s)
     :V (sign/negate-columns v mask)}))

(defn cond-number
  "The condition number `σ_max / σ_min` of `a` (any shape). Throws
  `:singular` when the smallest singular value is exactly 0.0."
  ^double [^Matrix a]
  (let [^doubles s (.data ^Matrix (:S (svd a)))
        smax (aget s 0) smin (aget s (dec (alength s)))]
    (when (== smin 0.0) (err/fail! :singular))
    (/ smax smin)))
