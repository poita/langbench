(ns linalg.qr-test
  (:require [clojure.test :refer [deftest is]]
            [clojure.test.check.clojure-test :refer [defspec]]
            [clojure.test.check.properties :as prop]
            [linalg.matrix :as m]
            [linalg.qr :as qr]
            [linalg.test-util :as tu]))

(deftest sign-normalisation
  (let [{:keys [Q R]} (qr/qr (m/from-rows [[3] [4]]))]
    (is (tu/close? Q (m/from-rows [[0.6] [0.8]])))
    (is (tu/close? R (m/from-rows [[5]])))))

(deftest rank-deficient-input-succeeds
  (let [a (m/from-rows [[1 0] [2 0] [3 0]])
        {:keys [Q R]} (qr/qr a)]
    (is (tu/close? (m/mul Q R) a))
    (is (= :singular (tu/thrown-code #(qr/lstsq a (m/zeros 3 1)))))))

(deftest errors
  (is (= :dimension-mismatch (tu/thrown-code #(qr/qr (m/zeros 2 3)))))
  (is (= :dimension-mismatch (tu/thrown-code #(qr/lstsq (m/zeros 2 3) (m/zeros 2 1)))))
  (is (= :dimension-mismatch (tu/thrown-code #(qr/lstsq (m/identity-matrix 3) (m/zeros 2 1))))))

(deftest lstsq-fits-a-line
  ;; y = 1 + 2x sampled exactly
  (let [a (m/from-rows [[1 0] [1 1] [1 2] [1 3]])
        b (m/from-rows [[1] [3] [5] [7]])]
    (is (tu/close? (qr/lstsq a b) (m/from-rows [[1] [2]])))))

(defspec qr-reconstructs-a 50
  (prop/for-all [a (tu/gen-tall 7)]
    (let [{:keys [Q R]} (qr/qr a)]
      (and (tu/orthonormal-columns? Q)
           (tu/upper-triangular? R)
           (every? #(>= (m/entry R % %) 0.0) (range (m/cols R)))
           (tu/close? (m/mul Q R) a)))))

(defspec lstsq-residual-is-orthogonal-to-range 50
  (prop/for-all [a (tu/gen-matrix 6 3) b (tu/gen-matrix 6 2)]
    (let [x (qr/lstsq a b)
          resid (tu/sub (m/mul a x) b)]
      (tu/close? (m/mul (m/transpose a) resid) (m/zeros 3 2) 1e-7))))
