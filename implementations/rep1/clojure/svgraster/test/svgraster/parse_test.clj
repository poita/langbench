(ns svgraster.parse-test
  (:require [clojure.test :refer [deftest is testing]]
            [clojure.test.check.clojure-test :refer [defspec]]
            [clojure.test.check.generators :as gen]
            [clojure.test.check.properties :as prop]
            [svgraster.matrix :as m]
            [svgraster.parse :as p]))

(deftest numbers
  (is (= 5.0 (p/parse-number "5")))
  (is (= 0.5 (p/parse-number ".5")))
  (is (= 5.0 (p/parse-number "5.")))
  (is (= -2.5e3 (p/parse-number " -2.5E+3 ")))
  (is (= 1.0 (p/parse-number "1e")) "an exponent without digits is not part of the number")
  (is (nil? (p/parse-number ".")))
  (is (nil? (p/parse-number "e5")))
  (is (nil? (p/parse-number nil))))

(deftest scan-number-ends
  (is (= 3 (p/scan-number "1.5.5" 0)))
  (is (= 5 (p/scan-number "1.5.5" 3)) "`.5` starts right after `1.5`")
  (is (= -1 (p/scan-number "-" 0))))

(deftest lengths
  (is (= 12.0 (p/parse-length "12px")))
  (is (= 3.0 (p/parse-length "  3  ")))
  (is (nil? (p/parse-length "auto")))
  (is (nil? (p/parse-length nil))))

(deftest opacity
  (is (= 0.5 (p/parse-opacity "0.5")))
  (is (= 0.25 (p/parse-opacity "25%")))
  (is (= 1.0 (p/parse-opacity "7")))
  (is (= 0.0 (p/parse-opacity "-1")))
  (is (nil? (p/parse-opacity "0.5px")))
  (is (nil? (p/parse-opacity "abc")))
  (is (nil? (p/parse-opacity nil))))

(deftest number-lists
  (is (= [1.0 2.0 3.0 -4.0 0.5] (p/parse-number-list "1,2 3-4 .5")))
  (is (= [1.0] (p/parse-number-list "1 x 2")))
  (is (= [] (p/parse-number-list ""))))

(defn- approx= [a b]
  (every? true? (map #(< (Math/abs (- (double %1) (double %2))) 1e-9) a b)))

(deftest transforms
  (is (= m/identity-matrix (p/parse-transform nil)))
  (is (= [1.0 0.0 0.0 1.0 5.0 0.0] (p/parse-transform "translate(5)")))
  (is (= [2.0 0.0 0.0 3.0 0.0 0.0] (p/parse-transform "scale(2,3)")))
  (is (= [2.0 0.0 0.0 2.0 0.0 0.0] (p/parse-transform "scale(2)")))
  (is (approx= [0.0 1.0 -1.0 0.0 0.0 0.0] (p/parse-transform "rotate(90)")))
  (testing "rotation about a point leaves it fixed"
    (let [mat (p/parse-transform "rotate(90 10 20)")]
      (is (approx= [10 20] (m/transform-point mat 10 20)))))
  (testing "functions compose left to right"
    (is (approx= [11 4] (m/transform-point (p/parse-transform "translate(10) scale(2)") 0.5 2)))
    (is (approx= [20 0] (m/transform-point (p/parse-transform "scale(2) translate(10)") 0 0))))
  (is (approx= [1.0 0.0 1.0 1.0 0.0 0.0] (p/parse-transform "skewX(45)")))
  (is (= m/identity-matrix (p/parse-transform "bogus(1 2) translate()")))
  (is (= [1.0 0.0 0.0 1.0 4.0 0.0] (p/parse-transform "translate(1) , translate(3)"))))

(deftest style
  (is (= {"fill" "red" "stroke-width" "3"} (p/parse-style " fill : red ;; Stroke-Width:3; ")))
  (is (= {"a" "2"} (p/parse-style "a:1;a:2")))
  (is (= {} (p/parse-style "fill:;novalue")))
  (is (= {} (p/parse-style nil))))

(defspec scan-number-roundtrips-doubles 200
  (prop/for-all [d (gen/double* {:infinite? false :NaN? false :min -1e6 :max 1e6})]
    (let [s (format "%.6f" d)]
      (== (Double/parseDouble s) (double (p/parse-number s))))))
