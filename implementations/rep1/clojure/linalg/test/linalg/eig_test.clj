(ns linalg.eig-test
  (:require [clojure.test :refer [deftest is]]
            [clojure.test.check.clojure-test :refer [defspec]]
            [clojure.test.check.properties :as prop]
            [linalg.eig :as eig]
            [linalg.matrix :as m]
            [linalg.test-util :as tu]))

(deftest worked-example
  (let [{:keys [w V]} (eig/eig (m/from-rows [[2 1] [1 3]]))]
    (is (tu/close? w (m/column-vector [1.3819660113 3.6180339887]) 1e-9))
    (is (tu/close? V (m/from-rows [[0.8506508084 0.5257311121]
                                   [-0.5257311121 0.8506508084]])
                   1e-9))))

(deftest errors
  (is (= :not-square (tu/thrown-code #(eig/eig (m/zeros 2 3)))))
  (is (= :not-symmetric (tu/thrown-code #(eig/eig (m/from-rows [[1 2] [3 4]]))))))

(deftest diagonal-input
  (let [{:keys [w V]} (eig/eig (m/from-rows [[3 0] [0 1]]))]
    (is (= [[1.0] [3.0]] (m/to-rows w)))
    (is (= [[0.0 1.0] [1.0 0.0]] (m/to-rows V)))))

(defspec eig-decomposes-symmetric-matrices 40
  (prop/for-all [a (tu/gen-symmetric 8)]
    (let [{:keys [w V]} (eig/eig a)
          ws (map first (m/to-rows w))]
      (and (apply <= ws)
           (tu/orthonormal-columns? V)
           (tu/close? (m/mul a V) (m/mul V (tu/diag-matrix w)))))))
