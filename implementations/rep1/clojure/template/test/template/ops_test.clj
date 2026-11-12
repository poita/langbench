(ns template.ops-test
  (:require [clojure.test :refer [deftest is]]
            [clojure.test.check.clojure-test :refer [defspec]]
            [clojure.test.check.generators :as gen]
            [clojure.test.check.properties :as prop]
            [template.core :as core]
            [template.ops :as ops]))

(defn- kind [f] (try (f) nil (catch clojure.lang.ExceptionInfo e (core/error-kind e))))

(deftest arithmetic
  (is (= 7 (ops/add 3 4)))
  (is (= 3.5 (ops/add 3 0.5)))
  (is (= 2 (ops/add true true)))
  (is (= "ab" (ops/add "a" "b")))
  (is (= [1 2] (ops/add [1] [2])))
  (is (= 2.0 (ops/div 6 3)))
  (is (= -4 (ops/floordiv -7 2)))
  (is (= 3.0 (ops/floordiv 7.0 2)))
  (is (= 2 (ops/modulo -7 3)))
  (is (= -2 (ops/modulo 7 -3)))
  (is (= 1.5 (ops/modulo 7.5 3)))
  (is (= 1024 (ops/power 2 10)))
  (is (= 0.5 (ops/power 2 -1)))
  (is (= 4 (ops/power -2 2)))
  (is (= "ababab" (ops/mul "ab" 3)))
  (is (= "" (ops/mul 0 "ab")))
  (is (= "" (ops/mul "ab" -2)))
  (is (= "1a" (ops/concat-str 1 "a"))))

(deftest errors
  (is (= :type (kind #(ops/add "a" 1))))
  (is (= :type (kind #(ops/div 1 0))))
  (is (= :type (kind #(ops/modulo 1 0.0))))
  (is (= :type (kind #(ops/power 0 -1))))
  (is (= :type (kind #(ops/neg "a"))))
  (is (= :undefined (kind #(ops/add :template.values/undefined 1))))
  (is (= :type (kind #(ops/compare-op :lt 1 "a"))))
  (is (= :type (kind #(ops/member? 1 "abc")))))

(deftest comparison-and-membership
  (is (ops/compare-op :lt 1 1.5))
  (is (ops/compare-op :ge "b" "a"))
  (is (ops/member? "bc" "abcd"))
  (is (ops/member? "" "abc"))
  (is (ops/member? 2 [1 2.0]))
  (is (not (ops/member? 1 []))))

(defspec floor-division-identity 300
  (prop/for-all [a gen/small-integer b (gen/such-that #(not (zero? %)) gen/small-integer)]
    (= a (ops/add (ops/mul (ops/floordiv a b) b) (ops/modulo a b)))))

(defspec modulo-has-divisor-sign 300
  (prop/for-all [a gen/small-integer b (gen/such-that #(not (zero? %)) gen/small-integer)]
    (let [m (ops/modulo a b)]
      (or (zero? m) (= (neg? m) (neg? b))))))
