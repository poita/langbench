(ns linalg.svd-test
  (:require [clojure.test :refer [deftest is]]
            [clojure.test.check.clojure-test :refer [defspec]]
            [clojure.test.check.properties :as prop]
            [linalg.matrix :as m]
            [linalg.svd :as svd]
            [linalg.test-util :as tu]))

(deftest diagonal-matrix
  (let [{:keys [U S V]} (svd/svd (m/from-rows [[1 0] [0 -3]]))]
    (is (= [[3.0] [1.0]] (m/to-rows S)))
    (is (tu/close? (m/mul (m/mul U (tu/diag-matrix S)) (m/transpose V))
                   (m/from-rows [[1 0] [0 -3]])))))

(deftest condition-number
  (is (tu/close? (m/scalar (svd/cond-number (m/from-rows [[2 0] [0 0.5]])))
                 (m/scalar 4.0)))
  (is (= :singular (tu/thrown-code #(svd/cond-number (m/from-rows [[0 0] [0 1]]))))))

(defn- reconstruct [{:keys [U S V]}]
  (m/mul (m/mul U (tu/diag-matrix S)) (m/transpose V)))

(defspec svd-reconstructs-any-shape 40
  (prop/for-all [a (tu/gen-any-matrix 7)]
    (let [{:keys [U S V] :as r} (svd/svd a)
          k (min (m/rows a) (m/cols a))
          s (map first (m/to-rows S))]
      (and (= [(m/rows a) k] (m/shape U))
           (= [(m/cols a) k] (m/shape V))
           (apply >= s)
           (every? #(>= % 0.0) s)
           (tu/orthonormal-columns? U)
           (tu/orthonormal-columns? V)
           (tu/close? (reconstruct r) a)))))
