(ns jsonschema.value-test
  (:require [clojure.test :refer [deftest is testing]]
            [clojure.test.check.clojure-test :refer [defspec]]
            [clojure.test.check.generators :as gen]
            [clojure.test.check.properties :as prop]
            [jsonschema.json :as json]
            [jsonschema.value :as v]))

(def ^:private p json/parse)

(deftest equality
  (is (v/json-equal? (p "{\"a\":1,\"b\":2}") (p "{\"b\":2.0,\"a\":1}")))
  (is (not (v/json-equal? true (p "1"))))
  (is (not (v/json-equal? false (p "0"))))
  (is (not (v/json-equal? nil false)))
  (is (not (v/json-equal? "1" (p "1"))))
  (is (v/json-equal? (p "[1,[2,{\"x\":3}]]") (p "[1.0,[2e0,{\"x\":3.00}]]")))
  (is (not (v/json-equal? (p "[1,2]") (p "[1,2,3]"))))
  (is (not (v/json-equal? (p "{\"a\":1}") (p "{\"a\":1,\"b\":2}")))))

(deftest integers
  (is (v/integer-value? (p "1.0")))
  (is (v/integer-value? (p "1e2")))
  (is (v/integer-value? (p "-0")))
  (is (v/integer-value? (p "1.5e1")))
  (is (not (v/integer-value? (p "1.5"))))
  (is (not (v/integer-value? (p "1e-2")))))

(deftest multiple-of
  (testing "exact decimal arithmetic"
    (is (v/multiple-of? (p "0.3") (p "0.0001")))
    (is (v/multiple-of? (p "0.0021") (p "0.0001")))
    (is (v/multiple-of? (p "0") (p "7")))
    (is (v/multiple-of? (p "1e308") (p "0.5")))
    (is (not (v/multiple-of? (p "7.5") (p "2")))))
  (testing "huge exponents"
    (is (v/multiple-of? (p "1e400") (p "1e-400")))
    (is (not (v/multiple-of? (p "1e-400") (p "1e400"))))))

(deftest count-bounds
  (is (= 2 (v/count-bound (p "2.0") :floor)))
  (is (= 2 (v/count-bound (p "2e0") :ceiling)))
  (is (= 2 (v/count-bound (p "2.5") :floor)))
  (is (= 3 (v/count-bound (p "2.5") :ceiling)))
  (is (= Long/MAX_VALUE (v/count-bound (p "1e400") :floor))))

(deftest uniqueness
  (is (v/all-unique? []))
  (is (v/all-unique? (p "[1,\"1\",true,null,[1],{\"a\":1}]")))
  (is (not (v/all-unique? (p "[1,2,1.0]"))))
  (is (not (v/all-unique? (p "[{\"a\":1,\"b\":2},{\"b\":2,\"a\":1.0}]"))))
  (is (v/all-unique? (p "[[1,2],[2,1]]")))
  (is (v/all-unique? (p "[0,false]"))))

(def ^:private gen-json
  (gen/recursive-gen
   (fn [inner]
     (gen/one-of [(gen/vector inner 0 4)
                  (gen/map gen/string-alphanumeric inner {:max-elements 4})]))
   (gen/one-of [(gen/return nil) gen/boolean
                (gen/fmap #(java.math.BigDecimal/valueOf (long %)) gen/small-integer)
                gen/string-alphanumeric])))

(defn- rescale
  "Same JSON value with every number written with extra trailing zeros, and
  object entries rebuilt in reverse order."
  [x]
  (cond
    (instance? java.math.BigDecimal x) (.setScale ^java.math.BigDecimal x (+ 3 (max 0 (.scale ^java.math.BigDecimal x))))
    (map? x) (into {} (map (fn [[k y]] [k (rescale y)])) (reverse (seq x)))
    (vector? x) (mapv rescale x)
    :else x))

(defspec equality-ignores-number-spelling 200
  (prop/for-all [x gen-json]
    (and (v/json-equal? x x)
         (v/json-equal? x (rescale x))
         (== (v/json-hash x) (v/json-hash (rescale x))))))

(defspec all-unique-agrees-with-pairwise-comparison 200
  (prop/for-all [xs (gen/vector (gen/one-of [gen-json (gen/fmap rescale gen-json)]) 0 8)]
    (let [naive (every? true?
                        (for [i (range (count xs)) j (range (inc i) (count xs))]
                          (not (v/json-equal? (nth xs i) (nth xs j)))))]
      (= naive (v/all-unique? xs)))))
