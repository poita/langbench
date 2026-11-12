(ns linalg.sign
  "Sign normalisation of eigenvectors and singular vectors.

  Such vectors are only determined up to sign, so one is fixed: for a column
  `v`, let `i*` be the smallest index attaining `max |v[i]|`; if `v[i*] < 0`
  the column is negated."
  (:require [linalg.matrix :as m])
  (:import (linalg.matrix Matrix)))

(set! *warn-on-reflection* true)

(defn flip-mask
  "A vector of booleans, one per column of `a`: true where the column must be
  negated to satisfy the sign rule. All-zero columns are never flipped."
  [^Matrix a]
  (let [rows (.rows a) cols (.cols a) ^doubles d (.data a)]
    (vec (for [j (range cols)]
           (loop [i 0 best 0.0 neg false]
             (if (< i rows)
               (let [x (aget d (+ (* i cols) j)) ax (Math/abs x)]
                 (if (> ax best) (recur (inc i) ax (< x 0.0)) (recur (inc i) best neg)))
               neg))))))

(defn negate-columns
  "A copy of `a` with every column `j` negated for which `(nth mask j)` is true."
  [^Matrix a mask]
  (let [rows (.rows a) cols (.cols a)
        ^doubles d (aclone ^doubles (.data a))]
    (dotimes [j cols]
      (when (nth mask j)
        (dotimes [i rows]
          (let [k (+ (* i cols) j)] (aset d k (- (aget d k)))))))
    (m/matrix rows cols d)))
