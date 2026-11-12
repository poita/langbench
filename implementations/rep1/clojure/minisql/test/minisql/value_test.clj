(ns minisql.value-test
  (:require [clojure.test :refer [deftest is testing]]
            [clojure.test.check.clojure-test :refer [defspec]]
            [clojure.test.check.generators :as gen]
            [clojure.test.check.properties :as prop]
            [minisql.value :as v]))

(deftest total-order
  (is (neg? (v/compare-values nil 0)))
  (is (neg? (v/compare-values nil "")))
  (is (zero? (v/compare-values nil nil)))
  (is (neg? (v/compare-values 100 "0")))
  (is (neg? (v/compare-values 1 "a")))
  (is (neg? (v/compare-values -5 3)))
  (is (neg? (v/compare-values "" "a")))
  (is (neg? (v/compare-values "a" "ab")))
  (is (neg? (v/compare-values "ab" "b")))
  (is (neg? (v/compare-values "B" "a")))
  (testing "code point order, even across surrogate pairs"
    (is (neg? (v/compare-values "\uFFFD" (String. (Character/toChars 0x1F600)))))
    (is (neg? (v/compare-values "z" "é")))))

(deftest real-comparison
  (is (zero? (v/compare-values 2 (v/->Real 200))))
  (is (neg? (v/compare-values 2 (v/->Real 201))))
  (is (pos? (v/compare-values (v/->Real 150) 1)))
  (is (neg? (v/compare-values (v/->Real 150) "a"))))

(deftest three-valued-truth
  (is (nil? (v/truth nil)))
  (is (= [false true true] (map v/truth [0 1 -3])))
  (is (= [false true] (map v/truth [(v/->Real 0) (v/->Real 1)]))))

(deftest average-examples
  (doseq [[sum cnt out] [[3 2 "1.50"] [4 3 "1.33"] [36 8 "4.50"] [-3 2 "-1.50"]
                         [9 8 "1.13"] [-9 8 "-1.13"] [-1 201 "0.00"] [0 5 "0.00"]]]
    (is (= out (v/render (v/average sum cnt))) (str sum "/" cnt))))

(defspec average-matches-bigdecimal 500
  (prop/for-all [sum (gen/choose -1000000 1000000)
                 cnt (gen/choose 1 1000)]
    (= (v/render (v/average sum cnt))
       (-> (.divide (bigdec sum) (bigdec cnt) 2 java.math.RoundingMode/HALF_UP)
           .toPlainString))))

(deftest rendering
  (is (= ["NULL" "-12" "0" "abc" "4.50" "-1.13" "0.00" "0.05" "-0.05"]
         (map v/render [nil -12 0 "abc" (v/->Real 450) (v/->Real -113) (v/->Real 0)
                        (v/->Real 5) (v/->Real -5)]))))

(defspec compare-is-antisymmetric-and-transitive 300
  (let [val (gen/one-of [(gen/return nil) gen/small-integer gen/string-alphanumeric])]
    (prop/for-all [a val b val c val]
      (and (= (Long/signum (v/compare-values a b)) (- (Long/signum (v/compare-values b a))))
           (or (not (and (<= (v/compare-values a b) 0) (<= (v/compare-values b c) 0)))
               (<= (v/compare-values a c) 0))))))
