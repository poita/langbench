(ns linalg.chol
  "Cholesky factorisation of symmetric positive definite matrices."
  (:require [linalg.error :as err]
            [linalg.matrix :as m])
  (:import (linalg.matrix Matrix)))

(set! *warn-on-reflection* true)

(defn chol
  "The lower triangular `L` with a positive diagonal such that `A = L Lᵀ`,
  computed column by column. Throws `:not-square`, `:not-symmetric` (exact
  comparison) or `:not-positive-definite` (a pivot `s <= 0`)."
  [^Matrix a]
  (when-not (m/square? a) (err/fail! :not-square))
  (when-not (m/symmetric? a) (err/fail! :not-symmetric))
  (let [n (.rows a) ^doubles ad (.data a)
        l (double-array (* n n))]
    (dotimes [j n]
      (let [s (- (aget ad (+ (* j n) j))
                 (loop [k 0 s 0.0]
                   (if (< k j) (let [x (aget l (+ (* j n) k))] (recur (inc k) (+ s (* x x)))) s)))]
        (when (<= s 0.0) (err/fail! :not-positive-definite))
        (let [ljj (Math/sqrt s)]
          (aset l (+ (* j n) j) ljj)
          (loop [i (inc j)]
            (when (< i n)
              (let [t (loop [k 0 t 0.0]
                        (if (< k j)
                          (recur (inc k) (+ t (* (aget l (+ (* i n) k)) (aget l (+ (* j n) k)))))
                          t))]
                (aset l (+ (* i n) j) (/ (- (aget ad (+ (* i n) j)) t) ljj)))
              (recur (inc i)))))))
    (m/matrix n n l)))
