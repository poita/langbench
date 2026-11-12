(ns linalg.qr
  "Householder QR factorisation and least squares."
  (:require [linalg.error :as err]
            [linalg.matrix :as m])
  (:import (linalg.matrix Matrix)))

(set! *warn-on-reflection* true)

(defn qr
  "Thin Householder QR of the `m` x `n` matrix `a` with `m >= n`.
  Returns `{:Q Q :R R}` with `Q` `m` x `n` (orthonormal columns) and `R`
  `n` x `n` upper triangular with a non-negative diagonal (the factorisation
  is made unique by flipping signs). Rank-deficient input is accepted.
  Throws `:dimension-mismatch` when `m < n`."
  [^Matrix a]
  (let [mm (.rows a) n (.cols a)]
    (when (< mm n) (err/fail! :dimension-mismatch))
    (let [^doubles r (aclone ^doubles (.data a))
          vs (object-array n)]               ; reflector vectors, nil = identity
      (dotimes [k n]
        (let [len (- mm k)
              nu (Math/sqrt (loop [i k s 0.0]
                              (if (< i mm)
                                (let [x (aget r (+ (* i n) k))] (recur (inc i) (+ s (* x x))))
                                s)))]
          (if (== nu 0.0)
            (loop [i (inc k)]
              (when (< i mm) (aset r (+ (* i n) k) 0.0) (recur (inc i))))
            (let [rkk (aget r (+ (* k n) k))
                  alpha (if (>= rkk 0.0) (- nu) nu)
                  v (double-array len)]
              (dotimes [i len] (aset v i (aget r (+ (* (+ k i) n) k))))
              (aset v 0 (- (aget v 0) alpha))
              (let [vn (Math/sqrt (loop [i 0 s 0.0]
                                    (if (< i len) (let [x (aget v i)] (recur (inc i) (+ s (* x x)))) s)))]
                (dotimes [i len] (aset v i (/ (aget v i) vn))))
              (loop [j (inc k)]
                (when (< j n)
                  (let [dot (loop [i 0 s 0.0]
                              (if (< i len)
                                (recur (inc i) (+ s (* (aget v i) (aget r (+ (* (+ k i) n) j)))))
                                s))
                        f (* 2.0 dot)]
                    (dotimes [i len]
                      (let [idx (+ (* (+ k i) n) j)]
                        (aset r idx (- (aget r idx) (* f (aget v i)))))))
                  (recur (inc j))))
              (aset r (+ (* k n) k) alpha)
              (loop [i (inc k)]
                (when (< i mm) (aset r (+ (* i n) k) 0.0) (recur (inc i))))
              (aset vs k v)))))
      ;; Q = H_0 ... H_{n-1} applied to the first n columns of the identity.
      (let [^doubles q (double-array (* mm n))]
        (dotimes [i n] (aset q (+ (* i n) i) 1.0))
        (loop [k (dec n)]
          (when (>= k 0)
            (when-let [^doubles v (aget vs k)]
              (let [len (- mm k)]
                (dotimes [j n]
                  (let [dot (loop [i 0 s 0.0]
                              (if (< i len)
                                (recur (inc i) (+ s (* (aget v i) (aget q (+ (* (+ k i) n) j)))))
                                s))
                        f (* 2.0 dot)]
                    (dotimes [i len]
                      (let [idx (+ (* (+ k i) n) j)]
                        (aset q idx (- (aget q idx) (* f (aget v i))))))))))
            (recur (dec k))))
        ;; Keep the top n x n triangle of R and force a non-negative diagonal.
        (let [^doubles rr (double-array (* n n))]
          (dotimes [i n]
            (loop [j i]
              (when (< j n) (aset rr (+ (* i n) j) (aget r (+ (* i n) j))) (recur (inc j)))))
          (dotimes [j n]
            (when (< (aget rr (+ (* j n) j)) 0.0)
              (dotimes [c n]
                (let [idx (+ (* j n) c)] (aset rr idx (- (aget rr idx)))))
              (dotimes [i mm]
                (let [idx (+ (* i n) j)] (aset q idx (- (aget q idx)))))))
          {:Q (m/matrix mm n q) :R (m/matrix n n rr)})))))

(defn lstsq
  "The `n` x `k` least-squares solution `X` minimising `‖A X - B‖F` for `a`
  of shape `m` x `n` with `m >= n` and `b` of shape `m` x `k`: factors
  `A = Q R` and back-substitutes `R X = Qᵀ B`. Throws `:dimension-mismatch`
  when `m < n` or `b` has the wrong number of rows, and `:singular` when `R`
  has a diagonal entry of exactly 0.0."
  [^Matrix a ^Matrix b]
  (when (< (.rows a) (.cols a)) (err/fail! :dimension-mismatch))
  (when-not (== (.rows a) (.rows b)) (err/fail! :dimension-mismatch))
  (let [{:keys [Q R]} (qr a)
        n (.cols a) k (.cols b)
        ^doubles rd (.data ^Matrix R)]
    (dotimes [i n]
      (when (== 0.0 (aget rd (+ (* i n) i))) (err/fail! :singular)))
    (let [^doubles y (.data ^Matrix (m/mul (m/transpose Q) b))
          out (double-array (* n k))]
      (dotimes [c k]
        (loop [i (dec n)]
          (when (>= i 0)
            (let [s (loop [j (inc i) s (aget y (+ (* i k) c))]
                      (if (< j n)
                        (recur (inc j) (- s (* (aget rd (+ (* i n) j)) (aget out (+ (* j k) c)))))
                        s))]
              (aset out (+ (* i k) c) (/ s (aget rd (+ (* i n) i)))))
            (recur (dec i)))))
      (m/matrix n k out))))
