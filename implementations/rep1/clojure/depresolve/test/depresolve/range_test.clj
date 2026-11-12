(ns depresolve.range-test
  (:require [clojure.test :refer [deftest is testing]]
            [depresolve.range :as r]
            [depresolve.version :as v]))

(defn- accepts [range-str & versions]
  (let [rng (r/parse range-str)]
    (mapv #(r/accepts? rng (v/parse %)) versions)))

(deftest wildcard
  (is (= [true true] (accepts "*" "0.0.0" "999.9.9"))))

(deftest exact
  (is (= [true false false] (accepts "1.2.3" "1.2.3" "1.2.4" "1.2.2"))))

(deftest caret
  (testing "major > 0"
    (is (= [false true true true false]
           (accepts "^1.2.3" "1.2.2" "1.2.3" "1.9.0" "1.99.99" "2.0.0"))))
  (testing "0.minor"
    (is (= [false true true false]
           (accepts "^0.2.3" "0.2.2" "0.2.3" "0.2.9" "0.3.0"))))
  (testing "0.0.patch"
    (is (= [false true false]
           (accepts "^0.0.3" "0.0.2" "0.0.3" "0.0.4")))))

(deftest tilde
  (is (= [false true true false] (accepts "~1.2.3" "1.2.2" "1.2.3" "1.2.9" "1.3.0")))
  (testing "tilde on 0.0.z keeps major and minor fixed"
    (is (= [true true false] (accepts "~0.0.3" "0.0.3" "0.0.9" "0.1.0")))))

(deftest comparators
  (is (= [false true] (accepts ">1.0.0" "1.0.0" "1.0.1")))
  (is (= [true false] (accepts "<=1.0.0" "1.0.0" "1.0.1")))
  (is (= [false true false] (accepts "<2.0.0" "2.0.0" "1.9.9" "2.0.0")))
  (is (= [true true false false] (accepts ">=1.0.0 <2.0.0" "1.0.0" "1.5.0" "2.0.0" "0.9.0")))
  (is (= [true false] (accepts ">=1.0.0 <=1.0.0" "1.0.0" "1.0.1")))
  (is (= [false false] (accepts ">=2.0.0 <1.0.0" "1.5.0" "2.5.0")))
  (is (= [false true false] (accepts ">1.0.0 >=1.2.0 <1.3.0" "1.1.0" "1.2.0" "1.3.0"))))

(deftest emptiness
  (is (r/empty-range? (r/parse ">=2.0.0 <1.0.0")))
  (is (not (r/empty-range? (r/parse "^0.0.1"))))
  (is (not (r/empty-range? r/any))))
