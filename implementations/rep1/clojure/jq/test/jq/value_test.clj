(ns jq.value-test
  (:require [clojure.test :refer [deftest is testing]]
            [clojure.test.check.clojure-test :refer [defspec]]
            [clojure.test.check.generators :as gen]
            [clojure.test.check.properties :as prop]
            [jq.json :as json]
            [jq.value :as v]))

(defn- j [s] (json/parse s))

(deftest type-ordering
  (let [ascending [nil false true 0.0 1.5 "" "a" "ab" "b" [] [1.0] [1.0 0.0] [2.0]
                   v/empty-obj (v/object "a" 1.0) (v/object "a" 2.0) (v/object "b" 0.0)]]
    (doseq [[a b] (partition 2 1 ascending)]
      (is (neg? (v/compare-values a b)) (str (pr-str a) " < " (pr-str b)))
      (is (pos? (v/compare-values b a))))))

(deftest string-order-is-by-code-point
  (is (neg? (v/compare-values "Z" "a")))
  (is (neg? (v/compare-values "z" "é")))
  ;; U+1F600 (a surrogate pair in UTF-16) sorts after U+FF5E
  (is (pos? (v/compare-values "😀" "\uff5e"))))

(deftest object-equality-ignores-key-order
  (is (v/equal? (v/object "a" 1.0 "b" 2.0) (v/object "b" 2.0 "a" 1.0)))
  (is (not (v/equal? (v/object "a" 1.0) (v/object "a" 1.0 "b" nil)))))

(deftest object-key-order
  (let [o (v/object "b" 1.0 "a" 2.0 "b" 3.0)]
    (is (= ["b" "a"] (v/obj-keys o)))
    (is (= 3.0 (v/obj-get o "b")))
    (is (= ["a" "b"] (v/obj-sorted-keys o))))
  (is (= ["z" "a" "m"]
         (v/obj-keys (v/obj-merge (v/object "z" 1.0 "a" 2.0) (v/object "m" 3.0 "z" 9.0)))))
  (is (= "{\"a\":{\"x\":1,\"y\":2},\"b\":3}"
         (json/stringify (v/obj-deep-merge (j "{\"a\":{\"x\":1},\"b\":3}") (j "{\"a\":{\"y\":2}}"))))))

(deftest values-are-immutable
  (let [o (v/object "a" 1.0)
        o2 (v/obj-assoc o "a" 2.0)]
    (is (= 1.0 (v/obj-get o "a")))
    (is (= 2.0 (v/obj-get o2 "a")))))

(deftest truthiness
  (is (every? v/truthy? [0.0 "" [] v/empty-obj true]))
  (is (not-any? v/truthy? [nil false])))

(deftest clojure-conversion
  (let [x (v/from-clj {:a [1 2 {"b" nil}] :c "s"})]
    (is (= "{\"a\":[1,2,{\"b\":null}],\"c\":\"s\"}" (json/stringify x)))
    (is (= {"a" [1.0 2.0 {"b" nil}] "c" "s"} (v/to-clj x)))))

(def gen-num (gen/fmap #(/ (double %) 4) gen/small-integer))
(def gen-val (gen/recursive-gen #(gen/vector % 0 3)
                                (gen/one-of [(gen/return nil) gen/boolean gen-num gen/string])))

(defspec order-is-antisymmetric 200
  (prop/for-all [a gen-val b gen-val]
    (= (Long/signum (v/compare-values a b)) (- (Long/signum (v/compare-values b a))))))

(defspec order-is-transitive 200
  (prop/for-all [a gen-val b gen-val c gen-val]
    (if (and (<= (v/compare-values a b) 0) (<= (v/compare-values b c) 0))
      (<= (v/compare-values a c) 0)
      true)))
