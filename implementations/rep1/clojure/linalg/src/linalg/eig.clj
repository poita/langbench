(ns linalg.eig
  "Symmetric eigendecomposition by cyclic Jacobi rotations."
  (:require [linalg.error :as err]
            [linalg.jacobi :as j]
            [linalg.matrix :as m]
            [linalg.sign :as sign])
  (:import (linalg.matrix Matrix)))

(set! *warn-on-reflection* true)

(def ^:const max-sweeps "Upper bound on the number of Jacobi sweeps." 60)
(def ^:const tolerance "Convergence threshold relative to the Frobenius norm." 1e-14)

(defn- off-norm
  "`sqrt(2 Σ_{i<j} M[i][j]²)`, the strict upper triangle summed row-major."
  ^double [^doubles md ^long n]
  (Math/sqrt
   (* 2.0 (loop [i 0 s 0.0]
            (if (< i n)
              (recur (inc i)
                     (double (loop [jj (inc i) s s]
                               (if (< jj n) (let [x (aget md (+ (* i n) jj))] (recur (inc jj) (+ s (* x x)))) s))))
              s)))))

(defn- rotate!
  "Applies the Jacobi rotation for the pair `(p, q)` to `md` (as `Jᵀ M J`) and
  to `vt`, the transpose of the accumulated eigenvector matrix."
  [^doubles md ^doubles vt n p q]
  (let [n (long n) p (long p) q (long q)
        mpq (aget md (+ (* p n) q))
        theta (/ (- (aget md (+ (* q n) q)) (aget md (+ (* p n) p))) (* 2.0 mpq))
        t (j/tangent theta)
        c (j/cosine t)
        s (* t c)]
    (dotimes [i n]                                   ; columns p, q
      (let [ip (+ (* i n) p) iq (+ (* i n) q)
            a (aget md ip) b (aget md iq)]
        (aset md ip (- (* c a) (* s b)))
        (aset md iq (+ (* s a) (* c b)))))
    (dotimes [jj n]                                  ; rows p, q
      (let [pj (+ (* p n) jj) qj (+ (* q n) jj)
            a (aget md pj) b (aget md qj)]
        (aset md pj (- (* c a) (* s b)))
        (aset md qj (+ (* s a) (* c b)))))
    (aset md (+ (* p n) q) 0.0)
    (aset md (+ (* q n) p) 0.0)
    (dotimes [i n]                                   ; V[i][p], V[i][q]
      (let [pi (+ (* p n) i) qi (+ (* q n) i)
            a (aget vt pi) b (aget vt qi)]
        (aset vt pi (- (* c a) (* s b)))
        (aset vt qi (+ (* s a) (* c b)))))))

(defn eig
  "Eigendecomposition of the symmetric matrix `a`. Returns
  `{:w w :V V}`: `w` the ascending eigenvalues as an `n` x 1 matrix and `V`
  the orthogonal matrix whose column `j` is the unit eigenvector for `w[j]`,
  sign-normalised (see `linalg.sign`). Throws `:not-square` or
  `:not-symmetric`."
  [^Matrix a]
  (when-not (m/square? a) (err/fail! :not-square))
  (when-not (m/symmetric? a) (err/fail! :not-symmetric))
  (let [n (.rows a)
        ^doubles md (aclone ^doubles (.data a))
        ^doubles vt (.data ^Matrix (m/transpose (m/identity-matrix n)))
        phi (m/normfro a)]
    (loop [sweep 0 prev Double/POSITIVE_INFINITY]
      (when (< sweep max-sweeps)
        (let [off (off-norm md n)]
          (when-not (or (<= off (* tolerance phi)) (>= off prev))
            (dotimes [p n]
              (loop [q (inc p)]
                (when (< q n)
                  (when (not= 0.0 (aget md (+ (* p n) q)))
                    (rotate! md vt n p q))
                  (recur (inc q)))))
            (recur (inc sweep) off)))))
    (let [^doubles diag (double-array (map #(aget md (+ (* (long %) n) (long %))) (range n)))
          order (j/order-by-value diag :asc)
          w (double-array (map #(aget diag (long %)) order))
          v (double-array (* n n))]
      (dotimes [col n]
        (let [src (long (nth order col))]
          (dotimes [i n] (aset v (+ (* i n) col) (aget vt (+ (* src n) i))))))
      (let [vm (m/matrix n n v)]
        {:w (m/column-vector w)
         :V (sign/negate-columns vm (sign/flip-mask vm))}))))
