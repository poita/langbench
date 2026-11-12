(ns linalg.lu-test
  (:require [clojure.test :refer [deftest is]]
            [clojure.test.check.clojure-test :refer [defspec]]
            [clojure.test.check.properties :as prop]
            [linalg.lu :as lu]
            [linalg.matrix :as m]
            [linalg.test-util :as tu]))

(deftest worked-example
  (let [a (m/from-rows [[1 2] [3 4]])
        {:keys [P L U perm swaps]} (lu/lu a)]
    (is (= [1 0] perm))
    (is (= 1 swaps))
    (is (= [[0.0 1.0] [1.0 0.0]] (m/to-rows P)))
    (is (tu/close? L (m/from-rows [[1 0] [(/ 1.0 3.0) 1]])))
    (is (tu/close? U (m/from-rows [[3 4] [0 (/ 2.0 3.0)]])))
    (is (< (Math/abs (+ 2.0 (lu/det a))) 1e-12))))

(deftest ties-pick-the-smallest-row
  (is (= [0 1] (:perm (lu/lu (m/from-rows [[2 1] [-2 5]]))))))

(deftest errors
  (is (= :not-square (tu/thrown-code #(lu/lu (m/zeros 2 3)))))
  (is (= :not-square (tu/thrown-code #(lu/det (m/zeros 2 3)))))
  (is (= :not-square (tu/thrown-code #(lu/inverse (m/zeros 2 3)))))
  (is (= :not-square (tu/thrown-code #(lu/solve (m/zeros 2 3) (m/zeros 3 1)))))
  (is (= :dimension-mismatch (tu/thrown-code #(lu/solve (m/zeros 2 2) (m/zeros 3 1)))))
  (is (= :singular (tu/thrown-code #(lu/lu (m/from-rows [[1 2] [2 4]])))))
  (is (= :singular (tu/thrown-code #(lu/inverse (m/zeros 3 3)))))
  (is (= :singular (tu/thrown-code #(lu/solve (m/zeros 2 2) (m/zeros 2 1)))))
  (is (== 0.0 (lu/det (m/from-rows [[1 2] [2 4]])))))

(defspec plu-reconstructs-a 50
  (prop/for-all [a (tu/gen-square 8)]
    (if (== 0.0 (lu/det a))                  ; singular inputs are an error
      (= :singular (tu/thrown-code #(lu/lu a)))
      (let [{:keys [P L U]} (lu/lu a)]
        (and (tu/lower-triangular? L) (tu/upper-triangular? U)
             (every? #(<= (Math/abs ^double %) 1.0) (:data L))
             (tu/close? (m/mul P a) (m/mul L U)))))))

(defspec solve-satisfies-the-system 50
  (prop/for-all [a (tu/gen-matrix 5 5) b (tu/gen-matrix 5 3)]
    ;; make A safely nonsingular by adding a heavy diagonal
    (let [a (m/add a (tu/scale-matrix (m/identity-matrix 5) 100.0))
          x (lu/solve a b)]
      (tu/close? (m/mul a x) b 1e-9))))

(defspec inverse-times-a-is-identity 50
  (prop/for-all [a (tu/gen-matrix 4 4)]
    (let [a (m/add a (tu/scale-matrix (m/identity-matrix 4) 100.0))]
      (tu/close? (m/mul a (lu/inverse a)) (m/identity-matrix 4)))))

(defspec det-is-multiplicative 50
  (prop/for-all [a (tu/gen-matrix 3 3) b (tu/gen-matrix 3 3)]
    (let [x (lu/det (m/mul a b)) y (* (lu/det a) (lu/det b))]
      (<= (Math/abs (- x y)) (* 1e-9 (max 1.0 (Math/abs y)))))))
