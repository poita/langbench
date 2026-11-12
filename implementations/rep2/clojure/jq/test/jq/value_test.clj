(ns jq.value-test
  (:require [clojure.test :refer [deftest is]]
            [clojure.test.check.clojure-test :refer [defspec]]
            [clojure.test.check.properties :as prop]
            [jq.json :as json]
            [jq.json-test :refer [gen-json]]
            [jq.value :as v]))

(defn- p [s] (json/parse s))

(deftest type-ordering
  (let [sorted [nil false true 0.0 "" "a" [] [1.0] {} ]]
    (is (apply < (map-indexed (fn [i x] i) sorted)))
    (doseq [[a b] (partition 2 1 [nil false true 1.0 "a" [] (p "{}")])]
      (is (neg? (v/compare-values a b))))))

(deftest string-order-is-by-code-point
  (is (neg? (v/compare-values "Z" "a")))
  (is (neg? (v/compare-values "z" "é")))
  (is (neg? (v/compare-values "" "a")))
  (is (neg? (v/compare-values "a" "ab")))
  ;; U+FF5E (BMP, above surrogates) sorts BEFORE U+1F600 (astral)
  (is (neg? (v/compare-values "\uFF5E" "\uD83D\uDE00"))))

(deftest array-and-object-order
  (is (neg? (v/compare-values (p "[1,2]") (p "[1,2,0]"))))
  (is (neg? (v/compare-values (p "[1,2]") (p "[1,3]"))))
  (is (neg? (v/compare-values (p "{\"a\":2}") (p "{\"b\":1}"))))
  (is (neg? (v/compare-values (p "{\"a\":1}") (p "{\"a\":2}"))))
  (is (v/equal? (p "{\"a\":1,\"b\":2}") (p "{\"b\":2,\"a\":1}")))
  (is (v/equal? 1.0 (- 1.5 0.5))))

(deftest negative-zero-equals-zero
  (is (v/equal? -0.0 0.0)))

(deftest sorted-keys-cached
  (let [o (p "{\"b\":1,\"a\":2}")]
    (is (identical? (v/sorted-keys o) (v/sorted-keys o)))))

(deftest clj-conversion
  (is (= {"a" [1.0 nil "x"]} (v/->clj (v/clj-> {:a [1 nil "x"]}))))
  (is (= {:a [1.0]} (v/->clj (v/clj-> {"a" [1]}) true))))

(defspec compare-is-antisymmetric 200
  (prop/for-all [a gen-json b gen-json]
    (= (Long/signum (v/compare-values a b)) (- (Long/signum (v/compare-values b a))))))

(defspec compare-is-reflexive 200
  (prop/for-all [a gen-json] (zero? (v/compare-values a a))))
