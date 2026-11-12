(ns linalg.matrix-test
  (:require [clojure.test :refer [deftest is testing]]
            [clojure.test.check.clojure-test :refer [defspec]]
            [clojure.test.check.properties :as prop]
            [linalg.matrix :as m]
            [linalg.test-util :as tu]))

(deftest construction
  (let [a (m/from-rows [[1 2 3] [4 5 6]])]
    (is (= [2 3] (m/shape a)))
    (is (= [[1.0 2.0 3.0] [4.0 5.0 6.0]] (m/to-rows a)))
    (is (= 6.0 (m/entry a 1 2)))
    (is (= [[1.0 0.0] [0.0 1.0]] (m/to-rows (m/identity-matrix 2))))))

(deftest add-and-mul
  (let [a (m/from-rows [[1 2] [3 4]])
        b (m/from-rows [[0.5 0] [0 -1.5]])]
    (is (= [[1.5 2.0] [3.0 2.5]] (m/to-rows (m/add a b))))
    (is (= [[0.5 -3.0] [1.5 -6.0]] (m/to-rows (m/mul a b)))))
  (is (= [[32.0]] (m/to-rows (m/mul (m/from-rows [[1 2 3]]) (m/from-rows [[4] [5] [6]])))))
  (is (= :dimension-mismatch
         (tu/thrown-code #(m/add (m/zeros 2 2) (m/zeros 2 3)))))
  (is (= :dimension-mismatch
         (tu/thrown-code #(m/mul (m/zeros 2 3) (m/zeros 2 3))))))

(deftest norms
  (let [a (m/from-rows [[1 -2] [-3 4]])]
    (is (= 6.0 (m/norm1 a)))
    (is (= 7.0 (m/norminf a)))
    (is (== (Math/sqrt 30.0) (m/normfro a)))))

(deftest symmetry
  (is (m/symmetric? (m/from-rows [[1 2] [2 3]])))
  (is (not (m/symmetric? (m/from-rows [[1 2] [2.0000001 3]]))))
  (is (not (m/symmetric? (m/zeros 2 3)))))

(defspec transpose-is-an-involution 50
  (prop/for-all [a (tu/gen-any-matrix 6)]
    (= (m/to-rows a) (m/to-rows (m/transpose (m/transpose a))))))

(defspec transpose-of-product 50
  (prop/for-all [a (tu/gen-matrix 3 4) b (tu/gen-matrix 4 2)]
    (tu/close? (m/transpose (m/mul a b))
               (m/mul (m/transpose b) (m/transpose a)))))
