(ns linalg.mmio-test
  (:require [clojure.string :as str]
            [clojure.test :refer [are deftest is]]
            [clojure.test.check.clojure-test :refer [defspec]]
            [clojure.test.check.generators :as gen]
            [clojure.test.check.properties :as prop]
            [linalg.matrix :as m]
            [linalg.mmio :as mmio]
            [linalg.test-util :as tu]))

(defn- parse-rows [& lines] (m/to-rows (mmio/parse (str (str/join "\n" lines) "\n"))))

(deftest array-general-is-column-major
  (is (= [[1.0 2.0] [3.0 4.0]]
         (parse-rows "%%MatrixMarket matrix array real general" "2 2" "1.0" "3.0" "2.0" "4.0"))))

(deftest array-symmetric-and-skew
  (is (= [[4.0 2.0] [2.0 5.0]]
         (parse-rows "%%MatrixMarket matrix array real symmetric" "2 2" "4.0" "2.0" "5.0")))
  (is (= [[0.0 -1.0 -2.0] [1.0 0.0 -3.0] [2.0 3.0 0.0]]
         (parse-rows "%%MatrixMarket matrix array real skew-symmetric" "3 3" "1" "2" "3"))))

(deftest coordinate-variants
  (is (= [[0.5 0.0] [0.0 -1.5]]
         (parse-rows "%%MatrixMarket matrix coordinate real general" "2 2 2" "1 1 0.5" "2 2 -1.5")))
  (is (= [[1.0 0.0 7.0] [0.0 0.0 0.0]]
         (parse-rows "%%MatrixMarket matrix coordinate integer general"
                     "% a comment" "" "2 3 2" "" "1 1 1" "1 3 7")))
  (is (= [[2.0 3.0] [3.0 0.0]]
         (parse-rows "%%MatrixMarket matrix coordinate real symmetric" "2 2 2" "1 1 2" "2 1 3")))
  (is (= [[0.0 -3.0] [3.0 0.0]]
         (parse-rows "%%MatrixMarket matrix coordinate real skew-symmetric" "2 2 1" "2 1 3")))
  (is (= [[1.0 0.0] [1.0 1.0]]
         (parse-rows "%%MatrixMarket MATRIX Coordinate Pattern General" "2 2 3" "1 1" "2 1" "2 2"))))

(deftest value-forms
  (is (= [[1.0 -2.5 3.0e-7 1000.0]]
         (parse-rows "%%MatrixMarket matrix array real general" "1 4" "1" "-2.5" "3.0e-7" "1.0E+03"))))

(deftest format-double-matches-printf
  (are [x s] (= s (mmio/format-double x))
    1.2345678901234 "1.2345678901e+00"
    -0.007 "-7.0000000000e-03"
    40015.4224789 "4.0015422479e+04"
    0.0 "0.0000000000e+00"
    -0.0 "0.0000000000e+00"
    1.5 "1.5000000000e+00"
    9.99999999999 "1.0000000000e+01"
    1e100 "1.0000000000e+100"
    -1e-300 "-1.0000000000e-300"
    4.9e-324 "4.9406564584e-324"))

(deftest format-matrix-layout
  (is (= (str "%%MatrixMarket matrix array real general\n2 1\n"
              "1.0000000000e+00\n-2.0000000000e+00\n")
         (mmio/format-matrix (m/from-rows [[1] [-2]])))))

(defspec format-then-parse-is-accurate 50
  (prop/for-all [a (tu/gen-any-matrix 5)]
    (let [b (mmio/parse (mmio/format-matrix a))]
      (tu/close? a b 1e-9))))
