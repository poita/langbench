(ns linalg.chol-test
  (:require [clojure.test :refer [deftest is]]
            [clojure.test.check.clojure-test :refer [defspec]]
            [clojure.test.check.properties :as prop]
            [linalg.chol :as chol]
            [linalg.matrix :as m]
            [linalg.test-util :as tu]))

(deftest worked-example
  (is (= [[2.0 0.0] [1.0 2.0]] (m/to-rows (chol/chol (m/from-rows [[4 2] [2 5]]))))))

(deftest errors
  (is (= :not-square (tu/thrown-code #(chol/chol (m/zeros 2 3)))))
  (is (= :not-symmetric (tu/thrown-code #(chol/chol (m/from-rows [[2 1] [0 2]])))))
  (is (= :not-positive-definite (tu/thrown-code #(chol/chol (m/from-rows [[1 2] [2 1]])))))
  (is (= :not-positive-definite (tu/thrown-code #(chol/chol (m/zeros 2 2))))))

(defspec chol-reconstructs-spd-matrices 50
  (prop/for-all [a (tu/gen-square 7)]
    (let [n (m/rows a)
          spd (m/add (m/mul a (m/transpose a)) (tu/scale-matrix (m/identity-matrix n) 1.0))
          l (chol/chol spd)]
      (and (tu/lower-triangular? l)
           (every? pos? (map #(m/entry l % %) (range n)))
           (tu/close? (m/mul l (m/transpose l)) spd)))))
